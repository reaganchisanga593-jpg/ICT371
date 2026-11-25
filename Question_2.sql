-- ============ (a) TABLES & SEED ============
CREATE TABLE students (
  student_id     NUMBER PRIMARY KEY,
  student_number VARCHAR2(20) UNIQUE NOT NULL,
  full_name      VARCHAR2(100) NOT NULL,
  fee_due        NUMBER(12,2) NOT NULL CHECK (fee_due >= 0)
);

CREATE TABLE payments (
  payment_id NUMBER PRIMARY KEY,
  student_id NUMBER NOT NULL REFERENCES students(student_id),
  amount     NUMBER(12,2) NOT NULL CHECK (amount > 0),
  paid_on    DATE NOT NULL
);

CREATE TABLE payment_audit (
  audit_id   NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  payment_id NUMBER REFERENCES payments(payment_id),
  student_id NUMBER REFERENCES students(student_id),
  amount     NUMBER(12,2),
  logged_at  TIMESTAMP DEFAULT SYSTIMESTAMP
);

CREATE TABLE daily_collections (
  collection_date DATE PRIMARY KEY,
  payment_count   NUMBER DEFAULT 0,
  total_amount    NUMBER(14,2) DEFAULT 0
);

CREATE SEQUENCE seq_payment START WITH 1;

INSERT INTO students VALUES (1,'S001','Alice', 10000);
INSERT INTO students VALUES (2,'S002','Bob',    5000);
INSERT INTO students VALUES (3,'S003','Carol',  8000);
-- Alice has payments, Bob none, Carol has some
INSERT INTO payments VALUES (seq_payment.NEXTVAL,1,3000,DATE '2024-01-10');
INSERT INTO payments VALUES (seq_payment.NEXTVAL,1,2000,DATE '2024-02-10');
INSERT INTO payments VALUES (seq_payment.NEXTVAL,2,1000,DATE '2024-01-15');
INSERT INTO payments VALUES (seq_payment.NEXTVAL,3,4000,DATE '2024-03-01');
INSERT INTO payments VALUES (seq_payment.NEXTVAL,1,1000,DATE '2024-03-15');
INSERT INTO payments VALUES (seq_payment.NEXTVAL,3,1000,DATE '2024-04-01');
COMMIT;

-- ============ (b) FUNCTION ============
CREATE OR REPLACE FUNCTION fn_fee_balance(p_student_id NUMBER) RETURN NUMBER IS
  v_due NUMBER(12,2); v_paid NUMBER(12,2);
BEGIN
  SELECT fee_due INTO v_due FROM students WHERE student_id = p_student_id;
  SELECT NVL(SUM(amount),0) INTO v_paid FROM payments WHERE student_id = p_student_id;
  RETURN v_due - v_paid;
EXCEPTION WHEN NO_DATA_FOUND THEN
  RAISE_APPLICATION_ERROR(-20101,'Unknown student');
END;
/

-- ============ (c) PROCEDURE ============
CREATE OR REPLACE PROCEDURE pr_receive_payment(
  p_student_id NUMBER, p_amount NUMBER, p_paid_on DATE) IS
  v_balance NUMBER;
BEGIN
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE_APPLICATION_ERROR(-20102,'Invalid amount');
  END IF;
  v_balance := fn_fee_balance(p_student_id);
  IF p_amount > v_balance THEN
    RAISE_APPLICATION_ERROR(-20103,'Payment exceeds outstanding balance');
  END IF;
  INSERT INTO payments(payment_id, student_id, amount, paid_on)
    VALUES (seq_payment.NEXTVAL, p_student_id, p_amount, p_paid_on);
  COMMIT;
END;
/

-- ============ (d) TRIGGER ============
CREATE OR REPLACE TRIGGER trg_payment_audit
AFTER INSERT ON payments
FOR EACH ROW
BEGIN
  INSERT INTO payment_audit(payment_id, student_id, amount)
    VALUES (:NEW.payment_id, :NEW.student_id, :NEW.amount);
END;
/

-- ============ (e) VIEW ============
CREATE OR REPLACE VIEW v_fee_balances AS
SELECT s.student_number, s.full_name,
       s.fee_due - NVL((SELECT SUM(p.amount) FROM payments p
                        WHERE p.student_id = s.student_id),0) AS outstanding
FROM students s
WHERE s.fee_due - NVL((SELECT SUM(p.amount) FROM payments p
                       WHERE p.student_id = s.student_id),0) > 0;

-- ============ (f) INDEX ============
CREATE INDEX ix_pay_student_date ON payments(student_id, paid_on);
-- Justification: composite index supports equality on student_id plus a date range on paid_on.
EXPLAIN PLAN FOR
  SELECT * FROM payments WHERE student_id = 1 AND paid_on BETWEEN DATE '2024-01-01' AND DATE '2024-12-31';
SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY);

-- ============ (g) SCHEDULED JOB ============
CREATE OR REPLACE PROCEDURE pr_refresh_collections(p_day DATE) IS
BEGIN
  MERGE INTO daily_collections d
  USING (SELECT TRUNC(p_day) collection_date,
                COUNT(*) payment_count, NVL(SUM(amount),0) total_amount
         FROM payments WHERE TRUNC(paid_on) = TRUNC(p_day)) s
  ON (d.collection_date = s.collection_date)
  WHEN MATCHED THEN UPDATE SET payment_count=s.payment_count, total_amount=s.total_amount
  WHEN NOT MATCHED THEN INSERT(collection_date,payment_count,total_amount)
       VALUES(s.collection_date,s.payment_count,s.total_amount);
  COMMIT;
END;
/

BEGIN
  DBMS_SCHEDULER.CREATE_JOB(
    job_name        => 'JOB_REFRESH_COLLECTIONS',
    job_type        => 'PLSQL_BLOCK',
    job_action      => 'BEGIN pr_refresh_collections(TRUNC(SYSDATE)-1); END;',
    start_date      => SYSTIMESTAMP,
    repeat_interval => 'FREQ=DAILY;BYHOUR=1;BYMINUTE=0;BYSECOND=0',
    enabled         => TRUE);
END;
/