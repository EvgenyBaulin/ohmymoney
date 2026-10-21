-- OhMyMoney initial schema.
--
-- Conventions, kept deliberately plain so that a future Windows port can use the same
-- files with any SQLite driver:
--   * identifiers are UUID strings in TEXT columns;
--   * money lives in INTEGER columns named *_e4, in units of 1/10000;
--   * exchange rates are decimal strings in TEXT, never floating point;
--   * calendar days are TEXT 'YYYY-MM-DD', months are TEXT 'YYYY-MM';
--   * instants are TEXT in UTC, 'YYYY-MM-DD HH:MM:SS.SSS' (the format GRDB writes);
--   * booleans are INTEGER 0/1;
--   * enumerations store the same raw strings as the Swift enums in CoreKit.
-- Rows referenced by operations are archived, never deleted.

PRAGMA foreign_keys = ON;

CREATE TABLE categories (
  id            TEXT PRIMARY KEY,
  parent_id     TEXT REFERENCES categories(id) ON DELETE RESTRICT,
  kind          TEXT NOT NULL CHECK (kind IN ('expense', 'income')),
  name          TEXT NOT NULL,
  sort          INTEGER NOT NULL DEFAULT 0,
  archived      INTEGER NOT NULL DEFAULT 0 CHECK (archived IN (0, 1)),
  -- Empty on a subcategory: it inherits the quality of its parent.
  quality       TEXT CHECK (quality IN ('good', 'neutral', 'bad')),
  -- Goals, Loans, Unknown, Surcharges: cannot be renamed, deleted or given a limit.
  system_role   TEXT CHECK (system_role IN ('goals', 'loans', 'unknown', 'surcharges'))
);
CREATE INDEX idx_categories_parent ON categories(parent_id);
CREATE UNIQUE INDEX idx_categories_system_role ON categories(system_role, kind)
  WHERE system_role IS NOT NULL;

CREATE TABLE people (
  id        TEXT PRIMARY KEY,
  name      TEXT NOT NULL,
  relation  TEXT NOT NULL DEFAULT 'other'
            CHECK (relation IN ('family', 'partner', 'friend', 'other')),
  aliases   TEXT NOT NULL DEFAULT '',   -- newline separated, matched case-insensitively
  archived  INTEGER NOT NULL DEFAULT 0 CHECK (archived IN (0, 1))
);

CREATE TABLE places (
  id        TEXT PRIMARY KEY,
  name      TEXT NOT NULL,
  aliases   TEXT NOT NULL DEFAULT '',
  archived  INTEGER NOT NULL DEFAULT 0 CHECK (archived IN (0, 1))
);

CREATE TABLE payment_methods (
  id          TEXT PRIMARY KEY,
  name        TEXT NOT NULL,
  kind        TEXT NOT NULL DEFAULT 'card'
              CHECK (kind IN ('card', 'cash', 'account', 'other')),
  currency    TEXT,
  aliases     TEXT NOT NULL DEFAULT '',
  is_default  INTEGER NOT NULL DEFAULT 0 CHECK (is_default IN (0, 1)),
  archived    INTEGER NOT NULL DEFAULT 0 CHECK (archived IN (0, 1))
);

CREATE TABLE events (
  id                TEXT PRIMARY KEY,
  name              TEXT NOT NULL,
  kind              TEXT NOT NULL DEFAULT 'other'
                    CHECK (kind IN ('birthday', 'new_year', 'trip', 'holiday', 'other')),
  start_date        TEXT NOT NULL,
  end_date          TEXT NOT NULL,
  budget_e4         INTEGER,
  recurring_yearly  INTEGER NOT NULL DEFAULT 0 CHECK (recurring_yearly IN (0, 1)),
  -- Same series across years, so the same event can be compared year over year.
  series_id         TEXT,
  archived          INTEGER NOT NULL DEFAULT 0 CHECK (archived IN (0, 1))
);
CREATE INDEX idx_events_dates ON events(start_date, end_date);

CREATE TABLE goals (
  id               TEXT PRIMARY KEY,
  name             TEXT NOT NULL,
  target_e4        INTEGER NOT NULL,
  target_date      TEXT,
  monthly_plan_e4  INTEGER,
  -- Every goal owns a subcategory of the system Goals category, created automatically.
  subcategory_id   TEXT REFERENCES categories(id) ON DELETE SET NULL,
  archived         INTEGER NOT NULL DEFAULT 0 CHECK (archived IN (0, 1))
);

