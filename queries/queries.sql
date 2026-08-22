-- =============================================
-- City Library Management System — Required Queries
-- PostgreSQL
-- =============================================
-- Curated from two sources: the author's own draft queries and a
-- ChatGPT-assisted draft. Each query below was picked because it's the
-- strongest example of its category and was verified to actually run
-- and return sensible rows against this schema — some queries from
-- both original drafts were dropped for being redundant with a
-- stronger version, or (in one case) for referencing a member name
-- that doesn't exist in this seed data.

-- ---------------------------------------------
-- Simple SELECT + WHERE
-- ---------------------------------------------

-- 1. Mystery books published between 2000 and 2015.
SELECT *
FROM book
WHERE genre = 'Mystery'
  AND publish_year BETWEEN 2000 AND 2015;

-- 2. Active members whose email is on the example.com domain.
SELECT member_id, name, email
FROM member
WHERE active = TRUE
  AND email LIKE '%@example.com';

-- ---------------------------------------------
-- JOINs across two or more tables
-- ---------------------------------------------

-- 3. Every book with its author(s), via the book_author link table.
SELECT b.title, a.name AS author
FROM book b
JOIN book_author ba ON ba.book_id = b.book_id
JOIN author a ON a.author_id = ba.author_id
ORDER BY b.title, a.name;

-- 4. Members who currently have a book out (four-table join).
SELECT m.name AS member_name,
       bk.title,
       l.loaned_at,
       l.due_at
FROM loan l
JOIN member m ON m.member_id = l.member_id
JOIN copy c ON c.copy_id = l.copy_id
JOIN book bk ON bk.book_id = c.book_id
WHERE l.returned_at IS NULL
ORDER BY l.due_at;

-- ---------------------------------------------
-- GROUP BY + aggregation
-- ---------------------------------------------

-- 5. Loans per genre in the last 30 days.
SELECT b.genre, COUNT(*) AS loans_last_30d
FROM loan l
JOIN copy c ON c.copy_id = l.copy_id
JOIN book b ON b.book_id = c.book_id
WHERE l.loaned_at >= NOW() - INTERVAL '30 days'
GROUP BY b.genre
ORDER BY loans_last_30d DESC NULLS LAST;

-- ---------------------------------------------
-- GROUP BY + HAVING
-- ---------------------------------------------

-- 6. Authors whose books have been loaned more than once in total.
SELECT a.name, COUNT(*) AS total_loans
FROM loan l
JOIN copy c ON c.copy_id = l.copy_id
JOIN book_author ba ON ba.book_id = c.book_id
JOIN author a ON a.author_id = ba.author_id
GROUP BY a.name
HAVING COUNT(*) > 1
ORDER BY total_loans DESC;

-- ---------------------------------------------
-- Nested / subqueries
-- ---------------------------------------------

-- 7. Books with more copies than the average number of copies per book
--    (subquery inside a subquery: average-of-counts, then filtered by HAVING).
SELECT bk.book_id,
       bk.title,
       COUNT(c.copy_id) AS copies
FROM book bk
JOIN copy c ON c.book_id = bk.book_id
GROUP BY bk.book_id, bk.title
HAVING COUNT(c.copy_id) > (
    SELECT AVG(copy_count)
    FROM (
        SELECT COUNT(*) AS copy_count
        FROM copy
        GROUP BY book_id
    ) AS counts_per_book
)
ORDER BY copies DESC;

-- 8. Books that have never been loaned (no copy of them ever appears in loan).
SELECT b.title
FROM book b
WHERE b.book_id NOT IN (
    SELECT DISTINCT c.book_id
    FROM loan l
    JOIN copy c ON c.copy_id = l.copy_id
);

-- ---------------------------------------------
-- Bonus queries
-- ---------------------------------------------

-- 9. Top 5 authors by number of distinct books.
-- (This exact query is what surfaced a real seeding bug during
-- development — see the "Engineering notes" section of the README.)
SELECT a.author_id,
       a.name,
       COUNT(DISTINCT ba.book_id) AS number_of_books
FROM author a
JOIN book_author ba ON ba.author_id = a.author_id
GROUP BY a.author_id, a.name
ORDER BY number_of_books DESC, a.name
LIMIT 5;

-- 10. Available copies of each book, per branch.
SELECT br.name AS branch, b.title, COUNT(*) AS available_copies
FROM copy c
JOIN book b ON b.book_id = c.book_id
JOIN branch br ON br.branch_id = c.branch_id
WHERE c.status = 'available'
GROUP BY br.name, b.title
ORDER BY br.name, b.title;

-- 11. Total unpaid fine amount for each member (only those who owe something).
SELECT m.member_id,
       m.name,
       COALESCE(SUM(f.amount), 0) AS unpaid_fines
FROM member m
LEFT JOIN loan l ON l.member_id = m.member_id
LEFT JOIN fine f ON f.loan_id = l.loan_id AND f.paid_at IS NULL
GROUP BY m.member_id, m.name
HAVING COALESCE(SUM(f.amount), 0) > 0
ORDER BY unpaid_fines DESC;

-- 12. All loans (past and present) for a specific member, by name.
-- Swap in any name that exists in your member table.
SELECT l.*
FROM loan l
JOIN member m ON m.member_id = l.member_id
WHERE m.name = 'Taylor Baker';

-- ---------------------------------------------
-- Database-changing query that fires a trigger
-- ---------------------------------------------

-- 13. Change an open loan into a late return — fine_on_late_return fires
-- automatically and inserts the matching fine row.
UPDATE loan
SET returned_at = due_at + INTERVAL '3 days'
WHERE loan_id = (
    SELECT loan_id
    FROM loan
    WHERE returned_at IS NULL
    ORDER BY loan_id
    LIMIT 1
);

-- Verify the trigger created the fine.
SELECT l.loan_id,
       l.due_at,
       l.returned_at,
       f.amount
FROM loan l
JOIN fine f ON f.loan_id = l.loan_id
WHERE l.loan_id = (
    SELECT MAX(loan_id)
    FROM loan
    WHERE returned_at IS NOT NULL
);
