-- ============ (a) TABLES & SEED ============
CREATE TABLE students (
  student_id     NUMBER PRIMARY KEY,
  student_number VARCHAR2(20) UNIQUE NOT NULL,
  full_name      VARCHAR2(100) NOT NULL
);
CREATE TABLE rooms (
  room_id     NUMBER PRIMARY KEY,
  room_number VARCHAR2(10) UNIQUE NOT NULL,
  capacity    NUMBER(3) NOT NULL CHECK (capacity > 0)
);
CREATE TABLE allocations (
  allocation_id NUMBER PRIMARY KEY,
  student_id    NUMBER NOT NULL REFERENCES students(student_id),
  room_id       NUMBER NOT NULL REFERENCES rooms(room_id),
  allocated_on  DATE NOT NULL,
  released_on   DATE NULL,
  status        VARCHAR2(6) NOT NULL CHECK (status IN ('ACTIVE','ENDED')),
  CONSTRAINT ck_rel CHECK (
    (status = 'ACTIVE' AND released_on IS NULL) OR
    (status = 'ENDED'  AND released_on IS NOT NULL))
);
CREATE TABLE occupancy_snapshot (
  snapshot_date DATE NOT NULL,
  room_id       NUMBER NOT NULL REFERENCES rooms(room_id),
  occupied_beds NUMBER DEFAULT 0,
  free_beds     NUMBER DEFAULT 0,
  PRIMARY KEY(snapshot_date, room_id)
);
CREATE SEQUENCE seq_alloc START WITH 1;

INSERT INTO students VALUES (1,'S1','Ann');
INSERT INTO students VALUES (2,'S2','Ben');
INSERT INTO students VALUES (3,'S3','Cat');
INSERT INTO rooms VALUES (1,'R101',2);
INSERT INTO rooms VALUES (2,'R102',1);
INSERT INTO rooms VALUES (3,'R103',3);
-- full room 2, partly occupied 1, empty 3
INSERT INTO allocations VALUES (seq_alloc.NEXTVAL,1,2, DATE '2024-01-01', NULL, 'ACTIVE');
INSERT INTO allocations VALUES (seq_alloc.NEXTVAL,2,1, DATE '2024-01-01', NULL, 'ACTIVE');
INSERT INTO allocations VALUES (seq_alloc.NEXTVAL,3,1, DATE '2023-09-01', DATE '2024-01-01', 'ENDED');
COMMIT;

-- ============ (b) FUNCTION ============
CREATE OR REPLACE FUNCTION fn_free_beds(p_room_id NUMBER) RETURN NUMBER IS
  v_cap NUMBER; v_used NUMBER;
BEGIN
  SELECT capacity INTO v_cap FROM rooms WHERE room_id = p_room_id;
  SELECT COUNT(*) INTO v_used FROM allocations
   WHERE room_id = p_room_id AND status = 'ACTIVE';
  RETURN v_cap - v_used;
EXCEPTION WHEN NO_DATA_FOUND THEN
  RAISE_APPLICATION_ERROR(-20401,'Unknown room');
END;
/

-- ============ (c) PROCEDURE ============
CREATE OR REPLACE PROCEDURE pr_allocate_room(
  p_student_id NUMBER, p_room_id NUMBER, p_allocated_on DATE) IS
  v_free NUMBER; v_active NUMBER;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM students WHERE student_id = p_student_id) THEN
    RAISE_APPLICATION_ERROR(-20402,'Unknown student');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM rooms WHERE room_id = p_room_id) THEN
    RAISE_APPLICATION_ERROR(-20403,'Unknown room');
  END IF;
  SELECT COUNT(*) INTO v_active FROM allocations
   WHERE student_id = p_student_id AND status = 'ACTIVE';
  IF v_active > 0 THEN
    RAISE_APPLICATION_ERROR(-20404,'Student already has active allocation');
  END IF;
  v_free := fn_free_beds(p_room_id);
  IF v_free <= 0 THEN
    RAISE_APPLICATION_ERROR(-20405,'Room is full');
  END IF;
  INSERT INTO allocations(allocation_id,student_id,room_id,allocated_on,released_on,status)
    VALUES (seq_alloc.NEXTVAL,p_student_id,p_room_id,p_allocated_on,NULL,'ACTIVE');
  COMMIT;
