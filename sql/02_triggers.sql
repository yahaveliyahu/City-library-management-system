-- =============================================
-- City Library Management System — Triggers
-- =============================================
-- Uses CREATE OR REPLACE TRIGGER (PostgreSQL 14+), so this file
-- is idempotent on its own without needing DROP TRIGGER statements.

BEGIN;

-- ---------------------------------------------
-- 1) Keep copy.status in sync with loans
--    Uses OLD vs NEW (not just NEW) so this only fires on the actual
--    "just got returned" transition, not on every UPDATE that merely
--    touches the returned_at column.
-- ---------------------------------------------
CREATE OR REPLACE FUNCTION trg_copy_status_from_loan() RETURNS trigger AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    UPDATE copy SET status = 'on_loan' WHERE copy_id = NEW.copy_id;
  ELSIF TG_OP = 'UPDATE' AND OLD.returned_at IS NULL AND NEW.returned_at IS NOT NULL THEN
    UPDATE copy c
    SET status = CASE
        WHEN EXISTS (
          SELECT 1 FROM reservation r
          WHERE r.copy_id = c.copy_id AND r.fulfilled_at IS NULL
        ) THEN 'reserved'
        ELSE 'available'
      END
    WHERE c.copy_id = NEW.copy_id;
  END IF;
  RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE TRIGGER loan_copy_status_ai
AFTER INSERT ON loan
FOR EACH ROW EXECUTE FUNCTION trg_copy_status_from_loan();

CREATE OR REPLACE TRIGGER loan_copy_status_au
AFTER UPDATE OF returned_at ON loan
FOR EACH ROW EXECUTE FUNCTION trg_copy_status_from_loan();

-- ---------------------------------------------
-- 2) Keep copy.status in sync with reservations
--
--    FIX: the INSERT branch now only flips status to 'reserved' when the
--    copy is currently 'available'. Previously it unconditionally
--    overwrote status on INSERT — so reserving a copy that was
--    currently on loan silently erased the 'on_loan' status, even
--    though the copy was still out with a borrower. Reserving a copy
--    that's on loan is normal (that's the point of a reservation); the
--    copy should stay 'on_loan' until it's actually returned, at which
--    point loan_copy_status_au already checks for an open reservation
--    and moves it to 'reserved' then.
-- ---------------------------------------------
CREATE OR REPLACE FUNCTION trg_copy_status_from_reservation() RETURNS trigger AS $$
BEGIN
  IF TG_OP = 'INSERT' AND NEW.fulfilled_at IS NULL THEN
    UPDATE copy
    SET status = 'reserved'
    WHERE copy_id = NEW.copy_id
      AND status = 'available';
  ELSIF TG_OP = 'UPDATE' AND OLD.fulfilled_at IS NULL AND NEW.fulfilled_at IS NOT NULL THEN
    UPDATE copy c
    SET status = CASE
        WHEN EXISTS (
          SELECT 1 FROM loan l
          WHERE l.copy_id = c.copy_id AND l.returned_at IS NULL
        ) THEN 'on_loan'
        ELSE 'available'
      END
    WHERE c.copy_id = NEW.copy_id;
  END IF;
  RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE TRIGGER reservation_copy_status_ai
AFTER INSERT ON reservation
FOR EACH ROW EXECUTE FUNCTION trg_copy_status_from_reservation();

CREATE OR REPLACE TRIGGER reservation_copy_status_au
AFTER UPDATE OF fulfilled_at ON reservation
FOR EACH ROW EXECUTE FUNCTION trg_copy_status_from_reservation();

-- ---------------------------------------------
-- 3) Auto-create a fine when a loan is returned late (one per loan)
-- ---------------------------------------------
CREATE OR REPLACE FUNCTION trg_fine_on_late_return() RETURNS trigger AS $$
DECLARE
  days_late int;
  fine_amt  numeric(10,2);
BEGIN
  IF OLD.returned_at IS NULL
     AND NEW.returned_at IS NOT NULL
     AND NEW.returned_at > NEW.due_at THEN
    days_late := GREATEST(1, CEIL(EXTRACT(EPOCH FROM (NEW.returned_at - NEW.due_at)) / 86400.0));
    fine_amt  := ROUND(days_late * 1.50::numeric, 2); -- $1.50/day late
    INSERT INTO fine(loan_id, amount)
    SELECT NEW.loan_id, fine_amt
    ON CONFLICT (loan_id) DO NOTHING; -- respect uq_fine_one_per_loan_idx
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE TRIGGER fine_on_late_return
AFTER UPDATE OF returned_at ON loan
FOR EACH ROW EXECUTE FUNCTION trg_fine_on_late_return();

-- ---------------------------------------------
-- 4) BEFORE INSERT guard on loan: block bad loans up front instead of
--    relying only on the unique index / a raw constraint violation.
--    Enforces two business rules:
--      a) a copy already on loan, or reserved for someone else, can't
--         be lent out
--      b) a member with more than $20 in unpaid fines can't take out
--         a new loan
-- ---------------------------------------------
CREATE OR REPLACE FUNCTION trg_before_loan_insert() RETURNS trigger AS $$
DECLARE
  v_copy_status         text;
  v_reserved_for_other  boolean;
  v_unpaid_fines        numeric(10,2);
BEGIN
  SELECT status INTO v_copy_status FROM copy WHERE copy_id = NEW.copy_id;

  IF v_copy_status = 'on_loan' THEN
    RAISE EXCEPTION 'Copy % is already on loan', NEW.copy_id;
  END IF;

  IF v_copy_status = 'reserved' THEN
    SELECT EXISTS (
      SELECT 1 FROM reservation
      WHERE copy_id = NEW.copy_id
        AND fulfilled_at IS NULL
        AND member_id <> NEW.member_id
    ) INTO v_reserved_for_other;

    IF v_reserved_for_other THEN
      RAISE EXCEPTION 'Copy % is reserved for another member', NEW.copy_id;
    END IF;
  END IF;

  SELECT COALESCE(SUM(f.amount), 0)
  INTO v_unpaid_fines
  FROM fine f
  JOIN loan l ON l.loan_id = f.loan_id
  WHERE l.member_id = NEW.member_id AND f.paid_at IS NULL;

  IF v_unpaid_fines > 20.00 THEN
    RAISE EXCEPTION 'Member % has $% in unpaid fines (limit is $20.00)',
      NEW.member_id, v_unpaid_fines;
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE TRIGGER loan_before_insert_check
BEFORE INSERT ON loan
FOR EACH ROW EXECUTE FUNCTION trg_before_loan_insert();

COMMIT;
