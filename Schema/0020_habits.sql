-- Habits: why a goal is saved for, the badges the owner earned for regular entry and counts, and the
-- days the owner said nothing was spent. Forward only.
--
-- Additive only, like 0004 to 0019: one new column that starts empty, two new tables, and no data
-- step. No row is inserted or updated, so every goal the update finds reads exactly as it did: no
-- note. No CHECK on an added column: adding one checks every other CHECK of the table again.
--
-- Both new tables are keyed by what they are about, not by a random id: the same badge earned, or
-- the same day marked, on two devices is one row, so the exchange of changes merges them instead
-- of tripping over a second row for the same thing (as `week_answers` of 0017 does).
--
-- The setting these features need no column: it is a key of the `settings` table, absent until the
-- owner changes it, and an absent key reads as its default: `habits.missedDaysAfter` (`3`) -- after
-- how many days without an operation typed by hand «Стоит посмотреть» offers to restore them.
--
-- Needs SQLite 3.37 or later, as 0004 to 0019 do.

-- 1. Goals ---------------------------------------------------------------------------------------------
-- `why_note`: why the owner saves for the goal, in the owner's words («море в июле, всей семьёй»).
-- Shown in the hard moments: when goal money looks spent, when the monthly plan is lowered, when the
-- goal is deleted. NULL or empty: none.
ALTER TABLE goals ADD COLUMN why_note TEXT;

-- 2. Badges --------------------------------------------------------------------------------------------
-- A badge the owner earned: a streak of days with entries (`entry7`, `entry30`, `entry100`) or a
-- month with a count of the accounts (`countMonth`), and series of such months (`count3`,
-- `count12`). `key` is `<kind>:<period>`; `period` is the first day of the streak (`YYYY-MM-DD`) or
-- the month (`YYYY-MM`) it is about. A badge once earned stays: an edit of the past never takes it
-- back. `earned_on`: the owner's day it was earned on; `earned_at`: the UTC instant it was written.
-- The kinds are not checked: a later build may know more.
CREATE TABLE habit_badges (
  key        TEXT PRIMARY KEY,
  kind       TEXT NOT NULL,
  period     TEXT NOT NULL,
  earned_on  TEXT NOT NULL,
  earned_at  TEXT NOT NULL
);

-- 3. Days without spending --------------------------------------------------------------------------
-- «Сегодня трат не было»: the owner said nothing was spent on `day` (`YYYY-MM-DD`); the day counts in
-- the streak of entry as a day with an entry. `marked_at`: the UTC instant of the answer.
CREATE TABLE no_spend_days (
  day        TEXT PRIMARY KEY,
  marked_at  TEXT NOT NULL
);

-- 4. Exchange of changes ------------------------------------------------------------------------------
-- The column added to `goals` needs no trigger: the triggers of 0012 write only the table and the key.

-- habit_badges
CREATE TRIGGER sync_habit_badges_insert AFTER INSERT ON habit_badges WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('habit_badges', NEW.key, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;
CREATE TRIGGER sync_habit_badges_update AFTER UPDATE ON habit_badges WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('habit_badges', NEW.key, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
  INSERT INTO sync_outbox (table_name, row_key, at)
    SELECT 'habit_badges', OLD.key, strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE OLD.key IS NOT NEW.key;
END;
CREATE TRIGGER sync_habit_badges_delete AFTER DELETE ON habit_badges WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('habit_badges', OLD.key, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;

-- no_spend_days
CREATE TRIGGER sync_no_spend_days_insert AFTER INSERT ON no_spend_days WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('no_spend_days', NEW.day, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;
CREATE TRIGGER sync_no_spend_days_update AFTER UPDATE ON no_spend_days WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('no_spend_days', NEW.day, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
  INSERT INTO sync_outbox (table_name, row_key, at)
    SELECT 'no_spend_days', OLD.day, strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE OLD.day IS NOT NEW.day;
END;
CREATE TRIGGER sync_no_spend_days_delete AFTER DELETE ON no_spend_days WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('no_spend_days', OLD.day, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;
