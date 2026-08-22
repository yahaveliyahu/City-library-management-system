-- =============================================
-- City Library Management System — Schema
-- =============================================
-- Drops and recreates all tables. Safe to re-run.

BEGIN;

DROP TABLE IF EXISTS fine        CASCADE;
DROP TABLE IF EXISTS reservation CASCADE;
DROP TABLE IF EXISTS loan        CASCADE;
DROP TABLE IF EXISTS copy        CASCADE;
DROP TABLE IF EXISTS book_author CASCADE;
DROP TABLE IF EXISTS book        CASCADE;
DROP TABLE IF EXISTS author      CASCADE;
DROP TABLE IF EXISTS member      CASCADE;
DROP TABLE IF EXISTS branch      CASCADE;

CREATE TABLE branch (
  branch_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  name      TEXT NOT NULL UNIQUE,
  address   TEXT NOT NULL
);

CREATE TABLE member (
  member_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  name      TEXT NOT NULL,
  phone     TEXT UNIQUE,
  email     TEXT NOT NULL UNIQUE,
  active    BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE author (
  author_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  name      TEXT NOT NULL
);

CREATE TABLE book (
  book_id      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  title        TEXT NOT NULL UNIQUE,
  publish_year INT CHECK (publish_year BETWEEN 1000 AND 2100),
  genre        TEXT NOT NULL
);

CREATE TABLE book_author (
  book_id   BIGINT NOT NULL REFERENCES book(book_id)     ON DELETE CASCADE,
  author_id BIGINT NOT NULL REFERENCES author(author_id) ON DELETE CASCADE,
  PRIMARY KEY (book_id, author_id)
);

CREATE TABLE copy (
  copy_id   BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  book_id   BIGINT NOT NULL REFERENCES book(book_id)     ON DELETE RESTRICT,
  branch_id BIGINT NOT NULL REFERENCES branch(branch_id) ON DELETE RESTRICT,
  status    TEXT NOT NULL DEFAULT 'available',
  CHECK (status IN ('available', 'on_loan', 'reserved')),
  barcode   TEXT NOT NULL UNIQUE
);

CREATE TABLE loan (
  loan_id     BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  copy_id     BIGINT NOT NULL REFERENCES copy(copy_id)     ON DELETE RESTRICT,
  member_id   BIGINT NOT NULL REFERENCES member(member_id) ON DELETE RESTRICT,
  loaned_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  due_at      TIMESTAMPTZ NOT NULL DEFAULT (NOW() + INTERVAL '14 days'),
  returned_at TIMESTAMPTZ NULL,
  CHECK (due_at >= loaned_at),
  CHECK (returned_at IS NULL OR returned_at >= loaned_at)
);

CREATE TABLE reservation (
  res_id       BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  copy_id      BIGINT NOT NULL REFERENCES copy(copy_id)     ON DELETE CASCADE,
  member_id    BIGINT NOT NULL REFERENCES member(member_id) ON DELETE CASCADE,
  reserved_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  fulfilled_at TIMESTAMPTZ NULL,
  CHECK (fulfilled_at IS NULL OR fulfilled_at >= reserved_at)
);

CREATE TABLE fine (
  fine_id    BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  loan_id    BIGINT NOT NULL REFERENCES loan(loan_id) ON DELETE RESTRICT,
  amount     NUMERIC(10,2) NOT NULL CHECK (amount >= 0),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  paid_at    TIMESTAMPTZ NULL,
  CHECK (paid_at IS NULL OR paid_at >= created_at)
);

-- ---------- INDEXES ----------
CREATE INDEX IF NOT EXISTS idx_copy_book_branch
  ON copy(book_id, branch_id);

CREATE INDEX IF NOT EXISTS idx_book_genre_year
  ON book(genre, publish_year);

CREATE INDEX IF NOT EXISTS idx_loan_member_open
  ON loan(member_id) WHERE returned_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_reservation_copy_open
  ON reservation(copy_id) WHERE fulfilled_at IS NULL;

-- Business rules enforced at the index level
CREATE UNIQUE INDEX IF NOT EXISTS uq_copy_single_open_loan
  ON loan(copy_id) WHERE returned_at IS NULL;

CREATE UNIQUE INDEX IF NOT EXISTS uq_reservation_open_per_member
  ON reservation(copy_id, member_id) WHERE fulfilled_at IS NULL;

CREATE UNIQUE INDEX IF NOT EXISTS uq_fine_one_per_loan_idx
  ON fine(loan_id);

COMMIT;
