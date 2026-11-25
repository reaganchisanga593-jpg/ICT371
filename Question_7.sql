-- ============ (a) TABLES & SEED ============
CREATE TABLE customers (
  customer_id NUMBER PRIMARY KEY,
  full_name   VARCHAR2(100) NOT NULL
);
CREATE TABLE readings (
  reading_id      NUMBER PRIMARY KEY,
  customer_id     NUMBER NOT NULL REFERENCES customers(customer_id),
  reading_month   DATE NOT NULL,   -- first day of month
  previous_reading NUMBER(12,2) NOT NULL CHECK (previous_reading >= 0),
  current_reading  NUMBER(12,2) NOT NULL CHECK (current_reading  >= 0),
  CONSTRAINT uq_read UNIQUE(customer_id, reading_month),
  CONSTRAINT ck_read CHECK (current_reading >= previous_reading)
);
CREATE TABLE bills (
  bill_id     NUMBER PRIMARY KEY,
  reading_id  NUMBER UNIQUE NOT NULL REFERENCES readings(reading_id),
  charge      NUMBER(14,2) NOT NULL CHECK (charge >= 0),
  amount_paid NUMBER(14,2) DEFAULT 0 NOT NULL,
  due_on      DATE NOT NULL,
  CONSTRAINT ck_paid CHECK (amount_paid >= 0 AND amount_paid <= charge)
);
CREATE TABLE receivable_snapshot (
  snapshot_date DATE PRIMARY KEY,
  total_due     NUMBER(14,2) DEFAULT 0
);
CREATE SEQUENCE seq_reading START WITH 1;
CREATE SEQUENCE seq_bill START WITH 1;

INSERT INTO customers VALUES (1,'Cust A');
INSERT INTO customers VALUES (2,'Cust B');
INSERT INTO customers VALUES (3,'Cust C');
-- six readings: zero, exactly 10, above 10
INSERT INTO readings VALUES (seq_reading.NEXTVAL,1, DATE '2024-01-01', 100, 100); -- 0 units
INSERT INTO readings VALUES (seq_reading.NEXTVAL,2, DATE '2024-01-01', 50, 60);   -- 10 units
INSERT INTO readings VALUES (seq_reading.NEXTVAL,3, DATE '2024-01-01', 20, 45);   -- 25 units
INSERT INTO readings VALUES (seq_reading.NEXTVAL,1, DATE '2024-02-01', 100, 115); -- 15 units
INSERT INTO readings VALUES (seq_reading.NEXTVAL,2, DATE '2024-02-01', 60, 70);   -- 10 units
INSERT INTO readings VALUES (seq_reading.NEXTVAL,3, DATE '2024-02-01', 45, 45);   -- 0
COMMIT;

-- ============ (b) FUNCTION ============
CREATE OR REPLACE FUNCTION fn_water_charge(p_units NUMBER) RETURN NUMBER IS
  v_charge NUMBER;
BEGIN
  IF p_units IS NULL OR p_units < 0 THEN
    RAISE_APPLICATION_ERROR(-20601,'Invalid consumption');
  END IF;
  IF p_units <= 10 THEN
    v_charge := p_units * 5;
  ELSE
    v_charge := 10*5 + (p_units-10)*8;
  END IF;
  RETURN ROUND(v_charge,2);
END;
/

-- ============ (c) PROCEDURE ============
CREATE OR REPLACE PROCEDURE pr_generate_bill(p_reading_id NUMBER, p_due_on DATE) IS
  v_prev NUMBER; v_cur NUMBER; v_units NUMBER; v_charge NUMBER;
BEGIN
  SELECT previous_reading, current_reading INTO v_prev, v_cur
    FROM readings WHERE reading_id = p_reading_id;
  IF EXISTS (SELECT 1 FROM bills WHERE reading_id = p_reading_id) THEN
    RAISE_APPLICATION_ERROR(-20602,'Bill already exists for reading');
  END IF;
  v_units := v_cur - v_prev;
  v_charge := fn_water_charge(v_units);
  INSERT INTO bills(bill_id, reading_id, charge, amount_paid, due_on)
    VALUES (seq_bill.NEXTVAL, p_reading_id, v_charge, 0, p_due_on);
  COMMIT;
EXCEPTION WHEN NO_DATA_FOUND THEN
  RAISE_APPLICATION_ERROR(-20603,'Unknown reading');
END;
/

-- ============ (d) TRIGGER ============
CREATE OR REPLACE TRIGGER trg_reading_check
BEFORE INSERT OR UPDATE ON readings
FOR EACH ROW
BEGIN
  IF :NEW.current_reading < :NEW.previous_reading THEN
    RAISE_APPLICATION_ERROR(-20610,'Current reading below previous');
  END IF;
END;
/

-- ============ (e) VIEW ============
CREATE OR REPLACE VIEW v_overdue_bills AS
SELECT c.full_name, b.due_on, (b.charge - b.amount_paid) AS outstanding
FROM bills b
JOIN readings r ON r.reading_id = b.reading_id
JOIN customers c ON c.customer_id = r.customer_id
WHERE b.due_on < CURRENT_DATE AND b.amount_paid < b.charge;

-- ============ (f) INDEX ============
CREATE INDEX ix_bills_due_paid ON bills(due_on, amount_paid);
-- Justification: overdue queries filter by due_on range and amount_paid < charge.
EXPLAIN PLAN FOR
  SELECT * FROM bills WHERE due_on < CURRENT_DATE AND amount_paid < charge;
SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY);

-- ============ (g) SCHEDULED JOB ============
CREATE OR REPLACE PROCEDURE pr_refresh_receivables IS
BEGIN
  MERGE INTO receivable_snapshot s
  USING (SELECT TRUNC(SYSDATE) snapshot_date,
                NVL(SUM(charge - amount_paid),0) total_due
         FROM bills WHERE amount_paid < charge) x
  ON (s.snapshot_date = x.snapshot_date)
  WHEN MATCHED THEN UPDATE SET total_due = x.total_due
  WHEN NOT MATCHED THEN INSERT(snapshot_date,total_due) VALUES(x.snapshot_date,x.total_due);
  COMMIT;
END;
/

BEGIN
  DBMS_SCHEDULER.CREATE_JOB(
    job_name        => 'JOB_REFRESH_RECEIVABLES',
    job_type        => 'PLSQL_BLOCK',
    job_action      => 'BEGIN pr_refresh_receivables; END;',
    start_date      => SYSTIMESTAMP,
    repeat_interval => 'FREQ=DAILY;BYHOUR=0;BYMINUTE=30;BYSECOND=0',
    enabled         => TRUE);
END;
/