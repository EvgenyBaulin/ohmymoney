-- The capital and the safety cushion: the things the owner values by hand, the accounts whose
-- money is the cushion and the categories of spending that cannot be stopped. Forward only.
--
-- Additive only, like 0004 to 0007: this file adds columns that start empty or with the value a
-- new row starts with, and two new tables, and changes no value an older build wrote. There is
-- no data step and no row is inserted: every account and every category the update finds keeps
-- reading exactly as it did — not the cushion, not essential. The settings of the cushion live
-- in `settings` under their own keys, written only when the owner sets them.
--
-- Needs SQLite 3.37 or later, as 0004 to 0007 do.

-- 1. The cushion ----------------------------------------------------------------------------
-- The money the owner keeps as the safety cushion: counted in «Подушка», every currency of the
-- account, and kept out of the free sum when the owner says so.
ALTER TABLE payment_methods ADD COLUMN cushion INTEGER NOT NULL DEFAULT 0
  CHECK (cushion IN (0, 1));

-- 2. Essential spending ---------------------------------------------------------------------
-- Spending I cannot stop: 1 yes, 0 no; NULL on a subcategory follows its parent (as quality
-- does), NULL on a category is no. Only an expense category says yes.
ALTER TABLE categories ADD COLUMN essential INTEGER
  CHECK (essential IS NULL OR (essential IN (0, 1) AND (essential = 0 OR kind = 'expense')));

-- 3. Assets ---------------------------------------------------------------------------------
-- Things valued by hand: a car, equipment, a brokerage account, a flat. The currency is the one
-- its valuations are in, three capital Latin letters.
CREATE TABLE assets (
  id           TEXT PRIMARY KEY,
  name         TEXT NOT NULL CHECK (length(trim(name)) > 0),
  kind         TEXT NOT NULL DEFAULT 'other'
               CHECK (kind IN ('vehicle', 'realty', 'equipment', 'investment', 'other')),
  currency     TEXT NOT NULL DEFAULT 'RUB'
               CHECK (length(currency) = 3 AND currency NOT GLOB '*[^A-Z]*'),
  note         TEXT,
  -- Sold or written off on this day (`YYYY-MM-DD`): counted through the day before, then gone.
  disposed_on  TEXT,
  sort         INTEGER NOT NULL DEFAULT 0
);

-- What an asset was worth on a day, in its currency: one valuation per asset and day. Deleting
-- an asset deletes its valuations.
CREATE TABLE asset_valuations (
  id        TEXT PRIMARY KEY,
  asset_id  TEXT NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
  day       TEXT NOT NULL,
  value_e4  INTEGER NOT NULL CHECK (value_e4 >= 0),
  note      TEXT,
  UNIQUE (asset_id, day)
);
CREATE INDEX idx_asset_valuations_asset ON asset_valuations(asset_id, day);
