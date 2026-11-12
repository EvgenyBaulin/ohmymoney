-- The merchant category and the commission of an operation, the market valuations of things, the
-- picture of a wish and the fee of an account without a card. Forward only.
--
-- Additive only, like 0004 to 0025: four new columns that start empty, one new table with its
-- triggers, and no data step. No row is inserted or updated, so every operation, wish and bank
-- condition the update finds reads exactly as it did. No CHECK on an added column: adding one
-- checks every other CHECK of the table again, and the old rows leave the column empty anyway.
--
-- The sync triggers of `transactions`, `wishes` and `bank_conditions` already write the key of a
-- changed row to the outbox, whatever column changed, so the new columns travel with the row and
-- need no trigger of their own.
--
-- Needs SQLite 3.37 or later, as 0004 to 0025 do.

-- 1. The merchant category of an operation -------------------------------------------------------
-- `mcc`: the four digits of the code the bank gave the shop («5411»), kept as text so a leading
-- zero («0742») stays. Written from the text of a bank and from a statement; NULL: not known.
ALTER TABLE transactions ADD COLUMN mcc TEXT;

-- 2. The commission of an operation --------------------------------------------------------------
-- `fee_e4`: what the bank's text says it took on top of the operation, in the currency of the
-- operation (`transactions.currency`); a fee in another currency is not kept. An informational
-- field: it is no operation of its own and moves no balance. NULL: the text named none.
ALTER TABLE transactions ADD COLUMN fee_e4 INTEGER;

-- 3. The fee of an account without a card --------------------------------------------------------
-- `no_card_fee_e4`: what the bank takes in a month for an account with no card tied to it, in the
-- row's `currency`. NULL is a condition not stated, never zero, like every amount of this table.
ALTER TABLE bank_conditions ADD COLUMN no_card_fee_e4 INTEGER;

-- 4. The picture of a wish -----------------------------------------------------------------------
-- `image_url`: the address of the picture the page of the product gave. Only the address is
-- kept; NULL: none was taken.
ALTER TABLE wishes ADD COLUMN image_url TEXT;

-- 5. Market valuations of things ------------------------------------------------------------------
-- What the owner thinks a thing is worth on a day. `owner_kind` is `asset` or `owned_item` and
-- `owner_id` names a row of that table; it is no foreign key, because one column names two
-- tables (like `attachments`), so a trigger below removes the valuations with their owner. The
-- currency belongs to the observation, not to its owner. `recorded_at` (UTC) tells two
-- valuations of one day apart. No CHECK on `owner_kind`: a later build may value more kinds of
-- owner.
CREATE TABLE thing_valuations (
  id           TEXT PRIMARY KEY,
  owner_kind   TEXT NOT NULL,
  owner_id     TEXT NOT NULL,
  valued_on    TEXT NOT NULL,
  value_e4     INTEGER NOT NULL CHECK (value_e4 >= 0),
  currency     TEXT NOT NULL,
  note         TEXT,
  recorded_at  TEXT NOT NULL
);
CREATE INDEX idx_thing_valuations_owner ON thing_valuations(owner_kind, owner_id);

CREATE TRIGGER thing_valuations_asset_gone AFTER DELETE ON assets
BEGIN
  DELETE FROM thing_valuations WHERE owner_kind = 'asset' AND owner_id = OLD.id;
END;
CREATE TRIGGER thing_valuations_owned_item_gone AFTER DELETE ON owned_items
BEGIN
  DELETE FROM thing_valuations WHERE owner_kind = 'owned_item' AND owner_id = OLD.id;
END;

-- 6. Exchange of changes -------------------------------------------------------------------------
-- thing_valuations
CREATE TRIGGER sync_thing_valuations_insert AFTER INSERT ON thing_valuations WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('thing_valuations', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;
CREATE TRIGGER sync_thing_valuations_update AFTER UPDATE ON thing_valuations WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('thing_valuations', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
  INSERT INTO sync_outbox (table_name, row_key, at)
    SELECT 'thing_valuations', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE OLD.id IS NOT NEW.id;
END;
CREATE TRIGGER sync_thing_valuations_delete AFTER DELETE ON thing_valuations WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('thing_valuations', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;
