-- Spending rules: the one-off mark, the budget basket, tags, rules, the last digits of a card and
-- the notes of days. Forward only.
--
-- Additive only, like 0004 to 0012: new columns that start empty or at their default, new
-- tables, and no data step. No row is inserted or updated, so every operation, category, card
-- and setting the update finds reads exactly as it did: an operation is not one-off, a category
-- has no basket of its own (it reads as before), a card has no digits, nobody has tags, rules or
-- notes. No CHECK on an added column: adding one checks every other CHECK of the table again.
--
-- The settings of «Доход и сбережения» (`incomeSavings.proportions`, `.earningsOnly`,
-- `.trendNudge.enabled`, `.trendNudge.shown`) and of the rules need no column: they are keys of
-- the `settings` table, absent until the owner changes them.
--
-- Needs SQLite 3.37 or later, as 0004 to 0012 do.

-- 1. Operations: the one-off mark --------------------------------------------------------------------
-- 1: the owner marked the whole operation as a one-off (a laptop, a repair): it leaves the
-- averages and the forecasts and stays in every total and every limit. 0: an ordinary operation.
ALTER TABLE transactions ADD COLUMN one_off INTEGER NOT NULL DEFAULT 0;

-- 2. Categories: the basket of the budget ------------------------------------------------------------
-- `needs`, `wants` or `savings`: the basket the category belongs to in the owner's proportions.
-- NULL — a subcategory follows its parent, a category is read from its «Необходимая трата» mark.
ALTER TABLE categories ADD COLUMN basket TEXT;

-- 3. Cards: the last four digits ----------------------------------------------------------------------
-- `last4`: the four digits a bank text names the card by («*3230»). `details`: whatever else the
-- owner wants to keep about the card, free text. Both NULL until typed.
ALTER TABLE cards ADD COLUMN last4 TEXT;
ALTER TABLE cards ADD COLUMN details TEXT;

-- 4. Tags ----------------------------------------------------------------------------------------------
-- A free label, «#отпуск». `name` is as first typed, without the «#»; two names that fold to the
-- same key are one tag, which the repository keeps (SQLite can not fold «Ё» and «е»).
CREATE TABLE tags (
  id          TEXT PRIMARY KEY,
  name        TEXT NOT NULL CHECK (length(trim(name)) > 0),
  archived    INTEGER NOT NULL DEFAULT 0 CHECK (archived IN (0, 1)),
  created_at  TEXT NOT NULL
);

-- The tags of a part. The id is the pair itself, `<part id>:<tag id>`, so the same tag put on the
-- same part on two devices is one row and not two that the next exchange would have to reconcile.
CREATE TABLE part_tags (
  id       TEXT PRIMARY KEY,
  part_id  TEXT NOT NULL REFERENCES transaction_parts(id) ON DELETE CASCADE,
  tag_id   TEXT NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
  CHECK (id = part_id || ':' || tag_id)
);
CREATE INDEX idx_part_tags_part ON part_tags(part_id);
CREATE INDEX idx_part_tags_tag ON part_tags(tag_id);

-- 5. Rules ---------------------------------------------------------------------------------------------
-- A rule of the owner's: all `conditions` must hold, then the `actions` apply. Both are JSON
-- arrays of `{"type": "...", ...}` objects (`RuleCondition`, `RuleAction` of `CoreKit`), so a new
-- kind of condition needs no column. `position` is the order of precedence, lowest first.
-- `origin` is only a note: `manual`, `import` or `exchange`.
CREATE TABLE rules (
  id          TEXT PRIMARY KEY,
  name        TEXT NOT NULL DEFAULT '',
  position    INTEGER NOT NULL DEFAULT 0,
  enabled     INTEGER NOT NULL DEFAULT 1 CHECK (enabled IN (0, 1)),
  origin      TEXT NOT NULL DEFAULT 'manual' CHECK (origin IN ('manual', 'import', 'exchange')),
  conditions  TEXT NOT NULL DEFAULT '[]',
  actions     TEXT NOT NULL DEFAULT '[]',
  created_at  TEXT NOT NULL,
  updated_at  TEXT NOT NULL
);
CREATE INDEX idx_rules_position ON rules(position);

-- 6. Notes of days -------------------------------------------------------------------------------------
-- «12 октября — день рождения мамы», shown on the day in the calendar. One note per day.
CREATE TABLE day_notes (
  id          TEXT PRIMARY KEY,
  day         TEXT NOT NULL UNIQUE,
  text        TEXT NOT NULL CHECK (length(trim(text)) > 0),
  created_at  TEXT NOT NULL,
  updated_at  TEXT NOT NULL
);

-- 7. The new tables travel between devices -------------------------------------------------------------
-- The columns added above need no trigger: the triggers of 0012 write only the table and the key.

-- tags
CREATE TRIGGER sync_tags_insert AFTER INSERT ON tags WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('tags', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;
CREATE TRIGGER sync_tags_update AFTER UPDATE ON tags WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('tags', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
  INSERT INTO sync_outbox (table_name, row_key, at)
    SELECT 'tags', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE OLD.id IS NOT NEW.id;
END;
CREATE TRIGGER sync_tags_delete AFTER DELETE ON tags WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('tags', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;

-- part_tags
CREATE TRIGGER sync_part_tags_insert AFTER INSERT ON part_tags WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('part_tags', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;
CREATE TRIGGER sync_part_tags_update AFTER UPDATE ON part_tags WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('part_tags', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
  INSERT INTO sync_outbox (table_name, row_key, at)
    SELECT 'part_tags', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE OLD.id IS NOT NEW.id;
END;
CREATE TRIGGER sync_part_tags_delete AFTER DELETE ON part_tags WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('part_tags', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;

-- rules
CREATE TRIGGER sync_rules_insert AFTER INSERT ON rules WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('rules', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;
CREATE TRIGGER sync_rules_update AFTER UPDATE ON rules WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('rules', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
  INSERT INTO sync_outbox (table_name, row_key, at)
    SELECT 'rules', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE OLD.id IS NOT NEW.id;
END;
CREATE TRIGGER sync_rules_delete AFTER DELETE ON rules WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('rules', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;

-- day_notes
CREATE TRIGGER sync_day_notes_insert AFTER INSERT ON day_notes WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('day_notes', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;
CREATE TRIGGER sync_day_notes_update AFTER UPDATE ON day_notes WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('day_notes', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
  INSERT INTO sync_outbox (table_name, row_key, at)
    SELECT 'day_notes', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE OLD.id IS NOT NEW.id;
END;
CREATE TRIGGER sync_day_notes_delete AFTER DELETE ON day_notes WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('day_notes', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;
