-- The journal of changes kept for ever, the monthly ceilings of cashback and the bank's monthly
-- choice of categories. Forward only.
--
-- Additive only, like 0004 to 0019: new tables, new triggers and new columns that start empty,
-- and no data step. No row of an older table is inserted or updated, so every operation, account
-- and rule the update finds reads exactly as it did. No CHECK on an added column: adding one
-- checks every other CHECK of the table again. The file names no table a later or a parallel
-- migration adds, so it applies after any of them.
--
-- Needs SQLite 3.37 or later, as 0004 to 0019 do.

-- 1. The journal of changes ---------------------------------------------------------------------
-- Every change of a row of the books, as it stood after the change: when, on which device (the
-- id of the device and the name it had then), what happened, and the whole row as JSON (the
-- fields of a journal file of the exchange: money as integer `*_e4`, moments as UTC text). The
-- changes of this device are taken from the outbox of the exchange before it is emptied; the
-- changes of another device are written when they are applied. Kept for ever: nothing deletes a
-- line. Bookkeeping of this device like the other `sync_*` tables: not in the export, the transfer
-- archive or the readable copy, and an anonymized copy leaves it out.
CREATE TABLE sync_history (
  seq          INTEGER PRIMARY KEY AUTOINCREMENT,
  table_name   TEXT NOT NULL,
  row_key      TEXT NOT NULL,
  op           TEXT NOT NULL CHECK (op IN ('created', 'updated', 'deleted')),
  at           TEXT NOT NULL,
  device_id    TEXT NOT NULL,
  device_name  TEXT NOT NULL DEFAULT '',
  fields       TEXT NOT NULL
);
CREATE INDEX idx_sync_history_row ON sync_history(table_name, row_key, seq);

-- 2. Monthly ceilings of cashback -----------------------------------------------------------------
-- «Не больше N в месяц», rubles in 1/10000: of one rule, and of a whole account (its cards and
-- categories together). NULL: no ceiling.
ALTER TABLE cashback_rules ADD COLUMN monthly_cap_e4 INTEGER;
ALTER TABLE payment_methods ADD COLUMN cashback_monthly_cap_e4 INTEGER;
-- The day of the month (1…31) the bank opens the choice of the month's categories, when the
-- reminder to choose comes; NULL: the bank offers no choice.
ALTER TABLE payment_methods ADD COLUMN cashback_choice_day INTEGER;

-- 3. The bank's monthly choice --------------------------------------------------------------------
-- «Категория банка → ваша», one table per bank: a bank's label and one of the owner's expense
-- categories it stands for; a label that stands for several categories is several rows.
-- `category_id` holds no foreign key on purpose: a category deleted (and brought back by ⌘Z)
-- leaves the bank's table as it was, and a label standing for a category that is gone simply
-- covers no spending.
CREATE TABLE bank_cashback_categories (
  id           TEXT PRIMARY KEY,
  bank_id      TEXT NOT NULL REFERENCES banks(id) ON DELETE CASCADE,
  label        TEXT NOT NULL CHECK (length(trim(label)) > 0),
  category_id  TEXT NOT NULL
);
CREATE UNIQUE INDEX idx_bank_cashback_categories_key
  ON bank_cashback_categories(bank_id, label, category_id);
CREATE INDEX idx_bank_cashback_categories_category ON bank_cashback_categories(category_id);

-- What a bank offers for one month, on an account or one of its cards, and whether the owner took
-- it. Taking an offer writes the month's rules of the account (`cashback_rules` with `month`),
-- which every figure of cashback reads; the offer keeps what was on the table. `percent_e4` is in
-- 1/10000 of a percent, as in `cashback_rules`.
CREATE TABLE cashback_offers (
  id                 TEXT PRIMARY KEY,
  payment_method_id  TEXT NOT NULL REFERENCES payment_methods(id) ON DELETE CASCADE,
  card_id            TEXT REFERENCES cards(id) ON DELETE CASCADE,
  month              TEXT NOT NULL CHECK (month GLOB '[0-9][0-9][0-9][0-9]-[01][0-9]'),
  label              TEXT NOT NULL CHECK (length(trim(label)) > 0),
  percent_e4         INTEGER NOT NULL CHECK (percent_e4 BETWEEN 0 AND 1000000),
  chosen             INTEGER NOT NULL DEFAULT 0 CHECK (chosen IN (0, 1))
);
CREATE INDEX idx_cashback_offers_account ON cashback_offers(payment_method_id, month);
CREATE INDEX idx_cashback_offers_card ON cashback_offers(card_id) WHERE card_id IS NOT NULL;

-- 4. Exchange of changes ----------------------------------------------------------------------------
-- bank_cashback_categories
CREATE TRIGGER sync_bank_cashback_categories_insert AFTER INSERT ON bank_cashback_categories WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('bank_cashback_categories', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;
CREATE TRIGGER sync_bank_cashback_categories_update AFTER UPDATE ON bank_cashback_categories WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('bank_cashback_categories', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
  INSERT INTO sync_outbox (table_name, row_key, at)
    SELECT 'bank_cashback_categories', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE OLD.id IS NOT NEW.id;
END;
CREATE TRIGGER sync_bank_cashback_categories_delete AFTER DELETE ON bank_cashback_categories WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('bank_cashback_categories', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;

-- cashback_offers
CREATE TRIGGER sync_cashback_offers_insert AFTER INSERT ON cashback_offers WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('cashback_offers', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;
CREATE TRIGGER sync_cashback_offers_update AFTER UPDATE ON cashback_offers WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('cashback_offers', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
  INSERT INTO sync_outbox (table_name, row_key, at)
    SELECT 'cashback_offers', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE OLD.id IS NOT NEW.id;
END;
CREATE TRIGGER sync_cashback_offers_delete AFTER DELETE ON cashback_offers WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('cashback_offers', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;
