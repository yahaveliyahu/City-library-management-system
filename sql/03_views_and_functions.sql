-- =============================================
-- City Library Management System — Views & Functions
-- =============================================

BEGIN;

-- Currently-open loans that are past their due date, with how overdue
CREATE OR REPLACE VIEW v_overdue_loans AS
SELECT
  l.loan_id,
  m.member_id,
  m.name        AS member_name,
  b.title       AS book_title,
  c.barcode,
  br.name       AS branch_name,
  l.due_at,
  NOW() - l.due_at AS overdue_by
FROM loan l
JOIN member m  ON m.member_id  = l.member_id
JOIN copy   c  ON c.copy_id    = l.copy_id
JOIN book   b  ON b.book_id    = c.book_id
JOIN branch br ON br.branch_id = c.branch_id
WHERE l.returned_at IS NULL
  AND l.due_at < NOW();

-- Per-member activity summary: active loans, total loans, unpaid fines
CREATE OR REPLACE VIEW v_member_activity AS
SELECT
  m.member_id,
  m.name,
  COUNT(DISTINCT l.loan_id) FILTER (WHERE l.returned_at IS NULL) AS active_loans,
  COUNT(DISTINCT l.loan_id)                                       AS total_loans,
  COALESCE(SUM(f.amount) FILTER (WHERE f.paid_at IS NULL), 0)     AS unpaid_fines
FROM member m
LEFT JOIN loan l ON l.member_id = m.member_id
LEFT JOIN fine f ON f.loan_id   = l.loan_id
GROUP BY m.member_id, m.name;

-- Renew an open loan by extending its due date, unless another member
-- is waiting on a reservation for that same copy. Returns the new due date.
CREATE OR REPLACE FUNCTION renew_loan(p_loan_id BIGINT, p_extra_days INT DEFAULT 14)
RETURNS TIMESTAMPTZ AS $$
DECLARE
  v_copy_id             BIGINT;
  v_member_id           BIGINT;
  v_returned_at         TIMESTAMPTZ;
  v_blocking_reservation BOOLEAN;
  v_new_due             TIMESTAMPTZ;
BEGIN
  SELECT copy_id, member_id, returned_at
  INTO v_copy_id, v_member_id, v_returned_at
  FROM loan
  WHERE loan_id = p_loan_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Loan % does not exist', p_loan_id;
  END IF;

  IF v_returned_at IS NOT NULL THEN
    RAISE EXCEPTION 'Loan % has already been returned, cannot renew', p_loan_id;
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM reservation r
    WHERE r.copy_id = v_copy_id
      AND r.fulfilled_at IS NULL
      AND r.member_id <> v_member_id
  ) INTO v_blocking_reservation;

  IF v_blocking_reservation THEN
    RAISE EXCEPTION 'Cannot renew loan %: another member has a pending reservation on this copy', p_loan_id;
  END IF;

  UPDATE loan
  SET due_at = due_at + (p_extra_days || ' days')::interval
  WHERE loan_id = p_loan_id
  RETURNING due_at INTO v_new_due;

  RETURN v_new_due;
END;
$$ LANGUAGE plpgsql;

COMMIT;
