-- ============ (a) TABLES & SEED ============
CREATE TABLE books (
  book_id NUMBER PRIMARY KEY,
  title   VARCHAR2(200) NOT NULL
);

CREATE TABLE loans (
  loan_id      NUMBER PRIMARY KEY,
  book_id      NUMBER NOT NULL REFERENCES books(book_id),
  borrower_name VARCHAR2(100) NOT NULL,
  borrowed_on  DATE NOT NULL,
  due_on       DATE NOT NULL,
  returned_on  DATE NULL,
  fine_amount  NUMBER(10,2) DEFAULT 0,
  CONSTRAINT ck_due CHECK (due_on >= borrowed_on)
);

CREATE TABLE loan_audit (
  audit_id   NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  loan_id    NUMBER REFERENCES loans(loan_id),
  old_returned_on DATE,
  new_returned_on DATE,
  changed_at TIMESTAMP DEFAULT SYSTIMESTAMP
);

CREATE TABLE overdue_summary (
  snapshot_date DATE PRIMARY KEY,
  overdue_count NUMBER DEFAULT 0,
  total_fine    NUMBER(14,2) DEFAULT 0
);

CREATE SEQUENCE seq_loan START WITH 1;
INSERT INTO books VALUES (1,'Oracle PL/SQL');
INSERT INTO books VALUES (2,'Databases');
INSERT INTO books VALUES (3,'Algorithms');
INSERT INTO loans VALUES (seq_loan.NEXTVAL,1,'John',  DATE '2024-01-01', DATE '2024-01-15', DATE '2024-01-10', 0);  -- on-time
INSERT INTO loans VALUES (seq_loan.NEXTVAL,2,'Mary',  DATE '2024-01-01', DATE '2024-02-01', NULL, 0);                  -- open overdue
INSERT INTO loans VALUES (seq_loan.NEXTVAL,3,'Peter', DATE '2024-02-01', DATE '2024-02-15', DATE '2024-02-20', 10);   -- returned late
INSERT INTO loans VALUES (seq_loan.NEXTVAL,1,'Ann',   DATE '2024-03-01', DATE '2024-03-15', NULL, 0);
INSERT INTO loans VALUES (seq_loan.NEXTVAL,2,'Bob',   DATE '2024-03-05', DATE '2024-03-19', DATE '2024-03-19', 0);
INSERT INTO loans VALUES (seq_loan.NEXTVAL,3,'Carl',  DATE '2024-04-01', DATE '2024-04-10', NULL, 0);
COMMIT;

-- ============ (b) FUNCTION ============
CREATE OR REPLACE FUNCTION fn_loan_fine(p_loan_id NUMBER, p_as_of DATE) RETURN NUMBER IS
  v_due DATE; v_ret DATE; v_end DATE; v_days NUMBER;
BEGIN
  SELECT due_on, returned_on INTO v_due, v_ret FROM loans WHERE loan_id = p_loan_id;
  v_end := LEAST(p_as_of, NVL(v_ret, p_as_of));
  v_days := v_end - v_due;
  IF v_days < 0 THEN v_days := 0; END IF;
  RETURN v_days * 2;
EXCEPTION WHEN NO_DATA_FOUND THEN
  RAISE_APPLICATION_ERROR(-20201,'Unknown loan');
END;
/

-- ============ (c) PROCEDURE ============
CREATE OR REPLACE PROCEDURE pr_return_loan(p_loan_id NUMBER, p_returned_on DATE) IS
  v_borrowed DATE; v_ret DATE;
BEGIN
  BEGIN
    SELECT borrowed_on, returned_on INTO v_borrowed, v_ret
      FROM loans WHERE loan_id = p_loan_id FOR UPDATE;
  EXCEPTION WHEN NO_DATA_FOUND THEN
    RAISE_APPLICATION_ERROR(-20202,'Unknown loan');
  END;
  IF v_ret IS NOT NULL THEN
    RAISE_APPLICATION_ERROR(-20203,'Loan already returned');
  END IF;
  IF p_returned_on < v_borrowed THEN
    RAISE_APPLICATION_ERROR(-20204,'Return before borrow');
  END IF;
  UPDATE loans
     SET returned_on = p_returned_on,
         fine_amount = fn_loan_fine(p_loan_id, p_returned_on)
   WHERE loan_id = p_loan_id;
  COMMIT;
END;
/

-- ============ (d) TRIGGER ============
CREATE OR REPLACE TRIGGER trg_loan_return_audit
AFTER UPDATE OF returned_on ON loans
FOR EACH ROW
WHEN (NVL(:OLD.returned_on, DATE '9999-01-01') <> NVL(:NEW.returned_on, DATE '9999-01-01'))
BEGIN
  INSERT INTO loan_audit(loan_id, old_returned_on, new_returned_on)
    VALUES (:OLD.loan_id, :OLD.returned_on, :NEW.returned_on);
END;
/

-- ============ (e) VIEW ============
CREATE OR REPLACE VIEW v_overdue_loans AS
SELECT b.title, l.borrower_name, l.due_on, fn_loan_fine(l.loan_id, CURRENT_DATE) AS fine_today
FROM loans l JOIN books b ON b.book_id = l.book_id
WHERE l.returned_on IS NULL AND l.due_on < CURRENT_DATE;

-- ============ (f) INDEX ============
CREATE INDEX ix_loans_book_ret ON loans(book_id, returned_on);
-- Justification: queries find a given book's unreturned loans (returned_on IS NULL).
EXPLAIN PLAN FOR
  SELECT * FROM loans WHERE book_id = 2 AND returned_on IS NULL;
SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY);

-- ============ (g) SCHEDULED JOB ============
CREATE OR REPLACE PROCEDURE pr_refresh_overdue(p_as_of DATE) IS
BEGIN
  MERGE INTO overdue_summary o
  USING (SELECT TRUNC(p_as_of) snapshot_date,
                COUNT(*) overdue_count,
                NVL(SUM(fn_loan_fine(loan_id, p_as_of)),0) total_fine
         FROM loans
         WHERE returned_on IS NULL AND due_on < p_as_of) s
  ON (o.snapshot_date = s.snapshot_date)
  WHEN MATCHED THEN UPDATE SET overdue_count=s.overdue_count, total_fine=s.total_fine
  WHEN NOT MATCHED THEN INSERT(snapshot_date,overdue_count,total_fine)
       VALUES(s.snapshot_date,s.overdue_count,s.total_fine);
  COMMIT;
END;
/

BEGIN
  DBMS_SCHEDULER.CREATE_JOB(
    job_name        => 'JOB_REFRESH_OVERDUE',
    job_type        => 'PLSQL_BLOCK',
    job_action      => 'BEGIN pr_refresh_overdue(TRUNC(SYSDATE)); END;',
    start_date      => SYSTIMESTAMP,
    repeat_interval => 'FREQ=DAILY;BYHOUR=0;BYMINUTE=10;BYSECOND=0',
    enabled         => TRUE);
END;
/