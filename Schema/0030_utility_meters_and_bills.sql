-- Utilities: the meters of a home (water, electricity, gas, heat) with their readings, and the
-- bills of the providers with the charges for each service. Forward only.
--
-- Additive only, like 0004 to 0028: four new tables with their triggers, no column added to an
-- older table and no data step. No row is inserted or updated, so everything the update finds
-- reads exactly as it did. The tables start empty.
--
-- Quantities are kept like money, as whole numbers of 1/10000 (`*_e4`): a reading of 123.456 m³
-- is 1234560. A tariff is the price of one unit in the row's `currency`.
--
-- Needs SQLite 3.37 or later, as 0004 to 0028 do.

-- 1. Meters --------------------------------------------------------------------------------------
-- `kind`: `cold_water`, `hot_water`, `electricity`, `gas`, `heat` or `other`; no CHECK, so a later
-- build may add a kind and an older one reads it as `other`. `unit`: `m3`, `kwh`, `gcal` or what
-- the owner typed. `tariff_e4`: the price of one unit now; NULL — not known. `submit_from` and
-- `submit_to`: the days of the month the provider takes readings on (20 and 25; 25 and 5 crosses
-- the end of a month); NULL — no reminder. `provider`: who bills for it, as the owner calls them.
-- `scheduled_payment_id`: the payment of «Планирование» that pays for it; NULL — none.
CREATE TABLE utility_meters (
  id                    TEXT PRIMARY KEY,
  name                  TEXT NOT NULL CHECK (length(trim(name)) > 0),
  kind                  TEXT NOT NULL,
  unit                  TEXT NOT NULL,
  tariff_e4             INTEGER CHECK (tariff_e4 IS NULL OR tariff_e4 >= 0),
  currency              TEXT NOT NULL DEFAULT 'RUB',
  submit_from           INTEGER CHECK (submit_from IS NULL OR submit_from BETWEEN 1 AND 31),
  submit_to             INTEGER CHECK (submit_to IS NULL OR submit_to BETWEEN 1 AND 31),
  provider              TEXT,
  scheduled_payment_id  TEXT REFERENCES scheduled_payments(id) ON DELETE SET NULL,
  archived              INTEGER NOT NULL DEFAULT 0 CHECK (archived IN (0, 1)),
  sort                  INTEGER NOT NULL DEFAULT 0,
  note                  TEXT
);

-- 2. Readings ------------------------------------------------------------------------------------
-- What a meter showed on a day. `restart` = 1: the meter was replaced or went round, so nothing is
-- counted between the reading before and this one; the count starts again from this value.
-- `tariff_e4`: the price of a unit the reading is counted at — the meter's tariff when it was
-- written, so a later change of tariff does not rewrite the past; NULL — the meter's. `submitted_at`
-- (UTC): when the owner passed it to the provider; NULL — not yet. `recorded_at` (UTC) tells two
-- readings of one day apart.
CREATE TABLE utility_readings (
  id            TEXT PRIMARY KEY,
  meter_id      TEXT NOT NULL REFERENCES utility_meters(id) ON DELETE CASCADE,
  read_on       TEXT NOT NULL,
  value_e4      INTEGER NOT NULL CHECK (value_e4 >= 0),
  restart       INTEGER NOT NULL DEFAULT 0 CHECK (restart IN (0, 1)),
  tariff_e4     INTEGER CHECK (tariff_e4 IS NULL OR tariff_e4 >= 0),
  submitted_at  TEXT,
  recorded_at   TEXT NOT NULL
);
CREATE INDEX idx_utility_readings_meter ON utility_readings(meter_id, read_on);

