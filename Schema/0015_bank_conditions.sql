-- Bank conditions, card expiry, account colour, crypto rate source, payouts of holdings. Forward only.
--
-- Additive only, like 0004 to 0014: new columns that start empty, two new tables, and no data
-- step. No row is inserted or updated, so every account, card, currency and expected income the
-- update finds reads exactly as it did: no account has a colour, no card an expiry, no currency a
-- network rate, no income a holding. No CHECK on an added column: adding one checks every other
-- CHECK of the table again.
--
-- The settings these features need no column: they are keys of the `settings` table, absent
-- until the owner changes them (`crypto.rateSource`, `deposits.parserEnabled`,
-- `banks.forgottenDays`).
--
-- Needs SQLite 3.37 or later, as 0004 to 0014 do.

-- 1. Accounts: a colour -------------------------------------------------------------------------------
-- `accent`: the key of one of the twelve palette colours (`01` to `12`); NULL reads as none.
ALTER TABLE payment_methods ADD COLUMN accent TEXT;

-- 2. Cards: the month the card expires ------------------------------------------------------------
-- `expires_on`: `YYYY-MM`, the last month the card works; NULL reads as unknown.
ALTER TABLE cards ADD COLUMN expires_on TEXT;

-- 3. Own currencies: where the rate comes from ------------------------------------------------------
-- `rate_source`: `manual` or `coingecko`; NULL reads as `manual`. `coin_id`: the id the source
-- knows the coin by, sent as the only thing in a request.
ALTER TABLE custom_currencies ADD COLUMN rate_source TEXT;
ALTER TABLE custom_currencies ADD COLUMN coin_id TEXT;

-- 4. Expected income: a dividend or a coupon of a holding ------------------------------------------
-- `payout_kind`: `dividend` or `coupon`; NULL is an ordinary expected income. `asset_id`: the
-- holding (an asset of kind `investment`) the money comes from.
ALTER TABLE expected_income ADD COLUMN payout_kind TEXT;
ALTER TABLE expected_income ADD COLUMN asset_id TEXT REFERENCES assets(id) ON DELETE SET NULL;

-- 5. Conditions of a bank product ------------------------------------------------------------------
-- One row for an account, or for one card of it (`card_id` set). Amounts in `currency`. A NULL
-- amount is a condition the owner did not state: it is never read as zero.
CREATE TABLE bank_conditions (
  id                       TEXT PRIMARY KEY,
  payment_method_id        TEXT NOT NULL REFERENCES payment_methods(id) ON DELETE CASCADE,
  card_id                  TEXT REFERENCES cards(id) ON DELETE CASCADE,
  currency                 TEXT NOT NULL DEFAULT 'RUB',
  free_cash_e4             INTEGER,
  free_sbp_e4              INTEGER,
  free_interbank_e4        INTEGER,
  service_free_spend_e4    INTEGER,
  service_free_balance_e4  INTEGER,
  min_balance_e4           INTEGER,
  note                     TEXT
);
CREATE UNIQUE INDEX idx_bank_conditions_product ON bank_conditions(payment_method_id, COALESCE(card_id, ''));

-- 6. Deposit offers the owner typed ---------------------------------------------------------------
-- The built-in showcase is data of the app, not rows; these are the owner's own. `rate_percent`
-- is a decimal string; `rate_on` is the day the rate was true (`YYYY-MM-DD`).
CREATE TABLE deposit_offers (
  id                  TEXT PRIMARY KEY,
  bank_name           TEXT NOT NULL CHECK (length(trim(bank_name)) > 0),
  rate_percent        TEXT NOT NULL,
  term_months         INTEGER,
  min_amount_e4       INTEGER,
  max_amount_e4       INTEGER,
  new_client_only     INTEGER NOT NULL DEFAULT 0 CHECK (new_client_only IN (0, 1)),
  needs_subscription  INTEGER NOT NULL DEFAULT 0 CHECK (needs_subscription IN (0, 1)),
  topup               INTEGER NOT NULL DEFAULT 0 CHECK (topup IN (0, 1)),
  rate_on             TEXT NOT NULL,
  note                TEXT,
  archived            INTEGER NOT NULL DEFAULT 0 CHECK (archived IN (0, 1))
);

-- 7. Exchange of changes ------------------------------------------------------------------------------
-- bank_conditions
CREATE TRIGGER sync_bank_conditions_insert AFTER INSERT ON bank_conditions WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('bank_conditions', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;
CREATE TRIGGER sync_bank_conditions_update AFTER UPDATE ON bank_conditions WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('bank_conditions', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
  INSERT INTO sync_outbox (table_name, row_key, at)
    SELECT 'bank_conditions', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE OLD.id IS NOT NEW.id;
END;
CREATE TRIGGER sync_bank_conditions_delete AFTER DELETE ON bank_conditions WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('bank_conditions', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;

-- deposit_offers
CREATE TRIGGER sync_deposit_offers_insert AFTER INSERT ON deposit_offers WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('deposit_offers', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;
CREATE TRIGGER sync_deposit_offers_update AFTER UPDATE ON deposit_offers WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('deposit_offers', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
  INSERT INTO sync_outbox (table_name, row_key, at)
    SELECT 'deposit_offers', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE OLD.id IS NOT NEW.id;
END;
CREATE TRIGGER sync_deposit_offers_delete AFTER DELETE ON deposit_offers WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('deposit_offers', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;
