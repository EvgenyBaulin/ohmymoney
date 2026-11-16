-- The answer to «не пришёл?» for one due date of a recurring expected income. Forward only.
--
-- Additive only, like 0004 to 0033: one new table with its triggers, and no data step. No row is
-- inserted or updated, so every expected income the update finds reads exactly as it did.
--
-- Needs SQLite 3.37 or later, as 0004 to 0033 do.

-- 1. One due of a recurring income -------------------------------------------------------------
-- A recurring income has no cursor to move past a due (a scheduled payment has `next_date`):
-- its dues are counted from its first due date and its frequency. So the owner's answer for a
-- single due that did not come is a row of its own; the recurrence and every other due stay.
--
-- `due_on`: the due as the recurrence puts it, `YYYY-MM-DD` — it names the due whatever the
-- answer, so a second answer rewrites the same row. A row whose `due_on` the recurrence no longer
-- puts a due on (its day was edited since) changes nothing.
-- `moved_to`: the day the money is expected instead («Перенести»), `YYYY-MM-DD`; NULL — the due
-- is skipped («Закрыть»): nothing more is waited for it, what came for it still counts.
-- `id`: made from the income and `due_on` — the income's id with bytes 10…15 mixed with a tag
-- and the day (`ExpectedIncomeDue.id(incomeId:due:)`) —, so two devices answering for the same
-- due write one row of the exchange and the later answer wins, never two rows the pair's
-- uniqueness refuses. A row with any other id is read all the same.
CREATE TABLE expected_income_dues (
  id                  TEXT PRIMARY KEY,
  expected_income_id  TEXT NOT NULL REFERENCES expected_income(id) ON DELETE CASCADE,
  due_on              TEXT NOT NULL,
  moved_to            TEXT
);
CREATE UNIQUE INDEX idx_expected_income_dues_key
  ON expected_income_dues(expected_income_id, due_on);

-- 2. Exchange of changes -------------------------------------------------------------------------
CREATE TRIGGER sync_expected_income_dues_insert AFTER INSERT ON expected_income_dues WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('expected_income_dues', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;
CREATE TRIGGER sync_expected_income_dues_update AFTER UPDATE ON expected_income_dues WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('expected_income_dues', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
  INSERT INTO sync_outbox (table_name, row_key, at)
    SELECT 'expected_income_dues', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE OLD.id IS NOT NEW.id;
END;
CREATE TRIGGER sync_expected_income_dues_delete AFTER DELETE ON expected_income_dues WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('expected_income_dues', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;
