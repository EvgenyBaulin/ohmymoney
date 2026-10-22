-- Exchange between devices: what a device remembers about the journal files of the shared
-- folder. Forward only.
--
-- Additive only, like 0004 to 0011: new tables and triggers, no column of an old table changes,
-- no row is inserted or updated, so every operation, event and card reads exactly as before.
-- Nothing here is part of the owner's books: the tables are bookkeeping of this device, left
-- out of the export, the transfer archive and the readable copy, and a database restored from a
-- backup brings the memory of the moment the backup was made along with it.
--
-- The triggers write one line into `sync_outbox` for every row that changes in a table of the
-- books — only the table and the key, never a value, so a later column of a table needs no new
-- trigger. They write only while `sync_meta.recording` is '1', which the app sets on the
-- owner's real database and never on a generated data set. The app turns the lines into journal
-- files (`CoreSync`) and deletes them once the file is in the folder.
--
-- Tables of the books that are NOT followed: `settings` (the settings of this device),
-- `rates` (fetched again on each device), `ml_models` and `category_feedback` (learned on each
-- device), and the bookkeeping tables below.
--
-- Needs SQLite 3.37 or later, as 0004 to 0011 do.

-- 1. Bookkeeping ----------------------------------------------------------------------------------
CREATE TABLE sync_meta (
  key    TEXT PRIMARY KEY,
  value  TEXT NOT NULL
);

-- Rows changed and not yet written into a journal file. `at` is the moment of the change, UTC,
-- `YYYY-MM-DDTHH:MM:SSZ` (the form of the journal). `row_key` is the primary key of the row.
CREATE TABLE sync_outbox (
  seq         INTEGER PRIMARY KEY AUTOINCREMENT,
  table_name  TEXT NOT NULL,
  row_key     TEXT NOT NULL,
  at          TEXT NOT NULL
);

-- The version of a row this device holds: when it was made and by which device. It is the
-- `base` of the next edit of the row, which is how two devices tell "built on mine" from
-- "made apart".
CREATE TABLE sync_heads (
  table_name  TEXT NOT NULL,
  row_key     TEXT NOT NULL,
  updated_at  TEXT NOT NULL,
  device_id   TEXT NOT NULL,
  PRIMARY KEY (table_name, row_key)
);

-- Rows another device changed that this device could not take yet (an edit of its own was
-- waiting to be written, or the row broke a constraint). Offered again at the next exchange.
CREATE TABLE sync_deferred (
  table_name  TEXT NOT NULL,
  row_key     TEXT NOT NULL,
  PRIMARY KEY (table_name, row_key)
);

-- The owner's choice in the list of conflicts, waiting to be written into a journal file: the
-- versions of the other device that the next edit of the row settles (JSON, `VersionStamp`s).
CREATE TABLE sync_resolutions (
  table_name  TEXT NOT NULL,
  row_key     TEXT NOT NULL,
  settles     TEXT NOT NULL,
  PRIMARY KEY (table_name, row_key)
);

-- The memory of the exchange (`SyncState` of `CoreSync`, JSON): which journal files are applied
-- and every version of every row they carried. One row.
CREATE TABLE sync_state (
  id    INTEGER PRIMARY KEY CHECK (id = 1),
  body  TEXT NOT NULL
);

-- 2. Triggers on the tables of the books ------------------------------------------------------------

