-- The own date of every payment of an instalment service (Split) and the minimum payments of a
-- credit card typed from the bank's statement. Forward only.
--
-- Additive only, like 0004 to 0024: one new column that starts empty, one new table with its
-- triggers, and no data step. No row is inserted or updated, so every debt and every card the
-- update finds reads exactly as it did. No CHECK on the added column: adding one checks every
-- other CHECK of the table again, and the old rows leave the column empty anyway.
--
-- Needs SQLite 3.37 or later, as 0004 to 0024 do.

-- 1. The date of a payment -----------------------------------------------------------------------
-- A due of a plan that is not monthly or every few days from a first day: the service names each
-- payment's day. The step of due `from_index` (0 the first) holds that due's own `due_on`, a day
-- `YYYY-MM-DD`; the sums and the dates of a service are typed once, in the same rows. NULL: the
-- due falls where the debt's own schedule (`payment_day`, `steps`) puts it, as every step
-- written before this file does.
ALTER TABLE debt_instalments ADD COLUMN due_on TEXT;

-- 2. The minimum of a statement ------------------------------------------------------------------
-- What the bank asked for one statement of a credit card, typed by hand: the statement's closing
-- day, the minimum payment, in the account's main currency, and the day it has to be paid by.
-- It belongs to that statement alone and never carries over to the next month. One row per
-- account and statement; a card with no row for a statement keeps the minimum the app works out.
CREATE TABLE credit_statements (
  id                 TEXT PRIMARY KEY,
  payment_method_id  TEXT NOT NULL REFERENCES payment_methods(id) ON DELETE CASCADE,
  statement_on       TEXT NOT NULL,
  minimum_e4         INTEGER NOT NULL CHECK (minimum_e4 >= 0),
  pay_by             TEXT NOT NULL
);
CREATE UNIQUE INDEX idx_credit_statements_key ON credit_statements(payment_method_id, statement_on);

-- 3. Exchange of changes -------------------------------------------------------------------------
-- credit_statements. The new column of `debt_instalments` needs no trigger: the triggers of
-- 0012 write the key of a changed row whatever column changed.
CREATE TRIGGER sync_credit_statements_insert AFTER INSERT ON credit_statements WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('credit_statements', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;
CREATE TRIGGER sync_credit_statements_update AFTER UPDATE ON credit_statements WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('credit_statements', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
  INSERT INTO sync_outbox (table_name, row_key, at)
    SELECT 'credit_statements', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE OLD.id IS NOT NEW.id;
END;
CREATE TRIGGER sync_credit_statements_delete AFTER DELETE ON credit_statements WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('credit_statements', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;
