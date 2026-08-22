-- =============================================
-- City Library Management System — Seed Data
-- =============================================
-- Run after 01_schema.sql, 02_triggers.sql, 03_views_and_functions.sql.
--
-- Design notes:
--  - Loan returns are performed as real UPDATEs (not baked into the
--    initial INSERT), so the copy-status and fine-on-late-return
--    triggers actually fire while this data is being generated.
--  - Reservations are assigned by copy_id deterministically, not
--    filtered to "whatever copies happen to be free right now" — the
--    reservation trigger fix (see 02_triggers.sql) means reserving a
--    copy that's currently on loan no longer corrupts its status, so
--    reservations can safely land on any copy, which also guarantees
--    the exact row count below regardless of how the loan data landed.
--  - Fine payment dates are always created_at + a positive offset, so
--    they can never violate the paid_at >= created_at check.

BEGIN;

SELECT setseed(0.42);

-- 15 branches across the city (a real municipal system runs this many
-- or more — this is not padded, just realistic).
WITH b(name, address) AS (
  VALUES
    ('Central Library',   '100 Main St'),
    ('North Branch',      '55 Oak Ave'),
    ('South Branch',      '12 Cedar Rd'),
    ('East Branch',       '77 Pine Blvd'),
    ('West Branch',       '9 Maple Court'),
    ('Riverside Branch',  '210 River Rd'),
    ('Hillcrest Branch',  '48 Hillcrest Dr'),
    ('Lakeside Branch',   '33 Lakeshore Ave'),
    ('Downtown Branch',   '5 Market Sq'),
    ('Uptown Branch',     '88 Broadway'),
    ('Greenwood Branch',  '17 Greenwood Ln'),
    ('Harborview Branch', '61 Harbor St'),
    ('Meadowbrook Branch','22 Meadow Way'),
    ('Sunnyside Branch',  '140 Sunnyside Blvd'),
    ('Old Town Branch',   '3 Heritage Sq')
)
INSERT INTO branch(name, address)
SELECT name, address FROM b;

-- 25 members
-- Paired 1:1 by position (WITH ORDINALITY), not cross-joined — an
-- unordered CROSS JOIN + LIMIT here would exhaust every last name
-- against the first first name before moving on, so every member
-- would end up named "Alex ___".
WITH firsts AS (
  SELECT * FROM unnest(ARRAY[
    'Alex','Taylor','Jordan','Casey','Morgan','Sam','Jamie','Riley','Avery','Quinn',
    'Cameron','Drew','Elliot','Kai','Logan','Parker','Rowan','Shawn','Skye','Toby',
    'Eden','Hayden','Jules','Kendall','Reese'
  ]) WITH ORDINALITY AS f(first_name, idx)
), lasts AS (
  SELECT * FROM unnest(ARRAY[
    'Adams','Baker','Clark','Diaz','Evans','Foster','Garcia','Hughes','Iverson','Jones',
    'Kim','Lopez','Miller','Nguyen','Owens','Patel','Quintero','Reed','Singh','Turner',
    'Upton','Vega','White','Xu','Young'
  ]) WITH ORDINALITY AS l(last_name, idx)
)
INSERT INTO member(name, phone, email, active)
SELECT
  f.first_name || ' ' || l.last_name AS name,
  '+1-555-' || lpad(((1000 + f.idx * 37) % 9000)::text, 4, '0') AS phone,
  lower(f.first_name || '.' || l.last_name) || '@example.com' AS email,
  (random() > 0.08) AS active
FROM firsts f
JOIN lasts l ON f.idx = l.idx;

-- 20 authors
WITH a(n) AS (
  SELECT unnest(ARRAY[
    'Harper Stone','Maya Brook','Ethan Vale','Nora Quinn','Liam North','Isla Pierce',
    'Owen Hale','Zara Flynn','Miles Hart','Clara Wade','Ronan Blake','Ivy Rhodes',
    'Soren Pike','Ada Finch','Jonah Cross','Lena Frost','Felix Ward','Iris Beck',
    'Noah Chase','Tess Monroe'
  ])
)
INSERT INTO author(name)
SELECT n FROM a;