-- account_groups
CREATE TRIGGER sync_account_groups_insert AFTER INSERT ON account_groups WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('account_groups', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;
CREATE TRIGGER sync_account_groups_update AFTER UPDATE ON account_groups WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('account_groups', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
  INSERT INTO sync_outbox (table_name, row_key, at)
    SELECT 'account_groups', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE OLD.id IS NOT NEW.id;
END;
CREATE TRIGGER sync_account_groups_delete AFTER DELETE ON account_groups WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('account_groups', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;

-- allocation_rules
CREATE TRIGGER sync_allocation_rules_insert AFTER INSERT ON allocation_rules WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('allocation_rules', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;
CREATE TRIGGER sync_allocation_rules_update AFTER UPDATE ON allocation_rules WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('allocation_rules', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
  INSERT INTO sync_outbox (table_name, row_key, at)
    SELECT 'allocation_rules', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE OLD.id IS NOT NEW.id;
END;
CREATE TRIGGER sync_allocation_rules_delete AFTER DELETE ON allocation_rules WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('allocation_rules', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;

-- anomaly_dismissals
CREATE TRIGGER sync_anomaly_dismissals_insert AFTER INSERT ON anomaly_dismissals WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('anomaly_dismissals', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;
CREATE TRIGGER sync_anomaly_dismissals_update AFTER UPDATE ON anomaly_dismissals WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('anomaly_dismissals', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
  INSERT INTO sync_outbox (table_name, row_key, at)
    SELECT 'anomaly_dismissals', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE OLD.id IS NOT NEW.id;
END;
CREATE TRIGGER sync_anomaly_dismissals_delete AFTER DELETE ON anomaly_dismissals WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('anomaly_dismissals', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;

-- asset_valuations
CREATE TRIGGER sync_asset_valuations_insert AFTER INSERT ON asset_valuations WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('asset_valuations', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;
CREATE TRIGGER sync_asset_valuations_update AFTER UPDATE ON asset_valuations WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('asset_valuations', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
  INSERT INTO sync_outbox (table_name, row_key, at)
    SELECT 'asset_valuations', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE OLD.id IS NOT NEW.id;
END;
CREATE TRIGGER sync_asset_valuations_delete AFTER DELETE ON asset_valuations WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('asset_valuations', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;

-- assets
CREATE TRIGGER sync_assets_insert AFTER INSERT ON assets WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('assets', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;
CREATE TRIGGER sync_assets_update AFTER UPDATE ON assets WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('assets', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
  INSERT INTO sync_outbox (table_name, row_key, at)
    SELECT 'assets', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE OLD.id IS NOT NEW.id;
END;
CREATE TRIGGER sync_assets_delete AFTER DELETE ON assets WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('assets', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;

-- banks
CREATE TRIGGER sync_banks_insert AFTER INSERT ON banks WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('banks', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;
CREATE TRIGGER sync_banks_update AFTER UPDATE ON banks WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('banks', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
  INSERT INTO sync_outbox (table_name, row_key, at)
    SELECT 'banks', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE OLD.id IS NOT NEW.id;
END;
CREATE TRIGGER sync_banks_delete AFTER DELETE ON banks WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('banks', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;

-- budgets
CREATE TRIGGER sync_budgets_insert AFTER INSERT ON budgets WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('budgets', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;
CREATE TRIGGER sync_budgets_update AFTER UPDATE ON budgets WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('budgets', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
  INSERT INTO sync_outbox (table_name, row_key, at)
    SELECT 'budgets', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE OLD.id IS NOT NEW.id;
END;
CREATE TRIGGER sync_budgets_delete AFTER DELETE ON budgets WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('budgets', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;

-- cards
CREATE TRIGGER sync_cards_insert AFTER INSERT ON cards WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('cards', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;
CREATE TRIGGER sync_cards_update AFTER UPDATE ON cards WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('cards', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
  INSERT INTO sync_outbox (table_name, row_key, at)
    SELECT 'cards', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE OLD.id IS NOT NEW.id;
END;
CREATE TRIGGER sync_cards_delete AFTER DELETE ON cards WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('cards', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;

-- cashback_rules
CREATE TRIGGER sync_cashback_rules_insert AFTER INSERT ON cashback_rules WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('cashback_rules', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;
CREATE TRIGGER sync_cashback_rules_update AFTER UPDATE ON cashback_rules WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('cashback_rules', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
  INSERT INTO sync_outbox (table_name, row_key, at)
    SELECT 'cashback_rules', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE OLD.id IS NOT NEW.id;
END;
CREATE TRIGGER sync_cashback_rules_delete AFTER DELETE ON cashback_rules WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('cashback_rules', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;

-- categories
CREATE TRIGGER sync_categories_insert AFTER INSERT ON categories WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('categories', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;
CREATE TRIGGER sync_categories_update AFTER UPDATE ON categories WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('categories', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
  INSERT INTO sync_outbox (table_name, row_key, at)
    SELECT 'categories', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE OLD.id IS NOT NEW.id;
END;
CREATE TRIGGER sync_categories_delete AFTER DELETE ON categories WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('categories', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;

-- currencies
CREATE TRIGGER sync_currencies_insert AFTER INSERT ON currencies WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('currencies', NEW.code, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;
CREATE TRIGGER sync_currencies_update AFTER UPDATE ON currencies WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('currencies', NEW.code, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
  INSERT INTO sync_outbox (table_name, row_key, at)
    SELECT 'currencies', OLD.code, strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE OLD.code IS NOT NEW.code;
END;
CREATE TRIGGER sync_currencies_delete AFTER DELETE ON currencies WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('currencies', OLD.code, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;

-- custom_currencies
CREATE TRIGGER sync_custom_currencies_insert AFTER INSERT ON custom_currencies WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('custom_currencies', NEW.code, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;
CREATE TRIGGER sync_custom_currencies_update AFTER UPDATE ON custom_currencies WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('custom_currencies', NEW.code, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
  INSERT INTO sync_outbox (table_name, row_key, at)
    SELECT 'custom_currencies', OLD.code, strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE OLD.code IS NOT NEW.code;
END;
CREATE TRIGGER sync_custom_currencies_delete AFTER DELETE ON custom_currencies WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('custom_currencies', OLD.code, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;

-- debt_costs
CREATE TRIGGER sync_debt_costs_insert AFTER INSERT ON debt_costs WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('debt_costs', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;
CREATE TRIGGER sync_debt_costs_update AFTER UPDATE ON debt_costs WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('debt_costs', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
  INSERT INTO sync_outbox (table_name, row_key, at)
    SELECT 'debt_costs', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE OLD.id IS NOT NEW.id;
END;
CREATE TRIGGER sync_debt_costs_delete AFTER DELETE ON debt_costs WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('debt_costs', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;

-- debt_entries
CREATE TRIGGER sync_debt_entries_insert AFTER INSERT ON debt_entries WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('debt_entries', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;
CREATE TRIGGER sync_debt_entries_update AFTER UPDATE ON debt_entries WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('debt_entries', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
  INSERT INTO sync_outbox (table_name, row_key, at)
    SELECT 'debt_entries', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE OLD.id IS NOT NEW.id;
END;
CREATE TRIGGER sync_debt_entries_delete AFTER DELETE ON debt_entries WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('debt_entries', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;

-- debt_instalments
CREATE TRIGGER sync_debt_instalments_insert AFTER INSERT ON debt_instalments WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('debt_instalments', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;
CREATE TRIGGER sync_debt_instalments_update AFTER UPDATE ON debt_instalments WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('debt_instalments', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
  INSERT INTO sync_outbox (table_name, row_key, at)
    SELECT 'debt_instalments', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE OLD.id IS NOT NEW.id;
END;
CREATE TRIGGER sync_debt_instalments_delete AFTER DELETE ON debt_instalments WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('debt_instalments', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;

-- debts
CREATE TRIGGER sync_debts_insert AFTER INSERT ON debts WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('debts', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;
CREATE TRIGGER sync_debts_update AFTER UPDATE ON debts WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('debts', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
  INSERT INTO sync_outbox (table_name, row_key, at)
    SELECT 'debts', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE OLD.id IS NOT NEW.id;
END;
CREATE TRIGGER sync_debts_delete AFTER DELETE ON debts WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('debts', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;

-- events
CREATE TRIGGER sync_events_insert AFTER INSERT ON events WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('events', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;
CREATE TRIGGER sync_events_update AFTER UPDATE ON events WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('events', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
  INSERT INTO sync_outbox (table_name, row_key, at)
    SELECT 'events', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE OLD.id IS NOT NEW.id;
END;
CREATE TRIGGER sync_events_delete AFTER DELETE ON events WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('events', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;

-- expected_income
CREATE TRIGGER sync_expected_income_insert AFTER INSERT ON expected_income WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('expected_income', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;
CREATE TRIGGER sync_expected_income_update AFTER UPDATE ON expected_income WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('expected_income', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
  INSERT INTO sync_outbox (table_name, row_key, at)
    SELECT 'expected_income', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE OLD.id IS NOT NEW.id;
END;
CREATE TRIGGER sync_expected_income_delete AFTER DELETE ON expected_income WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('expected_income', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;

-- expected_income_links
CREATE TRIGGER sync_expected_income_links_insert AFTER INSERT ON expected_income_links WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('expected_income_links', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;
CREATE TRIGGER sync_expected_income_links_update AFTER UPDATE ON expected_income_links WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('expected_income_links', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
  INSERT INTO sync_outbox (table_name, row_key, at)
    SELECT 'expected_income_links', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE OLD.id IS NOT NEW.id;
END;
CREATE TRIGGER sync_expected_income_links_delete AFTER DELETE ON expected_income_links WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('expected_income_links', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;

-- goals
CREATE TRIGGER sync_goals_insert AFTER INSERT ON goals WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('goals', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;
CREATE TRIGGER sync_goals_update AFTER UPDATE ON goals WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('goals', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
  INSERT INTO sync_outbox (table_name, row_key, at)
    SELECT 'goals', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE OLD.id IS NOT NEW.id;
END;
CREATE TRIGGER sync_goals_delete AFTER DELETE ON goals WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('goals', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;

-- import_batches
CREATE TRIGGER sync_import_batches_insert AFTER INSERT ON import_batches WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('import_batches', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;
CREATE TRIGGER sync_import_batches_update AFTER UPDATE ON import_batches WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('import_batches', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
  INSERT INTO sync_outbox (table_name, row_key, at)
    SELECT 'import_batches', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE OLD.id IS NOT NEW.id;
END;
CREATE TRIGGER sync_import_batches_delete AFTER DELETE ON import_batches WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('import_batches', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;

-- import_mappings
CREATE TRIGGER sync_import_mappings_insert AFTER INSERT ON import_mappings WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('import_mappings', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;
CREATE TRIGGER sync_import_mappings_update AFTER UPDATE ON import_mappings WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('import_mappings', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
  INSERT INTO sync_outbox (table_name, row_key, at)
    SELECT 'import_mappings', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE OLD.id IS NOT NEW.id;
END;
CREATE TRIGGER sync_import_mappings_delete AFTER DELETE ON import_mappings WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('import_mappings', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;

-- payment_methods
CREATE TRIGGER sync_payment_methods_insert AFTER INSERT ON payment_methods WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('payment_methods', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;
CREATE TRIGGER sync_payment_methods_update AFTER UPDATE ON payment_methods WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('payment_methods', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
  INSERT INTO sync_outbox (table_name, row_key, at)
    SELECT 'payment_methods', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE OLD.id IS NOT NEW.id;
END;
CREATE TRIGGER sync_payment_methods_delete AFTER DELETE ON payment_methods WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('payment_methods', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;

-- people
CREATE TRIGGER sync_people_insert AFTER INSERT ON people WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('people', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;
CREATE TRIGGER sync_people_update AFTER UPDATE ON people WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('people', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
  INSERT INTO sync_outbox (table_name, row_key, at)
    SELECT 'people', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE OLD.id IS NOT NEW.id;
END;
CREATE TRIGGER sync_people_delete AFTER DELETE ON people WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('people', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;

-- places
CREATE TRIGGER sync_places_insert AFTER INSERT ON places WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('places', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;
CREATE TRIGGER sync_places_update AFTER UPDATE ON places WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('places', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
  INSERT INTO sync_outbox (table_name, row_key, at)
    SELECT 'places', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE OLD.id IS NOT NEW.id;
END;
CREATE TRIGGER sync_places_delete AFTER DELETE ON places WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('places', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;

-- reconciliation_balances
CREATE TRIGGER sync_reconciliation_balances_insert AFTER INSERT ON reconciliation_balances WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('reconciliation_balances', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;
CREATE TRIGGER sync_reconciliation_balances_update AFTER UPDATE ON reconciliation_balances WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('reconciliation_balances', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
  INSERT INTO sync_outbox (table_name, row_key, at)
    SELECT 'reconciliation_balances', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE OLD.id IS NOT NEW.id;
END;
CREATE TRIGGER sync_reconciliation_balances_delete AFTER DELETE ON reconciliation_balances WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('reconciliation_balances', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;

-- reconciliations
CREATE TRIGGER sync_reconciliations_insert AFTER INSERT ON reconciliations WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('reconciliations', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;
CREATE TRIGGER sync_reconciliations_update AFTER UPDATE ON reconciliations WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('reconciliations', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
  INSERT INTO sync_outbox (table_name, row_key, at)
    SELECT 'reconciliations', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE OLD.id IS NOT NEW.id;
END;
CREATE TRIGGER sync_reconciliations_delete AFTER DELETE ON reconciliations WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('reconciliations', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;

-- reimbursement_links
CREATE TRIGGER sync_reimbursement_links_insert AFTER INSERT ON reimbursement_links WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('reimbursement_links', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;
CREATE TRIGGER sync_reimbursement_links_update AFTER UPDATE ON reimbursement_links WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('reimbursement_links', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
  INSERT INTO sync_outbox (table_name, row_key, at)
    SELECT 'reimbursement_links', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE OLD.id IS NOT NEW.id;
END;
CREATE TRIGGER sync_reimbursement_links_delete AFTER DELETE ON reimbursement_links WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('reimbursement_links', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;

-- scenarios
CREATE TRIGGER sync_scenarios_insert AFTER INSERT ON scenarios WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('scenarios', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;
CREATE TRIGGER sync_scenarios_update AFTER UPDATE ON scenarios WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('scenarios', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
  INSERT INTO sync_outbox (table_name, row_key, at)
    SELECT 'scenarios', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE OLD.id IS NOT NEW.id;
END;
CREATE TRIGGER sync_scenarios_delete AFTER DELETE ON scenarios WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('scenarios', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;

-- scheduled_payments
CREATE TRIGGER sync_scheduled_payments_insert AFTER INSERT ON scheduled_payments WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('scheduled_payments', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;
CREATE TRIGGER sync_scheduled_payments_update AFTER UPDATE ON scheduled_payments WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('scheduled_payments', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
  INSERT INTO sync_outbox (table_name, row_key, at)
    SELECT 'scheduled_payments', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE OLD.id IS NOT NEW.id;
END;
CREATE TRIGGER sync_scheduled_payments_delete AFTER DELETE ON scheduled_payments WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('scheduled_payments', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;

-- subscription_prices
CREATE TRIGGER sync_subscription_prices_insert AFTER INSERT ON subscription_prices WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('subscription_prices', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;
CREATE TRIGGER sync_subscription_prices_update AFTER UPDATE ON subscription_prices WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('subscription_prices', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
  INSERT INTO sync_outbox (table_name, row_key, at)
    SELECT 'subscription_prices', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE OLD.id IS NOT NEW.id;
END;
CREATE TRIGGER sync_subscription_prices_delete AFTER DELETE ON subscription_prices WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('subscription_prices', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;

-- templates
CREATE TRIGGER sync_templates_insert AFTER INSERT ON templates WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('templates', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;
CREATE TRIGGER sync_templates_update AFTER UPDATE ON templates WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('templates', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
  INSERT INTO sync_outbox (table_name, row_key, at)
    SELECT 'templates', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE OLD.id IS NOT NEW.id;
END;
CREATE TRIGGER sync_templates_delete AFTER DELETE ON templates WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('templates', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;

-- transaction_parts
CREATE TRIGGER sync_transaction_parts_insert AFTER INSERT ON transaction_parts WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('transaction_parts', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;
CREATE TRIGGER sync_transaction_parts_update AFTER UPDATE ON transaction_parts WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('transaction_parts', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
  INSERT INTO sync_outbox (table_name, row_key, at)
    SELECT 'transaction_parts', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE OLD.id IS NOT NEW.id;
END;
CREATE TRIGGER sync_transaction_parts_delete AFTER DELETE ON transaction_parts WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('transaction_parts', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;

-- transactions
CREATE TRIGGER sync_transactions_insert AFTER INSERT ON transactions WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('transactions', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;
CREATE TRIGGER sync_transactions_update AFTER UPDATE ON transactions WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('transactions', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
  INSERT INTO sync_outbox (table_name, row_key, at)
    SELECT 'transactions', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE OLD.id IS NOT NEW.id;
END;
CREATE TRIGGER sync_transactions_delete AFTER DELETE ON transactions WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('transactions', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;

-- transfers
CREATE TRIGGER sync_transfers_insert AFTER INSERT ON transfers WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('transfers', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;
CREATE TRIGGER sync_transfers_update AFTER UPDATE ON transfers WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('transfers', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
  INSERT INTO sync_outbox (table_name, row_key, at)
    SELECT 'transfers', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE OLD.id IS NOT NEW.id;
END;
CREATE TRIGGER sync_transfers_delete AFTER DELETE ON transfers WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('transfers', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;
