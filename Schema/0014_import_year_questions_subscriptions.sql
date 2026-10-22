-- Import, the plan of the year, saved questions and subscriptions. Forward only.
--
-- Additive only, like 0004 to 0013: new columns that start empty, new tables, and no data step.
-- No row is inserted or updated, so every operation, transfer, import, payment and setting the
-- update finds reads exactly as it did: an operation did not come from a statement, a transfer
-- arrived when it was sent, nobody has tags of the year, saved views, terms of a subscription
-- or the numbers of one's own contracts. No CHECK on an added column: adding one checks every
-- other CHECK of the table again.
--
-- The settings these features need no column: they are keys of the `settings` table, absent
-- until the owner changes them (`import.unsortedCategory`, `planning.monthBuffer`,
-- `planning.monthBuffer.incomeAtSet`, `planning.monthBuffer.marks`). The category «Не разобрано»
-- is an ordinary category the app creates on first need and names by that key: the CHECK of
-- `categories.system_role` could only be widened by rebuilding the table.
--
-- Needs SQLite 3.37 or later, as 0004 to 0013 do.

-- 1. Operations: where an operation came from --------------------------------------------------------
-- `source`: `manual`, `statement`, `screenshot` or `receipt`; NULL reads as `manual`.
-- `bank_status`: `posted`, `pending`, `declined` or `unknown` as the bank said; NULL reads as
-- `posted`. `posted_on`: the day the bank posted the operation, when it differs from the day of
-- the operation. `dedup_key`: the versioned hash of the normalised fields of a statement line
-- (never its text), which finds the same line when the same period is loaded again. The index is
-- not unique: two identical lines of one day are two operations, and the loader counts repeats.
ALTER TABLE transactions ADD COLUMN source TEXT;
ALTER TABLE transactions ADD COLUMN bank_status TEXT;
ALTER TABLE transactions ADD COLUMN posted_on TEXT;
ALTER TABLE transactions ADD COLUMN dedup_key TEXT;
CREATE INDEX idx_transactions_dedup ON transactions(dedup_key) WHERE dedup_key IS NOT NULL;

-- 2. Imports: what each loaded statement was ---------------------------------------------------------
-- `import_batches` has been there since 0001 (file name, moment, line counts) and operations point
-- at it by `import_batch_id`. `rows_total`, `rows_imported` and `rows_skipped` are the lines read,
-- added and found already there. New: the account the statement belongs to, the profile that read
-- it, the period it covers, the lines the bank refused and the lines nothing could read, a hash of
-- the file (the same file twice is noticed) and the moment the import was undone (the list keeps
-- the row, the operations it added are gone).
ALTER TABLE import_batches ADD COLUMN payment_method_id TEXT
  REFERENCES payment_methods(id) ON DELETE SET NULL;
ALTER TABLE import_batches ADD COLUMN profile_id TEXT;
ALTER TABLE import_batches ADD COLUMN period_from TEXT;
ALTER TABLE import_batches ADD COLUMN period_to TEXT;
ALTER TABLE import_batches ADD COLUMN rows_declined INTEGER NOT NULL DEFAULT 0;
ALTER TABLE import_batches ADD COLUMN rows_unparsed INTEGER NOT NULL DEFAULT 0;
ALTER TABLE import_batches ADD COLUMN file_hash TEXT;
ALTER TABLE import_batches ADD COLUMN undone_at TEXT;

-- 3. Transfers: the moment the money arrived ---------------------------------------------------------
-- NULL: it arrived when it was sent, as every transfer so far. A later moment: the money is on its
-- way between the two accounts until then. Nothing moves a balance by this column yet.
ALTER TABLE transfers ADD COLUMN arrived_at TEXT;

-- 4. Statement profiles of the owner -------------------------------------------------------------------
-- How a file of a bank or of a tracker is read, as the JSON of a `StatementProfile` (patterns and
-- columns as data). The profiles that ship with the app live in code; a profile of the owner's
-- own, made from the columns of a file, is a row here. `id` is the profile's own id
-- (`my-tracker-csv-v1`), not a UUID.
CREATE TABLE statement_profiles (
  id          TEXT PRIMARY KEY,
  bank_name   TEXT NOT NULL DEFAULT '',
  payload     TEXT NOT NULL,
  created_at  TEXT NOT NULL,
  updated_at  TEXT NOT NULL
);

-- 5. Who the owner is, as banks write it --------------------------------------------------------------
-- A phone, a name («Имя Отчество Ф»), the number of a contract or the mask of a card of the owner's
-- own, so a transfer to oneself is recognised. Personal data: it stays in the database (the archive
-- carries it, a new Mac imports at once) and is in no CSV, no exchange file and no report.
CREATE TABLE identity_items (
  id          TEXT PRIMARY KEY,
  kind        TEXT NOT NULL,
  value       TEXT NOT NULL CHECK (length(trim(value)) > 0),
  created_at  TEXT NOT NULL
);
CREATE INDEX idx_identity_items_kind ON identity_items(kind);

