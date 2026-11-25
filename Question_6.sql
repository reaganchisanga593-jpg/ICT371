-- ============ (a) TABLES & SEED ============
CREATE TABLE employees (
  employee_id  NUMBER PRIMARY KEY,
  full_name    VARCHAR2(100) NOT NULL,
  basic_salary NUMBER(12,2) NOT NULL CHECK (basic_salary >= 0),
  allowance    NUMBER(12,2) NOT NULL CHECK (allowance >= 0),
  deduction    NUMBER(12,2) NOT NULL CHECK (deduction >= 0),
  active       CHAR(1) NOT NULL CHECK (active IN ('Y','N'))  -- boolean emulation
);
CREATE TABLE payroll (
  payroll_id  NUMBER PRIMARY KEY,
  employee_id NUMBER NOT NULL REFERENCES employees(employee_id),
  pay_month   DATE NOT NULL,     -- first day of month
  gross_pay   NUMBER(14,2),
  net_pay     NUMBER(14,2),
  CONSTRAINT uq_pay UNIQUE(employee_id, pay_month)
);
CREATE TABLE salary_audit (
  audit_id   NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  employee_id NUMBER REFERENCES employees(employee_id),
  old_salary NUMBER(12,2),
  new_salary NUMBER(12,2),
  changed_at TIMESTAMP DEFAULT SYSTIMESTAMP
);
CREATE SEQUENCE seq_payroll START WITH 1;

INSERT INTO employees VALUES (1,'Ann',  5000, 500, 200, 'Y');
INSERT INTO employees VALUES (2,'Ben',  4000, 300, 100, 'Y');
INSERT INTO employees VALUES (3,'Cat',  3000, 200, 100, 'N');
COMMIT;
-- Two payroll months' seed via the procedure after creation
-- (call pr_process_payroll at end)

-- ============ (b) FUNCTION ============
CREATE OR REPLACE FUNCTION fn_net_pay(p_employee_id NUMBER) RETURN NUMBER IS
  v_basic NUMBER; v_all NUMBER; v_ded NUMBER; v_net NUMBER;
BEGIN
  SELECT basic_salary, allowance, deduction
    INTO v_basic, v_all, v_ded
    FROM employees WHERE employee_id = p_employee_id;
  v_net := v_basic + v_all - v_ded;
  IF v_net < 0 THEN
    RAISE_APPLICATION_ERROR(-20501,'Negative net pay');
  END IF;
  RETURN v_net;
EXCEPTION WHEN NO_DATA_FOUND THEN
  RAISE_APPLICATION_ERROR(-20502,'Unknown employee');
END;
/

-- ============ (c) PROCEDURE ============
CREATE OR REPLACE PROCEDURE pr_process_payroll(p_month DATE) IS
BEGIN
  IF TRUNC(p_month) <> TRUNC(p_month,'MM') THEN
    RAISE_APPLICATION_ERROR(-20503,'Month must be first day of month');
  END IF;
  FOR e IN (SELECT employee_id, basic_salary, allowance, deduction
              FROM employees WHERE active = 'Y') LOOP
    DECLARE
      v_net NUMBER; v_gross NUMBER;
    BEGIN
      v_gross := e.basic_salary + e.allowance;
      v_net   := fn_net_pay(e.employee_id);
      INSERT INTO payroll(payroll_id, employee_id, pay_month, gross_pay, net_pay)
        SELECT seq_payroll.NEXTVAL, e.employee_id, TRUNC(p_month), v_gross, v_net
          FROM dual
         WHERE NOT EXISTS (
           SELECT 1 FROM payroll
            WHERE employee_id = e.employee_id AND pay_month = TRUNC(p_month));
    EXCEPTION WHEN OTHERS THEN
      ROLLBACK;
      RAISE;
    END;
  END LOOP;
  COMMIT;
END;
/

-- seed payroll for two months
BEGIN
  pr_process_payroll(DATE '2024-01-01');
  pr_process_payroll(DATE '2024-02-01');
END;
/

-- ============ (d) TRIGGER ============
CREATE OR REPLACE TRIGGER trg_salary_audit
AFTER UPDATE OF basic_salary ON employees
FOR EACH ROW
WHEN (OLD.basic_salary <> NEW.basic_salary)
BEGIN
  INSERT INTO salary_audit(employee_id, old_salary, new_salary)
    VALUES (:OLD.employee_id, :OLD.basic_salary, :NEW.basic_salary);
END;
/

-- ============ (e) VIEW ============
CREATE OR REPLACE VIEW v_payroll_report AS
SELECT e.full_name, p.pay_month, p.gross_pay, p.net_pay
FROM payroll p JOIN employees e ON e.employee_id = p.employee_id;

-- ============ (f) INDEX ============
CREATE INDEX ix_payroll_month ON payroll(pay_month);
-- Justification: reports filter by pay_month across employees; complements the unique (employee_id,pay_month).
EXPLAIN PLAN FOR
  SELECT * FROM payroll WHERE pay_month = DATE '2024-01-01';
SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY);

-- ============ (g) SCHEDULED JOB ============
BEGIN
  DBMS_SCHEDULER.CREATE_JOB(
    job_name        => 'JOB_PAYROLL_MONTHLY',
    job_type        => 'PLSQL_BLOCK',
    job_action      => 'BEGIN pr_process_payroll(TRUNC(ADD_MONTHS(SYSDATE,-1),''MM'')); END;',
    start_date      => SYSTIMESTAMP,
    repeat_interval => 'FREQ=MONTHLY;BYMONTHDAY=1;BYHOUR=2;BYMINUTE=0;BYSECOND=0',
    enabled         => TRUE);
END;
/

-- Inspect job / run history:
-- SELECT job_name, enabled, state FROM user_scheduler_jobs WHERE job_name = 'JOB_PAYROLL_MONTHLY';
-- SELECT job_name, log_date, status, error# FROM user_scheduler_job_run_details
--  WHERE job_name = 'JOB_PAYROLL_MONTHLY' ORDER BY log_date DESC;