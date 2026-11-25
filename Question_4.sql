-- ============ (a) TABLES & SEED ============
CREATE TABLE patients (
  patient_id NUMBER PRIMARY KEY,
  full_name  VARCHAR2(100) NOT NULL
);
CREATE TABLE doctors (
  doctor_id NUMBER PRIMARY KEY,
  full_name VARCHAR2(100) NOT NULL
);
CREATE TABLE appointments (
  appointment_id NUMBER PRIMARY KEY,
  patient_id     NUMBER NOT NULL REFERENCES patients(patient_id),
  doctor_id      NUMBER NOT NULL REFERENCES doctors(doctor_id),
  appointment_day DATE NOT NULL,
  slot_time      TIMESTAMP NOT NULL,  -- OR use INTERVAL DAY TO SECOND? Use DATE+TIME via TIMESTAMP
  status         VARCHAR2(10) NOT NULL CHECK (status IN ('BOOKED','ATTENDED','CANCELLED'))
);
CREATE TABLE clinic_summary (
  summary_date DATE PRIMARY KEY,
  booked_count   NUMBER DEFAULT 0,
  attended_count NUMBER DEFAULT 0,
  cancelled_count NUMBER DEFAULT 0
);
CREATE SEQUENCE seq_appt START WITH 1;

INSERT INTO patients VALUES (1,'P One');
INSERT INTO patients VALUES (2,'P Two');
INSERT INTO patients VALUES (3,'P Three');
INSERT INTO doctors VALUES (1,'Dr A');
INSERT INTO doctors VALUES (2,'Dr B');
INSERT INTO doctors VALUES (3,'Dr C');

INSERT INTO appointments VALUES (seq_appt.NEXTVAL,1,1, DATE '2024-05-01', TIMESTAMP '2024-05-01 09:00:00','BOOKED');
INSERT INTO appointments VALUES (seq_appt.NEXTVAL,2,1, DATE '2024-05-01', TIMESTAMP '2024-05-01 10:00:00','BOOKED');
INSERT INTO appointments VALUES (seq_appt.NEXTVAL,3,1, DATE '2024-05-01', TIMESTAMP '2024-05-01 11:00:00','BOOKED');
INSERT INTO appointments VALUES (seq_appt.NEXTVAL,1,2, DATE '2024-05-01', TIMESTAMP '2024-05-01 09:00:00','BOOKED');
INSERT INTO appointments VALUES (seq_appt.NEXTVAL,2,2, DATE '2024-05-01', TIMESTAMP '2024-05-01 10:00:00','BOOKED');
INSERT INTO appointments VALUES (seq_appt.NEXTVAL,3,3, DATE '2024-05-01', TIMESTAMP '2024-05-01 09:00:00','BOOKED');
COMMIT;

-- ============ (b) FUNCTION ============
CREATE OR REPLACE FUNCTION fn_daily_load(p_doctor_id NUMBER, p_day DATE) RETURN NUMBER IS
  v_cnt NUMBER;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM doctors WHERE doctor_id = p_doctor_id) THEN
    RAISE_APPLICATION_ERROR(-20301,'Unknown doctor');
  END IF;
  SELECT COUNT(*) INTO v_cnt FROM appointments
   WHERE doctor_id = p_doctor_id AND appointment_day = TRUNC(p_day)
     AND status <> 'CANCELLED';
  RETURN v_cnt;
END;
/

-- ============ (c) PROCEDURE ============
CREATE OR REPLACE PROCEDURE pr_book_appointment(
  p_patient_id NUMBER, p_doctor_id NUMBER, p_day DATE, p_slot TIMESTAMP) IS