-- 6. Saved filters and reports -------------------------------------------------------------------------
-- `kind` is `filter` or `report`; `payload` is the JSON of a `SavedFilter` or a `SavedReport`, keys
-- sorted. The menu «Отчёты» lists them in `sort_order`.
CREATE TABLE saved_views (
  id          TEXT PRIMARY KEY,
  kind        TEXT NOT NULL,
  name        TEXT NOT NULL,
  payload     TEXT NOT NULL,
  sort_order  INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX idx_saved_views_kind ON saved_views(kind, sort_order);

-- 7. The plan of the year -------------------------------------------------------------------------------
-- A limit that holds for one month only: «Подарки» is 5 000 ₽ and December's is 20 000 ₽. One per
-- limit and month; the writer replaces, the reader takes the latest of two (two devices may add one
-- apart), so there is no UNIQUE the exchange could trip on. `month` is `YYYY-MM`.
CREATE TABLE budget_month_exceptions (
  id         TEXT PRIMARY KEY,
  budget_id  TEXT NOT NULL REFERENCES budgets(id) ON DELETE CASCADE,
  month      TEXT NOT NULL,
  amount_e4  INTEGER NOT NULL CHECK (amount_e4 >= 0)
);
CREATE INDEX idx_budget_month_exceptions_budget ON budget_month_exceptions(budget_id, month);

-- The articles of the budget of an event, each with its own planned sum; the sums add up to the
-- budget of the event.
CREATE TABLE event_budget_items (
  id          TEXT PRIMARY KEY,
  event_id    TEXT NOT NULL REFERENCES events(id) ON DELETE CASCADE,
  title       TEXT NOT NULL,
  planned_e4  INTEGER NOT NULL CHECK (planned_e4 >= 0),
  sort        INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX idx_event_budget_items_event ON event_budget_items(event_id, sort);

-- The owner's own templates of events («Сохранить как шаблон»). The ready ones live in code and
-- are never stored. `lines` is the JSON array of `{"title", "shareBp"}`; the shares add up to 10000.
CREATE TABLE event_templates (
  id          TEXT PRIMARY KEY,
  name        TEXT NOT NULL,
  event_kind  TEXT NOT NULL DEFAULT 'other',
  total_e4    INTEGER NOT NULL DEFAULT 0 CHECK (total_e4 >= 0),
  lines       TEXT NOT NULL DEFAULT '[]',
  created_at  TEXT NOT NULL,
  updated_at  TEXT NOT NULL
);

-- 8. Subscriptions ---------------------------------------------------------------------------------------
-- What a subscription carries beyond its scheduled payment (`trial_end`, `end_date` and
-- `cancel_url` are columns of `scheduled_payments` since 0001; the history of the price is
-- `subscription_prices`). One row per payment, keyed by it; a payment without a row has no yearly
-- plan, no tolerance, no type of its own, and its reminders are on.
CREATE TABLE subscription_terms (
  payment_id          TEXT PRIMARY KEY REFERENCES scheduled_payments(id) ON DELETE CASCADE,
  yearly_plan_e4      INTEGER,
  monthly_plan_e4     INTEGER,
  floating            INTEGER NOT NULL DEFAULT 0 CHECK (floating IN (0, 1)),
  tolerance_percent   INTEGER,
  service_type        TEXT,
  needed              INTEGER NOT NULL DEFAULT 0 CHECK (needed IN (0, 1)),
  yearly_reminder_off INTEGER NOT NULL DEFAULT 0 CHECK (yearly_reminder_off IN (0, 1)),
  owner_uses          INTEGER NOT NULL DEFAULT 1 CHECK (owner_uses IN (0, 1))
);

-- «Пользовался»: one day the owner used a subscription.
CREATE TABLE subscription_usage (
  id          TEXT PRIMARY KEY,
  payment_id  TEXT NOT NULL REFERENCES scheduled_payments(id) ON DELETE CASCADE,
  day         TEXT NOT NULL
);
CREATE INDEX idx_subscription_usage_payment ON subscription_usage(payment_id, day);

-- The people a subscription is shared with. No UNIQUE on the pair: the reader takes each person once.
CREATE TABLE subscription_users (
  id          TEXT PRIMARY KEY,
  payment_id  TEXT NOT NULL REFERENCES scheduled_payments(id) ON DELETE CASCADE,
  person_id   TEXT NOT NULL REFERENCES people(id) ON DELETE CASCADE
);
CREATE INDEX idx_subscription_users_payment ON subscription_users(payment_id);

-- «Нужны оба»: a group of same-type subscriptions the owner looked at and decided to keep.
-- `payment_ids` is the JSON array of the payments' ids, sorted, so equal content is equal text.
CREATE TABLE subscription_keep_groups (
  id           TEXT PRIMARY KEY,
  type         TEXT NOT NULL,
  payment_ids  TEXT NOT NULL DEFAULT '[]'
);

-- 9. The new tables travel between devices --------------------------------------------------------------
-- The columns added above need no trigger: the triggers of 0012 write only the table and the key.
-- `identity_items` is not followed: it is personal, and the files of the exchange are not sealed.

-- statement_profiles
CREATE TRIGGER sync_statement_profiles_insert AFTER INSERT ON statement_profiles WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('statement_profiles', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;
CREATE TRIGGER sync_statement_profiles_update AFTER UPDATE ON statement_profiles WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('statement_profiles', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
  INSERT INTO sync_outbox (table_name, row_key, at)
    SELECT 'statement_profiles', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE OLD.id IS NOT NEW.id;
END;
CREATE TRIGGER sync_statement_profiles_delete AFTER DELETE ON statement_profiles WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('statement_profiles', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;

-- saved_views
CREATE TRIGGER sync_saved_views_insert AFTER INSERT ON saved_views WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('saved_views', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;
CREATE TRIGGER sync_saved_views_update AFTER UPDATE ON saved_views WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('saved_views', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
  INSERT INTO sync_outbox (table_name, row_key, at)
    SELECT 'saved_views', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE OLD.id IS NOT NEW.id;
END;
CREATE TRIGGER sync_saved_views_delete AFTER DELETE ON saved_views WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('saved_views', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;

-- budget_month_exceptions
CREATE TRIGGER sync_budget_month_exceptions_insert AFTER INSERT ON budget_month_exceptions WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('budget_month_exceptions', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;
CREATE TRIGGER sync_budget_month_exceptions_update AFTER UPDATE ON budget_month_exceptions WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('budget_month_exceptions', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
  INSERT INTO sync_outbox (table_name, row_key, at)
    SELECT 'budget_month_exceptions', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE OLD.id IS NOT NEW.id;
END;
CREATE TRIGGER sync_budget_month_exceptions_delete AFTER DELETE ON budget_month_exceptions WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('budget_month_exceptions', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;

-- event_budget_items
CREATE TRIGGER sync_event_budget_items_insert AFTER INSERT ON event_budget_items WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('event_budget_items', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;
CREATE TRIGGER sync_event_budget_items_update AFTER UPDATE ON event_budget_items WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('event_budget_items', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
  INSERT INTO sync_outbox (table_name, row_key, at)
    SELECT 'event_budget_items', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE OLD.id IS NOT NEW.id;
END;
CREATE TRIGGER sync_event_budget_items_delete AFTER DELETE ON event_budget_items WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('event_budget_items', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;

-- event_templates
CREATE TRIGGER sync_event_templates_insert AFTER INSERT ON event_templates WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('event_templates', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;
CREATE TRIGGER sync_event_templates_update AFTER UPDATE ON event_templates WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('event_templates', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
  INSERT INTO sync_outbox (table_name, row_key, at)
    SELECT 'event_templates', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE OLD.id IS NOT NEW.id;
END;
CREATE TRIGGER sync_event_templates_delete AFTER DELETE ON event_templates WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('event_templates', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;

-- subscription_terms
CREATE TRIGGER sync_subscription_terms_insert AFTER INSERT ON subscription_terms WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('subscription_terms', NEW.payment_id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;
CREATE TRIGGER sync_subscription_terms_update AFTER UPDATE ON subscription_terms WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('subscription_terms', NEW.payment_id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
  INSERT INTO sync_outbox (table_name, row_key, at)
    SELECT 'subscription_terms', OLD.payment_id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE OLD.payment_id IS NOT NEW.payment_id;
END;
CREATE TRIGGER sync_subscription_terms_delete AFTER DELETE ON subscription_terms WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('subscription_terms', OLD.payment_id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;

-- subscription_usage
CREATE TRIGGER sync_subscription_usage_insert AFTER INSERT ON subscription_usage WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('subscription_usage', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;
CREATE TRIGGER sync_subscription_usage_update AFTER UPDATE ON subscription_usage WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('subscription_usage', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
  INSERT INTO sync_outbox (table_name, row_key, at)
    SELECT 'subscription_usage', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE OLD.id IS NOT NEW.id;
END;
CREATE TRIGGER sync_subscription_usage_delete AFTER DELETE ON subscription_usage WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('subscription_usage', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;

-- subscription_users
CREATE TRIGGER sync_subscription_users_insert AFTER INSERT ON subscription_users WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('subscription_users', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;
CREATE TRIGGER sync_subscription_users_update AFTER UPDATE ON subscription_users WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('subscription_users', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
  INSERT INTO sync_outbox (table_name, row_key, at)
    SELECT 'subscription_users', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE OLD.id IS NOT NEW.id;
END;
CREATE TRIGGER sync_subscription_users_delete AFTER DELETE ON subscription_users WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('subscription_users', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;

-- subscription_keep_groups
CREATE TRIGGER sync_subscription_keep_groups_insert AFTER INSERT ON subscription_keep_groups WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('subscription_keep_groups', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;
CREATE TRIGGER sync_subscription_keep_groups_update AFTER UPDATE ON subscription_keep_groups WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('subscription_keep_groups', NEW.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
  INSERT INTO sync_outbox (table_name, row_key, at)
    SELECT 'subscription_keep_groups', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE OLD.id IS NOT NEW.id;
END;
CREATE TRIGGER sync_subscription_keep_groups_delete AFTER DELETE ON subscription_keep_groups WHEN (SELECT value FROM sync_meta WHERE key = 'recording') = '1'
BEGIN
  INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('subscription_keep_groups', OLD.id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;
