-- Attachments, the warranty and return terms of an operation, and the answers to «how did the week go».
-- Forward only.
--
-- Additive only, like 0004 to 0015: new columns that start empty, two new tables, and no data
-- step. No row is inserted or updated, so every operation, asset, debt and subscription the update
-- finds reads exactly as it did: none has a file, a warranty or a return term, and no week has an
-- answer. No CHECK on an added column: adding one checks every other CHECK of the table again.
--
-- The files themselves are not in the database. A row of `attachments` names a file by the SHA-256
-- of its content (`content_hash`); the application keeps the bytes in a folder beside the database,
-- once for every hash however many rows name it. Two rows with the same hash share one file, and
-- the file goes only when no row names it.
--
-- The settings these features need no column: they are keys of the `settings` table, absent until
-- the owner changes them, and an absent key reads as its default: `attachments.keepReceiptsForever`
-- (`1`), `attachments.trashDays` (`30`), `attachments.mirror` (`1`), `archive.withAttachments`
-- (`1`).
--
-- Needs SQLite 3.37 or later, as 0004 to 0015 do.

-- 1. Operations: the warranty and the return term ----------------------------------------------------
-- `warranty_until`: the last day of the warranty (`YYYY-MM-DD`). `warranty_where`: where the original
-- of the document lies, in the owner's words. `return_until`: the last day the goods can be returned.
-- NULL reads as none. The warranty card or the receipt itself is an ordinary attachment.
ALTER TABLE transactions ADD COLUMN warranty_until TEXT;
ALTER TABLE transactions ADD COLUMN warranty_where TEXT;
ALTER TABLE transactions ADD COLUMN return_until TEXT;

-- 2. Attachments ------------------------------------------------------------------------------------
-- A file of any kind and size that belongs to one operation, asset, debt or subscription (a row of
-- `scheduled_payments`). `owner_id` names a row of the table `owner_kind` says; it is no foreign key
-- because the table differs, so the triggers of section 3 take the rows with their owner.
-- `owner_kind` and `kind` have no CHECK: a later build may attach files to more kinds of owner, and
-- widening a CHECK needs the table rebuilt. `owner_kind` is one of `transaction`, `asset`, `debt`,
-- `subscription`; a row of a kind this build does not know is left alone and not shown. `kind`:
-- `receipt`, `warranty`, `document` or `other`; a value this build does not know reads as
-- `other`. `added_at`: UTC. `trashed_at`: UTC, NULL while the file is kept; a file in the trash is
-- deleted after `attachments.trashDays` days. `keep_forever`: the retention rule never touches it.
CREATE TABLE attachments (
  id            TEXT PRIMARY KEY,
  owner_kind    TEXT NOT NULL,
  owner_id      TEXT NOT NULL,
  content_hash  TEXT NOT NULL CHECK (length(content_hash) = 64),
  file_name     TEXT NOT NULL,
  byte_size     INTEGER NOT NULL CHECK (byte_size >= 0),
  media_type    TEXT,
  kind          TEXT NOT NULL DEFAULT 'other',
  added_at      TEXT NOT NULL,
  trashed_at    TEXT,
  keep_forever  INTEGER NOT NULL DEFAULT 0 CHECK (keep_forever IN (0, 1)),
  note          TEXT
);
CREATE INDEX idx_attachments_owner ON attachments(owner_kind, owner_id);
CREATE INDEX idx_attachments_hash ON attachments(content_hash);
CREATE INDEX idx_attachments_trashed ON attachments(trashed_at) WHERE trashed_at IS NOT NULL;

-- 3. The files go with their owner -----------------------------------------------------------------------
-- The same effect as ON DELETE CASCADE for a column that names one of four tables. An operation is
-- only marked deleted in the ordinary way and keeps its files; these fire when the row is really
-- removed. The files in the folder are left to the sweep, which removes those no row names.
CREATE TRIGGER attachments_transaction_gone AFTER DELETE ON transactions
BEGIN
  DELETE FROM attachments WHERE owner_kind = 'transaction' AND owner_id = OLD.id;
END;
CREATE TRIGGER attachments_asset_gone AFTER DELETE ON assets
BEGIN
  DELETE FROM attachments WHERE owner_kind = 'asset' AND owner_id = OLD.id;
END;
CREATE TRIGGER attachments_debt_gone AFTER DELETE ON debts
BEGIN
  DELETE FROM attachments WHERE owner_kind = 'debt' AND owner_id = OLD.id;
END;
CREATE TRIGGER attachments_subscription_gone AFTER DELETE ON scheduled_payments
BEGIN
  DELETE FROM attachments WHERE owner_kind = 'subscription' AND owner_id = OLD.id;
END;

-- 4. Answers to «how did the week go» ----------------------------------------------------------------------
-- `week`: `YYYY-Www`. `mood`: 1 (hard) to 5 (good). `answered_at`: UTC. One answer a week; the table
-- is in the database and the transfer archive and not in the CSV export.
CREATE TABLE week_answers (
  week         TEXT PRIMARY KEY,
  mood         INTEGER NOT NULL CHECK (mood BETWEEN 1 AND 5),
  answered_at  TEXT NOT NULL
);

-- 5. Exchange of changes ------------------------------------------------------------------------------------
-- attachments
CREATE TRIGGER sync_attachments_insert AFTER INSERT ON attachments WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('attachments', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;
CREATE TRIGGER sync_attachments_update AFTER UPDATE ON attachments WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('attachments', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
  INSERT INTO sync_outbox (table_name, row_key, at)
    SELECT 'attachments', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE OLD.id IS NOT NEW.id;
END;
CREATE TRIGGER sync_attachments_delete AFTER DELETE ON attachments WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('attachments', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;

-- week_answers
CREATE TRIGGER sync_week_answers_insert AFTER INSERT ON week_answers WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('week_answers', NEW.week, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;
CREATE TRIGGER sync_week_answers_update AFTER UPDATE ON week_answers WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('week_answers', NEW.week, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
  INSERT INTO sync_outbox (table_name, row_key, at)
    SELECT 'week_answers', OLD.week, strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE OLD.week IS NOT NEW.week;
END;
CREATE TRIGGER sync_week_answers_delete AFTER DELETE ON week_answers WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('week_answers', OLD.week, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;
