-- Purchases, gifts and things: the list «хочу купить» with its price history, the shopping list,
-- the things the owner has outside the capital, the discount, the regret and the wait for a refund
-- of an operation, the mileage at a fill-up, and the birthday and gift budget of a person.
-- Forward only.
--
-- Additive only, like 0004 to 0017: new columns that start empty, four new tables, and no data
-- step. No row is inserted or updated, so every operation and person the update finds reads exactly
-- as it did: no discount, no answer about regret, no wait, no mileage, no birthday. No CHECK on an
-- added column: adding one checks every other CHECK of the table again.
--
-- The settings these features need no column: they are keys of the `settings` table, absent until
-- the owner changes them, and an absent key reads as its default: `purchases.pauseEnabled` (`0`),
-- `purchases.pausePercent` (`20`), `regret.enabled` (`1`), `regret.askAfterDays` (`1`),
-- `fuel.askMileage` (`1`).
--
-- Needs SQLite 3.37 or later, as 0004 to 0017 do.

-- 1. Operations ------------------------------------------------------------------------------------------
-- `discount_e4`: how much the price fell for the owner (a coupon, points), in the currency of the
-- operation; NULL reads as none. `regret`: the owner's answer to «would you buy it again» --
-- `no` (does not regret), `yes` (regrets), `skip` (asked, did not answer); NULL: not asked or not
-- answered yet. The values are not checked: a later build may know more. `regret_asked_on`: the day
-- the question was put (`YYYY-MM-DD`). `refund_waiting_until`: a refund of the purchase is expected
-- to reach the account by this day (`YYYY-MM-DD`). `odometer_km`: the mileage of the car at a fill-up,
-- whole kilometres.
ALTER TABLE transactions ADD COLUMN discount_e4 INTEGER;
ALTER TABLE transactions ADD COLUMN regret TEXT;
ALTER TABLE transactions ADD COLUMN regret_asked_on TEXT;
ALTER TABLE transactions ADD COLUMN refund_waiting_until TEXT;
ALTER TABLE transactions ADD COLUMN odometer_km INTEGER;

-- 2. People: birthday and gift budget ------------------------------------------------------------------
-- A birthday is a month and a day, and a year when the owner knows it. `gift_budget_e4`: what the
-- owner is ready to spend on a gift for the person, in rubles.
ALTER TABLE people ADD COLUMN birthday_month INTEGER;
ALTER TABLE people ADD COLUMN birthday_day INTEGER;
ALTER TABLE people ADD COLUMN birthday_year INTEGER;
ALTER TABLE people ADD COLUMN gift_budget_e4 INTEGER;

