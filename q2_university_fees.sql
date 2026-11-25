-- ICT371 Question 2: University Fee Payments (PostgreSQL)
DROP SCHEMA IF EXISTS q2 CASCADE;
CREATE SCHEMA q2;
SET search_path TO q2, public;

-- (a) TABLES -------------------------------------------------------------
CREATE TABLE students (
  student_id     INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  student_number VARCHAR(20) NOT NULL UNIQUE,
  full_name      VARCHAR(100) NOT NULL,
  fee_due        NUMERIC(12,2) NOT NULL CHECK (fee_due >= 0)
);

CREATE TABLE payments (
  payment_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  student_id INT NOT NULL REFERENCES students(student_id),
  amount     NUMERIC(12,2) NOT NULL CHECK (amount > 0),
  paid_on    DATE NOT NULL
);

CREATE TABLE payment_audit (
  audit_id   INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  payment_id INT NOT NULL REFERENCES payments(payment_id),
  student_id INT NOT NULL REFERENCES students(student_id),
  amount     NUMERIC(12,2) NOT NULL,
  logged_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE daily_collections (
  collection_date DATE PRIMARY KEY,
  payment_count   INT NOT NULL DEFAULT 0,
  total_amount    NUMERIC(12,2) NOT NULL DEFAULT 0
);

-- (b) FUNCTION -----------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_fee_balance(p_student_id INT)
RETURNS NUMERIC AS $$
DECLARE
  v_fee  NUMERIC;
  v_paid NUMERIC;
BEGIN
  SELECT fee_due INTO v_fee FROM students WHERE student_id = p_student_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown student: %', p_student_id;
  END IF;

  SELECT COALESCE(SUM(amount), 0) INTO v_paid FROM payments WHERE student_id = p_student_id;
  RETURN v_fee - v_paid;      -- full fee when there are no payments
END;
$$ LANGUAGE plpgsql STABLE;

-- (c) PROCEDURE (does NOT insert the audit row; the trigger does) --------
CREATE OR REPLACE PROCEDURE pr_receive_payment(p_student_id INT, p_amount NUMERIC, p_paid_on DATE)
AS $$
DECLARE
  v_balance NUMERIC;
BEGIN
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'Invalid payment amount: %', p_amount;
  END IF;
  IF p_paid_on IS NULL THEN
    RAISE EXCEPTION 'Payment date is required';
  END IF;

  -- lock the student so concurrent payments cannot overpay
  PERFORM 1 FROM students WHERE student_id = p_student_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown student: %', p_student_id;
  END IF;

  v_balance := fn_fee_balance(p_student_id);
  IF p_amount > v_balance THEN
    RAISE EXCEPTION 'Payment % exceeds outstanding balance %', p_amount, v_balance;
  END IF;

  INSERT INTO payments (student_id, amount, paid_on)
  VALUES (p_student_id, p_amount, p_paid_on);   -- fee_due is not changed
END;
$$ LANGUAGE plpgsql;

-- (d) TRIGGER ------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_payment_audit() RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO payment_audit (payment_id, student_id, amount, logged_at)
  VALUES (NEW.payment_id, NEW.student_id, NEW.amount, now());
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_payment_audit
AFTER INSERT ON payments
FOR EACH ROW
EXECUTE FUNCTION trg_fn_payment_audit();

-- (g) PROCEDURE: refresh collections -------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_collections(p_day DATE)
AS $$
BEGIN
  INSERT INTO daily_collections (collection_date, payment_count, total_amount)
  SELECT p_day, COUNT(*), COALESCE(SUM(amount), 0)
  FROM payments WHERE paid_on = p_day
  ON CONFLICT (collection_date) DO UPDATE
    SET payment_count = EXCLUDED.payment_count,
        total_amount  = EXCLUDED.total_amount;
END;
$$ LANGUAGE plpgsql;

-- (a) SEED DATA ----------------------------------------------------------
-- Student 3 has no payments. Balances: S1 = 2000, S2 = 0 (settled), S3 = 2500.
INSERT INTO students (student_number, full_name, fee_due) VALUES
  ('2024001', 'Mwansa Banda',  5000.00),
  ('2024002', 'Chola Mumba',   3000.00),
  ('2024003', 'Temwa Phiri',   2500.00);

CALL pr_receive_payment(1, 1000, DATE '2026-11-20');
CALL pr_receive_payment(1, 1500, DATE '2026-11-21');
CALL pr_receive_payment(1,  500, DATE '2026-11-21');
CALL pr_receive_payment(2, 1000, DATE '2026-11-20');
CALL pr_receive_payment(2, 1000, DATE '2026-11-21');
CALL pr_receive_payment(2, 1000, DATE '2026-11-22');

SELECT * FROM payments ORDER BY payment_id;
SELECT * FROM payment_audit ORDER BY audit_id;     -- one row per payment (from the trigger)

-- tests (each should raise an error)
-- SELECT fn_fee_balance(3);                          -- 2500 (no payments)
-- SELECT fn_fee_balance(99);                         -- Unknown student
-- CALL pr_receive_payment(1, 0, CURRENT_DATE);       -- invalid amount
-- CALL pr_receive_payment(1, 99999, CURRENT_DATE);   -- above balance

-- (e) VIEW ---------------------------------------------------------------
CREATE OR REPLACE VIEW v_fee_balances AS
SELECT s.student_number, s.full_name,
       s.fee_due - COALESCE(SUM(p.amount), 0) AS outstanding_balance
FROM students s
LEFT JOIN payments p ON p.student_id = s.student_id
GROUP BY s.student_id, s.student_number, s.full_name, s.fee_due
HAVING s.fee_due - COALESCE(SUM(p.amount), 0) > 0;   -- settled students excluded

SELECT * FROM v_fee_balances;

-- (f) INDEX --------------------------------------------------------------
-- Equality on student_id first, range on paid_on second.
CREATE INDEX idx_payments_student_date ON payments (student_id, paid_on);

ANALYZE payments;
SET enable_seqscan = off;
EXPLAIN
SELECT * FROM payments
WHERE student_id = 1 AND paid_on BETWEEN DATE '2026-11-20' AND DATE '2026-11-22';
RESET enable_seqscan;

-- (g) TEST AND SCHEDULE --------------------------------------------------
CALL pr_refresh_collections(DATE '2026-11-20');
CALL pr_refresh_collections(DATE '2026-11-20');    -- rerun replaces the row
SELECT * FROM daily_collections;

CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('q2_refresh_collections', '0 1 * * *',
  $$CALL q2.pr_refresh_collections(CURRENT_DATE - 1)$$);
