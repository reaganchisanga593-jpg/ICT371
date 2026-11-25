-- ============ (a) TABLES & SEED DATA ============
CREATE TABLE medicines (
  medicine_id   NUMBER PRIMARY KEY,
  medicine_name VARCHAR2(100) NOT NULL,
  unit_price    NUMBER(10,2) NOT NULL CHECK (unit_price > 0),
  stock_qty     NUMBER(10)   NOT NULL CHECK (stock_qty >= 0)
);

CREATE TABLE sales (
  sale_id     NUMBER PRIMARY KEY,
  medicine_id NUMBER NOT NULL REFERENCES medicines(medicine_id),
  quantity    NUMBER(10) NOT NULL CHECK (quantity > 0),
  unit_price  NUMBER(10,2) NOT NULL CHECK (unit_price > 0),
  sold_on     DATE NOT NULL
);

CREATE TABLE stock_audit (
  audit_id   NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  medicine_id NUMBER NOT NULL REFERENCES medicines(medicine_id),
  old_qty    NUMBER(10),
  new_qty    NUMBER(10),
  changed_at TIMESTAMP DEFAULT SYSTIMESTAMP
);

CREATE TABLE daily_sales (
  sales_date   DATE PRIMARY KEY,
  total_qty    NUMBER(12) DEFAULT 0,
  total_amount NUMBER(14,2) DEFAULT 0
);

CREATE SEQUENCE seq_sale START WITH 1;

-- Seed medicines
INSERT INTO medicines VALUES (1,'Paracetamol', 2.50, 100);
INSERT INTO medicines VALUES (2,'Amoxicillin', 5.00, 50);
INSERT INTO medicines VALUES (3,'Ibuprofen',   3.00, 8);
COMMIT;

-- ============ (b) FUNCTION ============
CREATE OR REPLACE FUNCTION fn_sale_value(p_medicine_id NUMBER, p_quantity NUMBER)
RETURN NUMBER IS
  v_price NUMBER(10,2);
BEGIN
  IF p_quantity IS NULL OR p_quantity <= 0 THEN
    RAISE_APPLICATION_ERROR(-20001,'Quantity must be positive');
  END IF;
  BEGIN
    SELECT unit_price INTO v_price FROM medicines WHERE medicine_id = p_medicine_id;
  EXCEPTION WHEN NO_DATA_FOUND THEN
    RAISE_APPLICATION_ERROR(-20002,'Unknown medicine');
  END;
  RETURN v_price * p_quantity;
END;
/

-- ============ (c) PROCEDURE ============
CREATE OR REPLACE PROCEDURE pr_record_sale(
  p_medicine_id NUMBER, p_quantity NUMBER, p_sold_on DATE) IS
  v_price NUMBER(10,2);
  v_stock NUMBER(10);
BEGIN
  IF p_quantity IS NULL OR p_quantity <= 0 THEN
    RAISE_APPLICATION_ERROR(-20003,'Quantity must be positive');
  END IF;
  SELECT unit_price, stock_qty INTO v_price, v_stock
    FROM medicines WHERE medicine_id = p_medicine_id FOR UPDATE;
  IF v_stock < p_quantity THEN
    RAISE_APPLICATION_ERROR(-20004,'Insufficient stock');
  END IF;
  INSERT INTO sales(sale_id, medicine_id, quantity, unit_price, sold_on)
    VALUES (seq_sale.NEXTVAL, p_medicine_id, p_quantity, v_price, p_sold_on);
  UPDATE medicines SET stock_qty = stock_qty - p_quantity
    WHERE medicine_id = p_medicine_id;
  COMMIT;
EXCEPTION WHEN NO_DATA_FOUND THEN
  RAISE_APPLICATION_ERROR(-20005,'Unknown medicine');
END;
/

-- ============ (d) TRIGGER ============
CREATE OR REPLACE TRIGGER trg_med_stock_audit
AFTER UPDATE OF stock_qty ON medicines
FOR EACH ROW
WHEN (OLD.stock_qty <> NEW.stock_qty)
BEGIN
  INSERT INTO stock_audit(medicine_id, old_qty, new_qty)
    VALUES (:OLD.medicine_id, :OLD.stock_qty, :NEW.stock_qty);
END;
/

-- ============ (e) VIEW ============
CREATE OR REPLACE VIEW v_low_stock AS
SELECT medicine_name, unit_price, stock_qty
FROM medicines WHERE stock_qty < 10;
-- Query after a sale:
-- EXEC pr_record_sale(2, 45, SYSDATE);
-- SELECT * FROM v_low_stock;

-- ============ (f) INDEX ============
CREATE INDEX ix_sales_med_date ON sales(medicine_id, sold_on);
-- Justification: range queries filtering by medicine_id then sold_on range use this composite index efficiently.
EXPLAIN PLAN FOR
  SELECT * FROM sales WHERE medicine_id = 1 AND sold_on BETWEEN DATE '2024-01-01' AND DATE '2024-12-31';
SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY);

-- ============ (g) SCHEDULED JOB ============
CREATE OR REPLACE PROCEDURE pr_refresh_sales(p_day DATE) IS
BEGIN
  MERGE INTO daily_sales d
  USING (SELECT TRUNC(p_day) sales_date,
                NVL(SUM(quantity),0) total_qty,
                NVL(SUM(quantity*unit_price),0) total_amount
         FROM sales WHERE TRUNC(sold_on) = TRUNC(p_day)) s
  ON (d.sales_date = s.sales_date)
  WHEN MATCHED THEN UPDATE SET total_qty=s.total_qty, total_amount=s.total_amount
  WHEN NOT MATCHED THEN INSERT(sales_date,total_qty,total_amount)
       VALUES(s.sales_date,s.total_qty,s.total_amount);
  COMMIT;
END;
/

BEGIN
  DBMS_SCHEDULER.CREATE_JOB(
    job_name        => 'JOB_REFRESH_SALES',
    job_type        => 'PLSQL_BLOCK',
    job_action      => 'BEGIN pr_refresh_sales(TRUNC(SYSDATE)-1); END;',
    start_date      => SYSTIMESTAMP,
    repeat_interval => 'FREQ=DAILY;BYHOUR=0;BYMINUTE=15;BYSECOND=0',
    enabled         => TRUE);
END;
/