END;
/

-- ============ (d) TRIGGER (defence in depth) ============
CREATE OR REPLACE TRIGGER trg_alloc_check
BEFORE INSERT OR UPDATE ON allocations
FOR EACH ROW
WHEN (NEW.status = 'ACTIVE')
DECLARE
  v_cap NUMBER; v_used NUMBER; v_other NUMBER;
BEGIN
  -- capacity
  SELECT capacity INTO v_cap FROM rooms WHERE room_id = :NEW.room_id;
  SELECT COUNT(*) INTO v_used FROM allocations
   WHERE room_id = :NEW.room_id AND status = 'ACTIVE'
     AND allocation_id <> NVL(:NEW.allocation_id,-1);
  IF v_used >= v_cap THEN
    RAISE_APPLICATION_ERROR(-20410,'Room capacity exceeded');
  END IF;
  -- one active per student
  SELECT COUNT(*) INTO v_other FROM allocations
   WHERE student_id = :NEW.student_id AND status = 'ACTIVE'
     AND allocation_id <> NVL(:NEW.allocation_id,-1);
  IF v_other > 0 THEN
    RAISE_APPLICATION_ERROR(-20411,'Student already active');
  END IF;
END;
/

-- ============ (e) VIEW ============
CREATE OR REPLACE VIEW v_room_occupancy AS
SELECT r.room_number, r.capacity,
       NVL(SUM(CASE WHEN a.status='ACTIVE' THEN 1 ELSE 0 END),0) occupied_beds,
       r.capacity - NVL(SUM(CASE WHEN a.status='ACTIVE' THEN 1 ELSE 0 END),0) free_beds
FROM rooms r
LEFT JOIN allocations a ON a.room_id = r.room_id
GROUP BY r.room_id, r.room_number, r.capacity;

-- ============ (f) INDEX ============
CREATE INDEX ix_alloc_room_status ON allocations(room_id, status);
-- Justification: filtering ACTIVE allocations by room_id (capacity checks / dashboards).
EXPLAIN PLAN FOR
  SELECT * FROM allocations WHERE room_id = 1 AND status = 'ACTIVE';
SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY);

-- ============ (g) SCHEDULED JOB ============
CREATE OR REPLACE PROCEDURE pr_refresh_occupancy IS
BEGIN
  FOR r IN (SELECT room_id, capacity FROM rooms) LOOP
    DECLARE
      v_used NUMBER;
    BEGIN
      SELECT COUNT(*) INTO v_used FROM allocations
       WHERE room_id = r.room_id AND status = 'ACTIVE';
      MERGE INTO occupancy_snapshot o
      USING (SELECT TRUNC(SYSDATE) snap, r.room_id rid FROM dual) s
      ON (o.snapshot_date = s.snap AND o.room_id = s.rid)
      WHEN MATCHED THEN UPDATE SET occupied_beds = v_used,
                                    free_beds = r.capacity - v_used
      WHEN NOT MATCHED THEN INSERT(snapshot_date,room_id,occupied_beds,free_beds)
           VALUES(TRUNC(SYSDATE), r.room_id, v_used, r.capacity - v_used);
    END;
  END LOOP;
  COMMIT;
END;
/

BEGIN
  DBMS_SCHEDULER.CREATE_JOB(
    job_name        => 'JOB_REFRESH_OCCUPANCY',
    job_type        => 'PLSQL_BLOCK',
    job_action      => 'BEGIN pr_refresh_occupancy; END;',
    start_date      => SYSTIMESTAMP,
    repeat_interval => 'FREQ=DAILY;BYHOUR=23;BYMINUTE=55;BYSECOND=0',
    enabled         => TRUE);
END;
/