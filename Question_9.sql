-- ============ (a) TABLES & SEED ============
CREATE TABLE farmers (
  farmer_id    NUMBER PRIMARY KEY,
  farmer_number VARCHAR2(20) UNIQUE NOT NULL,
  full_name    VARCHAR2(100) NOT NULL
);
CREATE TABLE deliveries (
  delivery_id  NUMBER PRIMARY KEY,
  farmer_id    NUMBER NOT NULL REFERENCES farmers(farmer_id),
  grade        CHAR(1) NOT NULL CHECK (grade IN ('A','B','C')),
  weight_kg    NUMBER(12,2) NOT NULL CHECK (weight_kg > 0),
  unit_rate    NUMBER(10,2),
  total_value  NUMBER(14,2),
  delivered_on DATE NOT NULL,
  is_paid      CHAR(1) DEFAULT 'N' NOT NULL CHECK (is_paid IN ('Y','N'))
);
CREATE TABLE daily_purchases (
  purchase_date DATE PRIMARY KEY,
  total_weight  NUMBER(14,2) DEFAULT 0,
  total_value   NUMBER(16,2) DEFAULT 0
);
CREATE SEQUENCE seq_delivery START WITH 1;

INSERT INTO farmers VALUES (1,'F1','Farmer One');
INSERT INTO farmers VALUES (2,'F2','Farmer Two');
INSERT INTO farmers VALUES (3,'F3','Farmer Three');
COMMIT;
-- deliveries inserted via procedure after trigger.

-- ============ (b) FUNCTION ============
CREATE OR REPLACE FUNCTION fn_maize_rate(p_grade CHAR) RETURN NUMBER IS
BEGIN
  IF p_grade = 'A' THEN RETURN 5;
  ELSIF p_grade = 'B' THEN RETURN 4;
  ELSIF p_grade = 'C' THEN RETURN 3;
  ELSE
    RAISE_APPLICATION_ERROR(-20801,'Unsupported grade');
  END IF;
END;
/

-- ============ (c) PROCEDURE ============
CREATE OR REPLACE PROCEDURE pr_receive_delivery(
  p_farmer_id NUMBER, p_grade CHAR, p_weight NUMBER, p_date DATE) IS
BEGIN
  IF NOT EXISTS (SELECT 1 FROM farmers WHERE farmer_id = p_farmer_id) THEN
    RAISE_APPLICATION_ERROR(-20802,'Unknown farmer');
  END IF;
  IF p_weight IS NULL OR p_weight <= 0 THEN
    RAISE_APPLICATION_ERROR(-20803,'Weight must be positive');
  END IF;
  INSERT INTO deliveries(delivery_id, farmer_id, grade, weight_kg, delivered_on, is_paid)
    VALUES (seq_delivery.NEXTVAL, p_farmer_id, p_grade, p_weight, p_date, 'N');
  COMMIT;
END;
/

-- ============ (d) TRIGGER ============
CREATE OR REPLACE TRIGGER trg_delivery_pricing
BEFORE INSERT OR UPDATE ON deliveries
FOR EACH ROW
BEGIN
  IF :NEW.weight_kg IS NULL OR :NEW.weight_kg <= 0 THEN
    RAISE_APPLICATION_ERROR(-20810,'Weight must be positive');
  END IF;
  :NEW.unit_rate   := fn_maize_rate(:NEW.grade);
  :NEW.total_value := ROUND(:NEW.weight_kg * :NEW.unit_rate, 2);
END;
/

-- load deliveries through procedure:
BEGIN
  pr_receive_delivery(1,'A',100, DATE '2024-05-01');
  pr_receive_delivery(2,'B',200, DATE '2024-05-01');
  pr_receive_delivery(3,'C',150, DATE '2024-05-02');
  pr_receive_delivery(1,'B',120, DATE '2024-05-02');
  pr_receive_delivery(2,'A', 80, DATE '2024-05-03');
  pr_receive_delivery(3,'C',100, DATE '2024-05-03');
END;
/

-- mark some paid for seed variety
UPDATE deliveries SET is_paid='Y' WHERE delivery_id IN (1,3,5);
COMMIT;

-- ============ (e) VIEW ============
CREATE OR REPLACE VIEW v_farmer_amount_due AS
SELECT f.farmer_number, f.full_name,
       NVL(SUM(CASE WHEN d.is_paid='N' THEN d.total_value END),0) AS amount_due
FROM farmers f
LEFT JOIN deliveries d ON d.farmer_id = f.farmer_id
GROUP BY f.farmer_number, f.full_name;

-- ============ (f) INDEX ============
CREATE INDEX ix_deliv_farmer_date ON deliveries(farmer_id, delivered_on);
-- Justification: one farmer's deliveries between two dates.
EXPLAIN PLAN FOR
  SELECT * FROM deliveries WHERE farmer_id = 1 AND delivered_on BETWEEN DATE '2024-05-01' AND DATE '2024-05-31';
SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY);

-- ============ (g) SCHEDULED JOB ============
CREATE OR REPLACE PROCEDURE pr_refresh_purchases(p_day DATE) IS
BEGIN
  MERGE INTO daily_purchases p
  USING (SELECT TRUNC(p_day) purchase_date,
                NVL(SUM(weight_kg),0) total_weight,
                NVL(SUM(total_value),0) total_value
         FROM deliveries WHERE TRUNC(delivered_on) = TRUNC(p_day)) s
  ON (p.purchase_date = s.purchase_date)
  WHEN MATCHED THEN UPDATE SET total_weight = s.total_weight, total_value = s.total_value
  WHEN NOT MATCHED THEN INSERT(purchase_date,total_weight,total_value)
       VALUES(s.purchase_date,s.total_weight,s.total_value);
  COMMIT;
END;
/

BEGIN
  DBMS_SCHEDULER.CREATE_JOB(
    job_name        => 'JOB_REFRESH_PURCHASES',
    job_type        => 'PLSQL_BLOCK',
    job_action      => 'BEGIN pr_refresh_purchases(TRUNC(SYSDATE)-1); END;',
    start_date      => SYSTIMESTAMP,
    repeat_interval => 'FREQ=DAILY;BYHOUR=1;BYMINUTE=30;BYSECOND=0',
    enabled         => TRUE);
END;
/