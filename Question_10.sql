-- ============ (a) TABLES & SEED ============
CREATE TABLE students (
  student_id     NUMBER PRIMARY KEY,
  student_number VARCHAR2(20) UNIQUE NOT NULL,
  full_name      VARCHAR2(100) NOT NULL
);
CREATE TABLE applications (
  application_id   NUMBER PRIMARY KEY,
  student_id       NUMBER NOT NULL REFERENCES students(student_id),
  age_at_application NUMBER(3) NOT NULL CHECK (age_at_application > 0),
  monthly_income   NUMBER(12,2) NOT NULL CHECK (monthly_income >= 0),
  average_mark     NUMBER(5,2) NOT NULL CHECK (average_mark BETWEEN 0 AND 100),
  submitted_on     DATE NOT NULL,
  status           VARCHAR2(10) NOT NULL CHECK (status IN ('PENDING','APPROVED','REJECTED'))
);
CREATE TABLE decision_audit (
  audit_id       NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  application_id NUMBER REFERENCES applications(application_id),
  old_status     VARCHAR2(10),
  new_status     VARCHAR2(10),
  changed_at     TIMESTAMP DEFAULT SYSTIMESTAMP
);
CREATE SEQUENCE seq_app START WITH 1;

INSERT INTO students VALUES (1,'S001','Ann');
INSERT INTO students VALUES (2,'S002','Ben');
INSERT INTO students VALUES (3,'S003','Cat');
-- six PENDING covering qualifying, non-qualifying, boundary
INSERT INTO applications VALUES (seq_app.NEXTVAL,1,20,2500,80, DATE '2024-01-10','PENDING'); -- qualify
INSERT INTO applications VALUES (seq_app.NEXTVAL,1,18,3000,70, DATE '2024-01-11','PENDING'); -- boundary qualify
INSERT INTO applications VALUES (seq_app.NEXTVAL,2,17,2000,90, DATE '2024-01-12','PENDING'); -- age fail
INSERT INTO applications VALUES (seq_app.NEXTVAL,2,22,3500,85, DATE '2024-01-13','PENDING'); -- income fail
INSERT INTO applications VALUES (seq_app.NEXTVAL,3,25,2000,69, DATE '2024-01-14','PENDING'); -- mark fail
INSERT INTO applications VALUES (seq_app.NEXTVAL,3,26,1000,95, DATE '2024-01-15','PENDING'); -- age fail (just above)
COMMIT;

-- ============ (b) FUNCTION ============
CREATE OR REPLACE FUNCTION fn_scholarship_eligible(
  p_age NUMBER, p_income NUMBER, p_mark NUMBER) RETURN BOOLEAN IS
BEGIN
  IF p_age IS NULL OR p_income IS NULL OR p_mark IS NULL THEN
    RAISE_APPLICATION_ERROR(-20901,'NULL inputs not allowed');
  END IF;
  IF p_age <= 0 OR p_income < 0 OR p_mark < 0 OR p_mark > 100 THEN
    RAISE_APPLICATION_ERROR(-20902,'Invalid input range');
  END IF;
  RETURN p_age BETWEEN 18 AND 25
     AND p_income <= 3000
     AND p_mark >= 70;
END;
/

-- ============ (c) PROCEDURE ============
CREATE OR REPLACE PROCEDURE pr_assess_application(p_application_id NUMBER) IS
  v_age NUMBER; v_income NUMBER; v_mark NUMBER; v_status VARCHAR2(10);
  v_ok BOOLEAN; v_new VARCHAR2(10);
BEGIN
  BEGIN
    SELECT age_at_application, monthly_income, average_mark, status
      INTO v_age, v_income, v_mark, v_status
      FROM applications WHERE application_id = p_application_id FOR UPDATE;
  EXCEPTION WHEN NO_DATA_FOUND THEN
    RAISE_APPLICATION_ERROR(-20903,'Unknown application');
  END;
  IF v_status <> 'PENDING' THEN
    RAISE_APPLICATION_ERROR(-20904,'Application already assessed');
  END IF;
  v_ok := fn_scholarship_eligible(v_age, v_income, v_mark);
  v_new := CASE WHEN v_ok THEN 'APPROVED' ELSE 'REJECTED' END;
  UPDATE applications SET status = v_new WHERE application_id = p_application_id;
  COMMIT;
END;
/

-- ============ (d) TRIGGER ============
CREATE OR REPLACE TRIGGER trg_decision_audit
AFTER UPDATE OF status ON applications
FOR EACH ROW
WHEN (OLD.status <> NEW.status)
BEGIN
  INSERT INTO decision_audit(application_id, old_status, new_status)
    VALUES (:OLD.application_id, :OLD.status, :NEW.status);
END;
/

-- ============ (e) VIEW ============
CREATE OR REPLACE VIEW v_approved_applicants AS
SELECT s.student_number, s.full_name, a.average_mark, a.status
FROM applications a JOIN students s ON s.student_id = a.student_id
WHERE a.status = 'APPROVED';

-- ============ (f) INDEX ============
CREATE INDEX ix_app_status_submitted ON applications(status, submitted_on);
-- Justification: searches filtered by status plus a submitted_on date range.
EXPLAIN PLAN FOR
  SELECT * FROM applications WHERE status = 'PENDING'
    AND submitted_on BETWEEN DATE '2024-01-01' AND DATE '2024-01-31';
SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY);

-- ============ (g) SCHEDULED JOB ============
CREATE OR REPLACE PROCEDURE pr_assess_pending IS
BEGIN
  FOR a IN (SELECT application_id FROM applications WHERE status = 'PENDING') LOOP
    pr_assess_application(a.application_id);
  END LOOP;
END;
/

BEGIN
  DBMS_SCHEDULER.CREATE_JOB(
    job_name        => 'JOB_ASSESS_PENDING',
    job_type        => 'PLSQL_BLOCK',
    job_action      => 'BEGIN pr_assess_pending; END;',
    start_date      => SYSTIMESTAMP,
    repeat_interval => 'FREQ=WEEKLY;BYDAY=MON;BYHOUR=8;BYMINUTE=0;BYSECOND=0',
    enabled         => TRUE);
END;
/

-- Reruns will not reassess because pr_assess_application rejects non-PENDING
-- applications; the trigger also only writes audit on actual status changes.