-- 25 books
WITH titles(t) AS (
  SELECT unnest(ARRAY[
    'The Silent Archive','Echoes of Time','Branches and Bindings','Cedar Street Tales',
    'Notes from the West','East of Main','Under Oak Skies','The Last Borrower',
    'Stacks at Midnight','Pinecone Path','Maple & Ink','Letters to North',
    'Southbound Stories','Between Shelves','The Missing Copy','Barcode Dreams',
    'Due Tomorrow','Return Receipt','Hold Request','Overdue Hearts',
    'Coded Pages','Aisle of Secrets','Index of Wonders','The Loan That Wasn''t',
    'Footnotes in June'
  ])
)
INSERT INTO book(title, publish_year, genre)
SELECT
  t,
  (1950 + floor(random()*75))::int,
  (ARRAY['Fiction','Sci-Fi','History','Mystery','Fantasy','Non-Fiction','Poetry'])[1 + floor(random()*7)]
FROM titles;

-- Book-Author links (each book gets 1-3 authors)
-- NOTE: ORDER BY random() inside a LATERAL subquery that never actually
-- references the outer row (book.*) is not truly correlated — Postgres'
-- planner is free to evaluate it once and reuse that single result for
-- every book, which is exactly what happened here: all 25 books ended
-- up with the identical 3 authors. Ordering by a hash of book_id makes
-- the subquery genuinely depend on the outer row, so it varies per book
-- (and is reproducibly deterministic, not just "random").
INSERT INTO book_author(book_id, author_id)
SELECT b.book_id, a.author_id
FROM book b
CROSS JOIN LATERAL (
  SELECT author_id
  FROM author
  ORDER BY md5(b.book_id::text || '-' || author_id::text)
  LIMIT 1 + (b.book_id % 3)
) a
ON CONFLICT DO NOTHING;

-- 45 copies across the 15 branches, barcode generated inline
-- (no separate UPDATE needed, so no window-function-in-UPDATE risk)
INSERT INTO copy(book_id, branch_id, status, barcode)
SELECT
  ((n - 1) % 25) + 1,
  ((n - 1) % 15) + 1,
  'available',
  'COPY-' || lpad(n::text, 5, '0')
FROM generate_series(1, 45) AS g(n);

-- ---------------------------------------------
-- 30 loans, one per copy on copies 1-30, inserted OPEN first so
-- loan_before_insert_check and loan_copy_status_ai both run for real.
-- ---------------------------------------------
INSERT INTO loan(copy_id, member_id, loaned_at, due_at)
SELECT
  n AS copy_id,
  ((n - 1) % 25) + 1 AS member_id,
  NOW() - (5 + (n % 20)) * INTERVAL '1 day' AS loaned_at,
  NOW() - (5 + (n % 20)) * INTERVAL '1 day' + INTERVAL '14 days' AS due_at
FROM generate_series(1, 30) AS g(n);

-- "Return" 18 of the 30 loans via a real UPDATE, so the AFTER triggers
-- (copy-status sync + fine-on-late-return) fire during seeding. The
-- offset mix (3 to 22 days after loaned_at against a 14-day due date)
-- naturally produces both on-time and late returns.
UPDATE loan l
SET returned_at = l.loaned_at + (3 + (l.loan_id % 20)) * INTERVAL '1 day'
WHERE l.loan_id <= 18;

-- Mark the resulting fines paid in roughly half the cases. The offset
-- is always positive, so paid_at >= created_at can never be violated.
UPDATE fine
SET paid_at = created_at + (1 + (fine_id % 5)) * INTERVAL '1 day'
WHERE fine_id % 2 = 0;

-- ---------------------------------------------
-- 20 reservations, one per copy on copies 1-20 — assigned by copy_id
-- regardless of current loan status. This is deterministic (always
-- exactly 20 rows) and realistic: reserving a copy that's currently on
-- loan is normal library behavior, not an edge case to avoid.
-- ---------------------------------------------
INSERT INTO reservation(copy_id, member_id, reserved_at, fulfilled_at)
SELECT
  n AS copy_id,
  ((n + 6) % 25) + 1 AS member_id,
  NOW() - (n % 10) * INTERVAL '1 day' AS reserved_at,
  CASE WHEN n % 4 = 0
    THEN NOW() - (n % 10) * INTERVAL '1 day' + (1 + (n % 3)) * INTERVAL '1 day'
    ELSE NULL
  END AS fulfilled_at
FROM generate_series(1, 20) AS g(n);

COMMIT;
