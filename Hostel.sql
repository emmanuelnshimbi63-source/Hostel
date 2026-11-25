Hostel Room Allocation
DROP SCHEMA IF EXISTS q5_hostel CASCADE;
CREATE SCHEMA q5_hostel;
SET search_path TO q5_hostel;

(a) Tables and data
CREATE TABLE students (
    student_id     SERIAL PRIMARY KEY,
    student_number VARCHAR(20) UNIQUE NOT NULL,
    full_name      VARCHAR(100) NOT NULL
);
CREATE TABLE rooms (
    room_id     SERIAL PRIMARY KEY,
    room_number VARCHAR(10) UNIQUE NOT NULL,
    capacity    INT NOT NULL CHECK (capacity > 0)
);
CREATE TABLE allocations (
    allocation_id SERIAL PRIMARY KEY,
    student_id    INT NOT NULL REFERENCES students(student_id),
    room_id       INT NOT NULL REFERENCES rooms(room_id),
    allocated_on  DATE NOT NULL,
    released_on   DATE,
    status        VARCHAR(10) NOT NULL CHECK (status IN ('ACTIVE','ENDED')),
    CHECK ((status = 'ACTIVE' AND released_on IS NULL)
        OR (status = 'ENDED'  AND released_on IS NOT NULL))
);
CREATE TABLE occupancy_snapshot (
    snapshot_date DATE NOT NULL,
    room_id       INT NOT NULL REFERENCES rooms(room_id),
    occupied_beds INT NOT NULL,
    free_beds     INT NOT NULL,
    PRIMARY KEY (snapshot_date, room_id)
);

INSERT INTO students (student_number, full_name) VALUES
('S001','Alice'), ('S002','Brian'), ('S003','Grace'), ('S004','David');
INSERT INTO rooms (room_number, capacity) VALUES
('R101', 2), ('R102', 3), ('R103', 2);

(b) Function: free beds
CREATE FUNCTION fn_free_beds(p_room_id INT) RETURNS INT AS $$
DECLARE v_cap INT;
BEGIN
    SELECT capacity INTO v_cap FROM rooms WHERE room_id = p_room_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown room';
    END IF;
    RETURN v_cap - (SELECT COUNT(*) FROM allocations
                    WHERE room_id = p_room_id AND status = 'ACTIVE')::INT;
END;
$$ LANGUAGE plpgsql;

(c) Procedure: allocate a room
CREATE PROCEDURE pr_allocate_room(p_student_id INT, p_room_id INT, p_allocated_on DATE)
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM students WHERE student_id = p_student_id) THEN
        RAISE EXCEPTION 'Unknown student';
    END IF;
    IF EXISTS (SELECT 1 FROM allocations
               WHERE student_id = p_student_id AND status = 'ACTIVE') THEN
        RAISE EXCEPTION 'Student already has an ACTIVE allocation';
    END IF;
    IF fn_free_beds(p_room_id) <= 0 THEN      -- also rejects an unknown room
        RAISE EXCEPTION 'Room is full';
    END IF;
    INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status)
    VALUES (p_student_id, p_room_id, p_allocated_on, NULL, 'ACTIVE');
END;
$$;

(d) Trigger: same rules for direct SQL
CREATE FUNCTION trg_alloc_fn() RETURNS TRIGGER AS $$
BEGIN
    IF NEW.status = 'ACTIVE' THEN
        IF EXISTS (SELECT 1 FROM allocations
                   WHERE student_id = NEW.student_id AND status = 'ACTIVE'
                     AND allocation_id <> NEW.allocation_id) THEN
            RAISE EXCEPTION 'Student already has an ACTIVE allocation';
        END IF;
        IF (SELECT COUNT(*) FROM allocations
            WHERE room_id = NEW.room_id AND status = 'ACTIVE'
              AND allocation_id <> NEW.allocation_id)
           >= (SELECT capacity FROM rooms WHERE room_id = NEW.room_id) THEN
            RAISE EXCEPTION 'Room is full';
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_alloc
BEFORE INSERT OR UPDATE ON allocations
FOR EACH ROW EXECUTE FUNCTION trg_alloc_fn();

(a) continued: load allocations
CALL pr_allocate_room(1, 1, '2026-09-01');   -- R101 (capacity 2)
CALL pr_allocate_room(2, 1, '2026-09-01');   -- R101 now full
CALL pr_allocate_room(3, 2, '2026-09-02');   -- R102 partly occupied
INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status)
VALUES (4, 2, '2026-02-01', '2026-06-30', 'ENDED');   -- history
-- R103 stays empty

SELECT * FROM allocations;
SELECT fn_free_beds(1), fn_free_beds(2), fn_free_beds(3);   -- 0, 2, 2
-- CALL pr_allocate_room(4, 1, CURRENT_DATE);   -- error: room full

(e) View: every room
CREATE VIEW v_room_occupancy AS
SELECT r.room_id, r.room_number, r.capacity,
       COUNT(a.allocation_id)              AS occupied_beds,
       r.capacity - COUNT(a.allocation_id) AS free_beds
FROM rooms r
LEFT JOIN allocations a ON a.room_id = r.room_id AND a.status = 'ACTIVE'
GROUP BY r.room_id, r.room_number, r.capacity;

SELECT * FROM v_room_occupancy;     -- R101 2/0, R102 1/2, R103 0/2

-- (f) Index: ACTIVE allocations by room
-- Justification: only ACTIVE rows use a bed, so this small index finds them fast.
CREATE INDEX idx_alloc_active_room ON allocations (room_id) WHERE status = 'ACTIVE';

SET enable_seqscan = off;
EXPLAIN SELECT * FROM allocations WHERE room_id = 1 AND status = 'ACTIVE';
SET enable_seqscan = on;

-- (g) Scheduled job: today's occupancy
CREATE PROCEDURE pr_refresh_occupancy()
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO occupancy_snapshot
    SELECT CURRENT_DATE, room_id, occupied_beds, free_beds
    FROM v_room_occupancy
    ON CONFLICT (snapshot_date, room_id) DO UPDATE
    SET occupied_beds = EXCLUDED.occupied_beds,
        free_beds     = EXCLUDED.free_beds;
END;
$$;

CALL pr_refresh_occupancy();
CALL pr_refresh_occupancy();        -- rerun: still 3 rows
SELECT * FROM occupancy_snapshot;

CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('refresh_occupancy', '55 23 * * *',
    $$CALL q5_hostel.pr_refresh_occupancy()$$);
SELECT * FROM cron.job;