-- 3. The wishes ----------------------------------------------------------------------------------------------
-- «Хочу купить»: what the owner wants and has not bought. `price_e4` and `currency`: the price now,
-- NULL when not known. `priority`: 1 (most wanted) upward; 0 is none. `url`: where it is sold.
-- `created_on`: the day it was added. `bought_transaction_id`: the operation that bought it (the
-- wish stays, marked bought), `expected_e4`: the price the owner expected at that moment, for
-- «expected against paid». `archived`: left the list without a purchase. `sort`: the owner's order.
CREATE TABLE wishes (
  id                    TEXT PRIMARY KEY,
  name                  TEXT NOT NULL,
  price_e4              INTEGER,
  currency              TEXT,
  priority              INTEGER NOT NULL DEFAULT 0,
  url                   TEXT,
  note                  TEXT,
  created_on            TEXT NOT NULL,
  bought_transaction_id TEXT REFERENCES transactions(id) ON DELETE SET NULL,
  expected_e4           INTEGER,
  archived              INTEGER NOT NULL DEFAULT 0 CHECK (archived IN (0, 1)),
  sort                  INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX idx_wishes_bought ON wishes(bought_transaction_id) WHERE bought_transaction_id IS NOT NULL;

-- The price of a wish on a day: one row each time the owner notes the price changed.
CREATE TABLE wish_prices (
  id        TEXT PRIMARY KEY,
  wish_id   TEXT NOT NULL REFERENCES wishes(id) ON DELETE CASCADE,
  on_date   TEXT NOT NULL,
  price_e4  INTEGER NOT NULL
);
CREATE INDEX idx_wish_prices_wish ON wish_prices(wish_id, on_date);

-- 4. The shopping list ---------------------------------------------------------------------------------------
-- A second list, for what is to be bought on the next trip to the shop.
CREATE TABLE shopping_items (
  id          TEXT PRIMARY KEY,
  name        TEXT NOT NULL,
  note        TEXT,
  done        INTEGER NOT NULL DEFAULT 0 CHECK (done IN (0, 1)),
  created_on  TEXT NOT NULL,
  sort        INTEGER NOT NULL DEFAULT 0
);

-- 5. Things outside the capital -------------------------------------------------------------------------------
-- A thing the owner keeps track of that is not an asset of the capital. `tag_id`: the tag that
-- gathers the operations about the thing. `sold_on` and `sale_transaction_id`: when and by which
-- operation it was sold.
CREATE TABLE owned_items (
  id                   TEXT PRIMARY KEY,
  name                 TEXT NOT NULL,
  bought_on            TEXT,
  price_e4             INTEGER,
  currency             TEXT,
  tag_id               TEXT REFERENCES tags(id) ON DELETE SET NULL,
  sold_on              TEXT,
  sale_transaction_id  TEXT REFERENCES transactions(id) ON DELETE SET NULL,
  note                 TEXT,
  archived             INTEGER NOT NULL DEFAULT 0 CHECK (archived IN (0, 1))
);
CREATE INDEX idx_owned_items_tag ON owned_items(tag_id) WHERE tag_id IS NOT NULL;
CREATE INDEX idx_owned_items_sale ON owned_items(sale_transaction_id) WHERE sale_transaction_id IS NOT NULL;

-- 6. Exchange of changes ----------------------------------------------------------------------------------------
-- wishes
CREATE TRIGGER sync_wishes_insert AFTER INSERT ON wishes WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('wishes', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;
CREATE TRIGGER sync_wishes_update AFTER UPDATE ON wishes WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('wishes', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
  INSERT INTO sync_outbox (table_name, row_key, at)
    SELECT 'wishes', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE OLD.id IS NOT NEW.id;
END;
CREATE TRIGGER sync_wishes_delete AFTER DELETE ON wishes WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('wishes', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;

-- wish_prices
CREATE TRIGGER sync_wish_prices_insert AFTER INSERT ON wish_prices WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('wish_prices', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;
CREATE TRIGGER sync_wish_prices_update AFTER UPDATE ON wish_prices WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('wish_prices', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
  INSERT INTO sync_outbox (table_name, row_key, at)
    SELECT 'wish_prices', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE OLD.id IS NOT NEW.id;
END;
CREATE TRIGGER sync_wish_prices_delete AFTER DELETE ON wish_prices WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('wish_prices', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;

-- shopping_items
CREATE TRIGGER sync_shopping_items_insert AFTER INSERT ON shopping_items WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('shopping_items', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;
CREATE TRIGGER sync_shopping_items_update AFTER UPDATE ON shopping_items WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('shopping_items', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
  INSERT INTO sync_outbox (table_name, row_key, at)
    SELECT 'shopping_items', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE OLD.id IS NOT NEW.id;
END;
CREATE TRIGGER sync_shopping_items_delete AFTER DELETE ON shopping_items WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('shopping_items', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;

-- owned_items
CREATE TRIGGER sync_owned_items_insert AFTER INSERT ON owned_items WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('owned_items', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;
CREATE TRIGGER sync_owned_items_update AFTER UPDATE ON owned_items WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('owned_items', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
  INSERT INTO sync_outbox (table_name, row_key, at)
    SELECT 'owned_items', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE OLD.id IS NOT NEW.id;
END;
CREATE TRIGGER sync_owned_items_delete AFTER DELETE ON owned_items WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('owned_items', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;