CREATE TABLE debts (
  id                    TEXT PRIMARY KEY,
  direction             TEXT NOT NULL CHECK (direction IN ('i_owe', 'owed_to_me')),
  type                  TEXT NOT NULL
                        CHECK (type IN ('loan', 'credit_card', 'installment', 'personal')),
  name                  TEXT NOT NULL,
  person_id             TEXT REFERENCES people(id) ON DELETE SET NULL,
  currency              TEXT NOT NULL DEFAULT 'RUB',
  interest_rate         TEXT,
  monthly_payment_e4    INTEGER,
  payment_day           INTEGER,
  remind_days_before    INTEGER,
  -- true for debts that existed before the app: their payments are expenses in Loans.
  payments_are_expenses INTEGER NOT NULL DEFAULT 1 CHECK (payments_are_expenses IN (0, 1)),
  origin                TEXT NOT NULL DEFAULT 'existing'
                        CHECK (origin IN ('existing', 'purchase')),
  note                  TEXT,
  closed                INTEGER NOT NULL DEFAULT 0 CHECK (closed IN (0, 1)),
  loans_subcategory_id  TEXT REFERENCES categories(id) ON DELETE SET NULL
);

CREATE TABLE import_batches (
  id                TEXT PRIMARY KEY,
  source_file_name  TEXT NOT NULL,
  imported_at       TEXT NOT NULL,
  rows_total        INTEGER NOT NULL DEFAULT 0,
  rows_imported     INTEGER NOT NULL DEFAULT 0,
  rows_skipped      INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE transactions (
  id                TEXT PRIMARY KEY,
  kind              TEXT NOT NULL
                    CHECK (kind IN ('expense', 'income', 'refund', 'reimbursement')),
  occurred_at       TEXT NOT NULL,
  currency          TEXT NOT NULL DEFAULT 'RUB',
  amount_e4         INTEGER NOT NULL,
  -- The expression exactly as typed, when the amount was entered as a formula.
  amount_expr       TEXT,
  rate              TEXT,
  rate_date         TEXT,
  rate_source       TEXT CHECK (rate_source IN ('cbr', 'cbr_mirror', 'manual', 'import')),
  rate_provisional  INTEGER NOT NULL DEFAULT 0 CHECK (rate_provisional IN (0, 1)),
  amount_rub_e4     INTEGER NOT NULL,
  note              TEXT,
  place_id          TEXT REFERENCES places(id) ON DELETE SET NULL,
  payment_method_id TEXT REFERENCES payment_methods(id) ON DELETE SET NULL,
  -- Income only: which month the money is for.
  period_month      TEXT,
  debt_id           TEXT REFERENCES debts(id) ON DELETE SET NULL,
  credit_debt_id    TEXT REFERENCES debts(id) ON DELETE SET NULL,
  import_batch_id   TEXT REFERENCES import_batches(id) ON DELETE SET NULL,
  external_id       TEXT,
  created_at        TEXT NOT NULL,
  updated_at        TEXT NOT NULL,
  -- Soft delete, so undo can bring an operation back.
  deleted_at        TEXT
);
CREATE INDEX idx_transactions_occurred ON transactions(occurred_at);
CREATE INDEX idx_transactions_alive ON transactions(deleted_at, occurred_at);
CREATE INDEX idx_transactions_place ON transactions(place_id);
CREATE INDEX idx_transactions_batch ON transactions(import_batch_id);
CREATE UNIQUE INDEX idx_transactions_external ON transactions(external_id)
  WHERE external_id IS NOT NULL;

CREATE TABLE transaction_parts (
  id                   TEXT PRIMARY KEY,
  transaction_id       TEXT NOT NULL REFERENCES transactions(id) ON DELETE CASCADE,
  category_id          TEXT REFERENCES categories(id) ON DELETE RESTRICT,
  category_source      TEXT NOT NULL DEFAULT 'manual'
                       CHECK (category_source IN
                         ('manual', 'history', 'model', 'template', 'import', 'system')),
  quality              TEXT CHECK (quality IN ('good', 'neutral', 'bad')),
  quality_source       TEXT CHECK (quality_source IN
                         ('system', 'history', 'category', 'manual')),
  amount_e4            INTEGER NOT NULL,
  amount_rub_e4        INTEGER NOT NULL,
  -- Analytics cut only: it never changes whether this is my spending.
  for_whom             TEXT NOT NULL DEFAULT 'me'
                       CHECK (for_whom IN ('me', 'partner', 'friends', 'family', 'other')),
  for_person_id        TEXT REFERENCES people(id) ON DELETE SET NULL,
  -- Paid for somebody else and expected back: not my spending until written off.
  reimbursable         INTEGER NOT NULL DEFAULT 0 CHECK (reimbursable IN (0, 1)),
  debtor_person_id     TEXT REFERENCES people(id) ON DELETE SET NULL,
  reimbursement_status TEXT CHECK (reimbursement_status IN
                         ('expected', 'returned', 'written_off')),
  event_id             TEXT REFERENCES events(id) ON DELETE SET NULL,
  goal_id              TEXT REFERENCES goals(id) ON DELETE SET NULL,
  note                 TEXT
);
CREATE INDEX idx_parts_transaction ON transaction_parts(transaction_id);
CREATE INDEX idx_parts_category ON transaction_parts(category_id);
CREATE INDEX idx_parts_event ON transaction_parts(event_id);
CREATE INDEX idx_parts_reimbursement ON transaction_parts(reimbursement_status)
  WHERE reimbursable = 1;

CREATE TABLE reimbursement_links (
  id                   TEXT PRIMARY KEY,
  reimbursement_tx_id  TEXT NOT NULL REFERENCES transactions(id) ON DELETE CASCADE,
  part_id              TEXT NOT NULL REFERENCES transaction_parts(id) ON DELETE CASCADE,
  amount_e4            INTEGER NOT NULL
);
CREATE INDEX idx_reimbursement_links_part ON reimbursement_links(part_id);

CREATE TABLE debt_entries (
  id              TEXT PRIMARY KEY,
  debt_id         TEXT NOT NULL REFERENCES debts(id) ON DELETE CASCADE,
  group_name      TEXT,
  date            TEXT,
  description     TEXT,
  -- A share of a larger amount: "full 1 000 000, share 1/2".
  full_amount_e4  INTEGER,
  share           TEXT,
  -- Signed: plus grows the debt, minus reduces it.
  amount_e4       INTEGER NOT NULL,
  kind            TEXT NOT NULL CHECK (kind IN
                    ('borrowed', 'offset', 'payment', 'transfer_in', 'transfer_out',
                     'adjustment')),
  transaction_id  TEXT REFERENCES transactions(id) ON DELETE SET NULL,
  note            TEXT
);
CREATE INDEX idx_debt_entries_debt ON debt_entries(debt_id);

CREATE TABLE templates (
  id           TEXT PRIMARY KEY,
  text         TEXT NOT NULL,
  category_id  TEXT REFERENCES categories(id) ON DELETE SET NULL,
  amount_e4    INTEGER,
  currency     TEXT,
  pinned       INTEGER NOT NULL DEFAULT 0 CHECK (pinned IN (0, 1)),
  use_count    INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE currencies (
  code     TEXT PRIMARY KEY,
  enabled  INTEGER NOT NULL DEFAULT 0 CHECK (enabled IN (0, 1)),
  sort     INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE rates (
  date          TEXT NOT NULL,
  currency      TEXT NOT NULL,
  -- Decimal string, exactly as published, with the nominal kept separately.
  rub_per_unit  TEXT NOT NULL,
  nominal       INTEGER NOT NULL DEFAULT 1,
  source        TEXT NOT NULL CHECK (source IN ('cbr', 'cbr_mirror', 'manual', 'import')),
  fetched_at    TEXT,
  PRIMARY KEY (date, currency, source)
);
CREATE INDEX idx_rates_lookup ON rates(currency, date);

CREATE TABLE scheduled_payments (
  id                       TEXT PRIMARY KEY,
  name                     TEXT NOT NULL,
  kind                     TEXT NOT NULL CHECK (kind IN ('bill', 'subscription')),
  amount_e4                INTEGER NOT NULL,
  currency                 TEXT NOT NULL DEFAULT 'RUB',
  category_id              TEXT REFERENCES categories(id) ON DELETE SET NULL,
  payment_method_id        TEXT REFERENCES payment_methods(id) ON DELETE SET NULL,
  for_whom                 TEXT NOT NULL DEFAULT 'me'
                           CHECK (for_whom IN ('me', 'partner', 'friends', 'family', 'other')),
  for_person_id            TEXT REFERENCES people(id) ON DELETE SET NULL,
  reimbursable             INTEGER NOT NULL DEFAULT 0 CHECK (reimbursable IN (0, 1)),
  debtor_person_id         TEXT REFERENCES people(id) ON DELETE SET NULL,
  -- How much that person gives back to me, which may differ from what I pay.
  reimbursement_amount_e4  INTEGER,
  reimbursement_currency   TEXT,
  freq                     TEXT NOT NULL DEFAULT 'monthly'
                           CHECK (freq IN ('weekly', 'monthly', 'yearly')),
  interval                 INTEGER NOT NULL DEFAULT 1,
  day                      INTEGER,
  month                    INTEGER,
  next_date                TEXT,
  end_date                 TEXT,
  trial_end                TEXT,
  cancel_url               TEXT,
  remind_days_before       INTEGER,
  active                   INTEGER NOT NULL DEFAULT 1 CHECK (active IN (0, 1))
);

CREATE TABLE subscription_prices (
  id          TEXT PRIMARY KEY,
  payment_id  TEXT NOT NULL REFERENCES scheduled_payments(id) ON DELETE CASCADE,
  date        TEXT NOT NULL,
  amount_e4   INTEGER NOT NULL
);
CREATE INDEX idx_subscription_prices_payment ON subscription_prices(payment_id, date);

CREATE TABLE expected_income (
  id              TEXT PRIMARY KEY,
  name            TEXT NOT NULL,
  category_id     TEXT REFERENCES categories(id) ON DELETE SET NULL,
  person_id       TEXT REFERENCES people(id) ON DELETE SET NULL,
  kind            TEXT NOT NULL CHECK (kind IN ('one_off', 'recurring')),
  total_e4        INTEGER NOT NULL,
  currency        TEXT NOT NULL DEFAULT 'RUB',
  due_date        TEXT,
  freq            TEXT CHECK (freq IN ('weekly', 'monthly', 'yearly')),
  day             INTEGER,
  parts_expected  INTEGER NOT NULL DEFAULT 1,
  closed          INTEGER NOT NULL DEFAULT 0 CHECK (closed IN (0, 1))
);

CREATE TABLE expected_income_links (
  id                  TEXT PRIMARY KEY,
  expected_income_id  TEXT NOT NULL REFERENCES expected_income(id) ON DELETE CASCADE,
  transaction_id      TEXT NOT NULL REFERENCES transactions(id) ON DELETE CASCADE
);

CREATE TABLE budgets (
  id           TEXT PRIMARY KEY,
  scope        TEXT NOT NULL CHECK (scope IN ('category', 'bad_total', 'for_whom')),
  category_id  TEXT REFERENCES categories(id) ON DELETE CASCADE,
  for_whom     TEXT CHECK (for_whom IN ('me', 'partner', 'friends', 'family', 'other')),
  -- Rubles per month.
  amount_e4    INTEGER NOT NULL,
  rollover     INTEGER NOT NULL DEFAULT 0 CHECK (rollover IN (0, 1))
);

CREATE TABLE reconciliations (
  id                   TEXT PRIMARY KEY,
  date                 TEXT NOT NULL,
  actual_total_rub_e4  INTEGER NOT NULL,
  expected_total_rub_e4 INTEGER,
  difference_e4        INTEGER,
  transaction_id       TEXT REFERENCES transactions(id) ON DELETE SET NULL
);

CREATE TABLE import_mappings (
  id                    TEXT PRIMARY KEY,
  source_kind           TEXT NOT NULL CHECK (source_kind IN ('expense', 'income')),
  source_category       TEXT NOT NULL,
  source_subcategory    TEXT,
  target_category_id    TEXT REFERENCES categories(id) ON DELETE SET NULL,
  target_for_whom       TEXT CHECK (target_for_whom IN
                          ('me', 'partner', 'friends', 'family', 'other')),
  target_for_person_id  TEXT REFERENCES people(id) ON DELETE SET NULL,
  -- The source subcategory is really a place, not a category.
  subcategory_is_place  INTEGER NOT NULL DEFAULT 0 CHECK (subcategory_is_place IN (0, 1)),
  target_event_id       TEXT REFERENCES events(id) ON DELETE SET NULL,
  target_quality        TEXT CHECK (target_quality IN ('good', 'neutral', 'bad')),
  special_rule          TEXT
);
CREATE UNIQUE INDEX idx_import_mappings_source
  ON import_mappings(source_kind, source_category, source_subcategory);

CREATE TABLE category_feedback (
  id                     TEXT PRIMARY KEY,
  text                   TEXT NOT NULL,
  predicted_category_id  TEXT REFERENCES categories(id) ON DELETE SET NULL,
  chosen_category_id     TEXT REFERENCES categories(id) ON DELETE SET NULL,
  at                     TEXT NOT NULL
);

CREATE TABLE ml_models (
  id            TEXT PRIMARY KEY,
  kind          TEXT NOT NULL,
  version       INTEGER NOT NULL DEFAULT 1,
  trained_at    TEXT NOT NULL,
  metrics_json  TEXT,
  file          TEXT NOT NULL,
  checksum      TEXT NOT NULL
);

CREATE TABLE anomaly_dismissals (
  id              TEXT PRIMARY KEY,
  rule            TEXT NOT NULL,
  transaction_id  TEXT REFERENCES transactions(id) ON DELETE CASCADE,
  at              TEXT NOT NULL
);

CREATE TABLE settings (
  key    TEXT PRIMARY KEY,
  value  TEXT NOT NULL
);