BEGIN
  IF NOT EXISTS (SELECT 1 FROM patients WHERE patient_id = p_patient_id) THEN
    RAISE_APPLICATION_ERROR(-20302,'Unknown patient');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM doctors WHERE doctor_id = p_doctor_id) THEN
    RAISE_APPLICATION_ERROR(-20303,'Unknown doctor');
  END IF;
  IF TRUNC(p_day) < TRUNC(SYSDATE) THEN
    RAISE_APPLICATION_ERROR(-20304,'Past date');
  END IF;
  IF TO_CHAR(p_slot,'HH24:MI') NOT IN ('09:00','10:00','11:00','12:00') THEN
    RAISE_APPLICATION_ERROR(-20305,'Unsupported slot');
  END IF;
  INSERT INTO appointments(appointment_id,patient_id,doctor_id,appointment_day,slot_time,status)
    VALUES (seq_appt.NEXTVAL,p_patient_id,p_doctor_id,TRUNC(p_day),p_slot,'BOOKED');
  COMMIT;
END;
/

-- ============ (d) TRIGGER (clash protection) ============
CREATE OR REPLACE TRIGGER trg_appt_clash
BEFORE INSERT OR UPDATE ON appointments
FOR EACH ROW
WHEN (NEW.status <> 'CANCELLED')
DECLARE
  v_clash NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_clash FROM appointments
   WHERE doctor_id = :NEW.doctor_id
     AND appointment_day = :NEW.appointment_day
     AND slot_time = :NEW.slot_time
     AND status <> 'CANCELLED'
     AND appointment_id <> NVL(:NEW.appointment_id,-1);
  IF v_clash > 0 THEN
    RAISE_APPLICATION_ERROR(-20310,'Slot clash for this doctor');
  END IF;
END;
/

-- ============ (e) VIEW ============
CREATE OR REPLACE VIEW v_today_appointments AS
SELECT p.full_name AS patient_name, d.full_name AS doctor_name, a.slot_time
FROM appointments a
JOIN patients p ON p.patient_id = a.patient_id
JOIN doctors  d ON d.doctor_id  = a.doctor_id
WHERE a.appointment_day = TRUNC(SYSDATE) AND a.status = 'BOOKED';

-- ============ (f) INDEX ============
CREATE INDEX ix_appt_day_doc ON appointments(appointment_day, doctor_id);
-- Justification: reports filter by appointment_day and doctor_id.
EXPLAIN PLAN FOR
  SELECT * FROM appointments WHERE appointment_day = DATE '2024-05-01' AND doctor_id = 1;
SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY);

-- ============ (g) SCHEDULED JOB ============
CREATE OR REPLACE PROCEDURE pr_refresh_clinic_summary(p_day DATE) IS
BEGIN
  MERGE INTO clinic_summary c
  USING (SELECT TRUNC(p_day) summary_date,
                COUNT(CASE WHEN status='BOOKED'   THEN 1 END) booked_count,
                COUNT(CASE WHEN status='ATTENDED' THEN 1 END) attended_count,
                COUNT(CASE WHEN status='CANCELLED' THEN 1 END) cancelled_count
         FROM appointments WHERE appointment_day = TRUNC(p_day)) s
  ON (c.summary_date = s.summary_date)
  WHEN MATCHED THEN UPDATE SET booked_count=s.booked_count,
                               attended_count=s.attended_count,
                               cancelled_count=s.cancelled_count
  WHEN NOT MATCHED THEN INSERT(summary_date,booked_count,attended_count,cancelled_count)
       VALUES(s.summary_date,s.booked_count,s.attended_count,s.cancelled_count);
  COMMIT;
END;
/

BEGIN
  DBMS_SCHEDULER.CREATE_JOB(
    job_name        => 'JOB_REFRESH_CLINIC',
    job_type        => 'PLSQL_BLOCK',
    job_action      => 'BEGIN pr_refresh_clinic_summary(TRUNC(SYSDATE)-1); END;',
    start_date      => SYSTIMESTAMP,
    repeat_interval => 'FREQ=DAILY;BYHOUR=1;BYMINUTE=0;BYSECOND=0',
    enabled         => TRUE);
END;
/