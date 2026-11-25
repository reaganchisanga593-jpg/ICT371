-- ============ (a) TABLES & SEED ============
CREATE TABLE vehicles (
  vehicle_id  NUMBER PRIMARY KEY,
  registration VARCHAR2(20) UNIQUE NOT NULL,
  current_odometer NUMBER(12,2) NOT NULL CHECK (current_odometer >= 0),
  last_service_odometer NUMBER(12,2) NOT NULL CHECK (last_service_odometer >= 0),
  CONSTRAINT ck_odo CHECK (last_service_odometer <= current_odometer)
);
CREATE TABLE trips (
  trip_id  NUMBER PRIMARY KEY,
  vehicle_id NUMBER NOT NULL REFERENCES vehicles(vehicle_id),
  trip_on  DATE NOT NULL,
  start_odometer NUMBER(12,2) NOT NULL,
  end_odometer   NUMBER(12,2) NOT NULL,
  CONSTRAINT ck_trip_odo CHECK (end_odometer > start_odometer)
);
CREATE TABLE service_alerts (
  vehicle_id NUMBER PRIMARY KEY REFERENCES vehicles(vehicle_id),
  km_since_service NUMBER(12,2),
  flagged_on DATE
);
CREATE SEQUENCE seq_trip START WITH 1;

INSERT INTO vehicles VALUES (1,'ABC123', 10000, 8000);  -- 2000 since service
INSERT INTO vehicles VALUES (2,'XYZ789', 50000, 44000); -- 6000 since service (due)
INSERT INTO vehicles VALUES (3,'QWE456', 30000, 30000); -- 0
COMMIT;
-- trips added via pr_record_trip after trigger installation.

-- ============ (b) FUNCTION ============
CREATE OR REPLACE FUNCTION fn_service_due(p_vehicle_id NUMBER) RETURN BOOLEAN IS
  v_diff NUMBER;
BEGIN
  SELECT current_odometer - last_service_odometer INTO v_diff
    FROM vehicles WHERE vehicle_id = p_vehicle_id;
  RETURN v_diff >= 5000;
EXCEPTION WHEN NO_DATA_FOUND THEN
  RAISE_APPLICATION_ERROR(-20701,'Unknown vehicle');
END;
/

-- ============ (c) PROCEDURE ============
CREATE OR REPLACE PROCEDURE pr_record_trip(
  p_vehicle_id NUMBER, p_trip_on DATE, p_start NUMBER, p_end NUMBER) IS
BEGIN
  IF NOT EXISTS (SELECT 1 FROM vehicles WHERE vehicle_id = p_vehicle_id) THEN
    RAISE_APPLICATION_ERROR(-20702,'Unknown vehicle');
  END IF;
  IF p_end IS NULL OR p_start IS NULL OR p_end <= p_start THEN
    RAISE_APPLICATION_ERROR(-20703,'Invalid mileage');
  END IF;
  INSERT INTO trips(trip_id, vehicle_id, trip_on, start_odometer, end_odometer)
    VALUES (seq_trip.NEXTVAL, p_vehicle_id, p_trip_on, p_start, p_end);
  COMMIT;
END;
/

-- ============ (d) TRIGGER ============
CREATE OR REPLACE TRIGGER trg_trip_odo
BEFORE INSERT ON trips
FOR EACH ROW
DECLARE
  v_current NUMBER;
BEGIN
  SELECT current_odometer INTO v_current FROM vehicles
    WHERE vehicle_id = :NEW.vehicle_id FOR UPDATE;
  IF :NEW.start_odometer <> v_current THEN
    RAISE_APPLICATION_ERROR(-20710,'Start odometer does not match vehicle current');
  END IF;
  IF :NEW.end_odometer <= :NEW.start_odometer THEN
    RAISE_APPLICATION_ERROR(-20711,'Invalid end odometer');
  END IF;
  UPDATE vehicles SET current_odometer = :NEW.end_odometer
    WHERE vehicle_id = :NEW.vehicle_id;
END;
/

-- Add trips via procedure now:
BEGIN
  pr_record_trip(1, DATE '2024-05-01', 10000, 10500);
  pr_record_trip(1, DATE '2024-05-02', 10500, 11000);
  pr_record_trip(2, DATE '2024-05-01', 50000, 51000);
  pr_record_trip(2, DATE '2024-05-02', 51000, 52000);
  pr_record_trip(3, DATE '2024-05-01', 30000, 30500);
  pr_record_trip(3, DATE '2024-05-02', 30500, 31000);
END;
/

-- ============ (e) VIEW ============
CREATE OR REPLACE VIEW v_service_due AS
SELECT registration, (current_odometer - last_service_odometer) AS km_since_service
FROM vehicles
WHERE current_odometer - last_service_odometer >= 5000;

-- ============ (f) INDEX ============
CREATE INDEX ix_trips_veh_date ON trips(vehicle_id, trip_on);
-- Justification: one vehicle's trips over a date range.
EXPLAIN PLAN FOR
  SELECT * FROM trips WHERE vehicle_id = 1 AND trip_on BETWEEN DATE '2024-05-01' AND DATE '2024-05-31';
SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY);

-- ============ (g) SCHEDULED JOB ============
CREATE OR REPLACE PROCEDURE pr_refresh_service_alerts IS
BEGIN
  -- upsert due
  MERGE INTO service_alerts s
  USING (SELECT vehicle_id, (current_odometer - last_service_odometer) diff
         FROM vehicles WHERE current_odometer - last_service_odometer >= 5000) x
  ON (s.vehicle_id = x.vehicle_id)
  WHEN MATCHED THEN UPDATE SET km_since_service = x.diff, flagged_on = TRUNC(SYSDATE)
  WHEN NOT MATCHED THEN INSERT(vehicle_id, km_since_service, flagged_on)
       VALUES(x.vehicle_id, x.diff, TRUNC(SYSDATE));
  -- remove no-longer-due
  DELETE FROM service_alerts s
   WHERE EXISTS (SELECT 1 FROM vehicles v
                  WHERE v.vehicle_id = s.vehicle_id
                    AND v.current_odometer - v.last_service_odometer < 5000);
  COMMIT;
END;
/

BEGIN
  DBMS_SCHEDULER.CREATE_JOB(
    job_name        => 'JOB_SERVICE_ALERTS',
    job_type        => 'PLSQL_BLOCK',
    job_action      => 'BEGIN pr_refresh_service_alerts; END;',
    start_date      => SYSTIMESTAMP,
    repeat_interval => 'FREQ=WEEKLY;BYDAY=MON;BYHOUR=6;BYMINUTE=0;BYSECOND=0',
    enabled         => TRUE);
END;
/