-- 3. Bills ---------------------------------------------------------------------------------------
-- One bill of a provider for a month: `period` is `YYYY-MM`, `total_e4` what it asks for in
-- `currency`, `pay_by` the day to pay by (NULL — not stated). `transaction_id`: the operation that
-- paid it; `scheduled_payment_id`: the payment of «Планирование» it belongs to; NULL — none.
CREATE TABLE utility_bills (
  id                    TEXT PRIMARY KEY,
  provider              TEXT NOT NULL CHECK (length(trim(provider)) > 0),
  period                TEXT NOT NULL,
  total_e4              INTEGER NOT NULL CHECK (total_e4 >= 0),
  currency              TEXT NOT NULL DEFAULT 'RUB',
  pay_by                TEXT,
  transaction_id        TEXT REFERENCES transactions(id) ON DELETE SET NULL,
  scheduled_payment_id  TEXT REFERENCES scheduled_payments(id) ON DELETE SET NULL,
  note                  TEXT,
  recorded_at           TEXT NOT NULL
);
CREATE INDEX idx_utility_bills_period ON utility_bills(period, provider);

-- 4. Charges -------------------------------------------------------------------------------------
-- A line of a bill: the service as the bill names it, its amount in the bill's currency (below
-- zero for a recalculation in the owner's favour), and when the bill says so the quantity and the
-- tariff it was counted at. `meter_id`: the meter the line is for; NULL — none.
CREATE TABLE utility_charges (
  id           TEXT PRIMARY KEY,
  bill_id      TEXT NOT NULL REFERENCES utility_bills(id) ON DELETE CASCADE,
  service      TEXT NOT NULL,
  amount_e4    INTEGER NOT NULL,
  quantity_e4  INTEGER,
  tariff_e4    INTEGER,
  meter_id     TEXT REFERENCES utility_meters(id) ON DELETE SET NULL,
  sort         INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX idx_utility_charges_bill ON utility_charges(bill_id);

-- 5. Exchange of changes -------------------------------------------------------------------------
-- utility_meters
CREATE TRIGGER sync_utility_meters_insert AFTER INSERT ON utility_meters WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('utility_meters', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;
CREATE TRIGGER sync_utility_meters_update AFTER UPDATE ON utility_meters WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('utility_meters', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
  INSERT INTO sync_outbox (table_name, row_key, at)
    SELECT 'utility_meters', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE OLD.id IS NOT NEW.id;
END;
CREATE TRIGGER sync_utility_meters_delete AFTER DELETE ON utility_meters WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('utility_meters', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;
-- utility_readings
CREATE TRIGGER sync_utility_readings_insert AFTER INSERT ON utility_readings WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('utility_readings', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;
CREATE TRIGGER sync_utility_readings_update AFTER UPDATE ON utility_readings WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('utility_readings', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
  INSERT INTO sync_outbox (table_name, row_key, at)
    SELECT 'utility_readings', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE OLD.id IS NOT NEW.id;
END;
CREATE TRIGGER sync_utility_readings_delete AFTER DELETE ON utility_readings WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('utility_readings', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;
-- utility_bills
CREATE TRIGGER sync_utility_bills_insert AFTER INSERT ON utility_bills WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('utility_bills', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;
CREATE TRIGGER sync_utility_bills_update AFTER UPDATE ON utility_bills WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('utility_bills', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
  INSERT INTO sync_outbox (table_name, row_key, at)
    SELECT 'utility_bills', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE OLD.id IS NOT NEW.id;
END;
CREATE TRIGGER sync_utility_bills_delete AFTER DELETE ON utility_bills WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('utility_bills', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;
-- utility_charges
CREATE TRIGGER sync_utility_charges_insert AFTER INSERT ON utility_charges WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('utility_charges', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;
CREATE TRIGGER sync_utility_charges_update AFTER UPDATE ON utility_charges WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('utility_charges', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
  INSERT INTO sync_outbox (table_name, row_key, at)
    SELECT 'utility_charges', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE OLD.id IS NOT NEW.id;
END;
CREATE TRIGGER sync_utility_charges_delete AFTER DELETE ON utility_charges WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('utility_charges', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;
