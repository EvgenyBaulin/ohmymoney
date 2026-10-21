-- Cards inside an account and the cashback they earn; a scheduled payment tied to an event; the
-- month a goal's plan starts; debts deleted; the account an expected income is to come to; how a
-- later count keeps its difference, and where a starting balance came from. Forward only.
--
-- Additive only, like 0004: this file creates tables, triggers and indexes and adds columns that
-- start empty. It changes no value an older build wrote. What needs the app — a card for every
-- live account of the kind «card», whether each compared count of a sheet records its
-- difference, and the month the plan of a goal with a monthly plan starts — is the data step
-- that runs right after this file inside the same transaction (`MigrationDataSteps` in
-- AppDatabase, rules in `CardsMigration` and `CountsMigration` in the core): all of it lands, or
-- the file stays exactly as it was. No difference is computed again.
--
-- Needs SQLite 3.37 or later, as 0004 does: the CHECK of an added column is tested against the
-- rows already there. Amounts stay INTEGER in 1/10000 (`*_e4`); currencies are upper-case ISO
-- 4217 codes; months are 'YYYY-MM'; instants are UTC text, as GRDB writes them.

-- 1. Cards -------------------------------------------------------------------------------------
-- A card belongs to one account. The money and the balance stay on the account; a card says
-- what paid and holds its own cashback rules. `aliases`: other names, one per line, as for the
-- accounts. A card anything names is archived, never deleted; an account deleted takes its cards.
CREATE TABLE cards (
  id                 TEXT PRIMARY KEY,
  payment_method_id  TEXT NOT NULL REFERENCES payment_methods(id) ON DELETE CASCADE,
  name               TEXT NOT NULL CHECK (length(trim(name)) > 0),
  aliases            TEXT NOT NULL DEFAULT '',
  -- The order the owner dragged; 0 everywhere is alphabetical.
  sort               INTEGER NOT NULL DEFAULT 0,
  archived           INTEGER NOT NULL DEFAULT 0 CHECK (archived IN (0, 1))
);
CREATE INDEX idx_cards_account ON cards(payment_method_id);

-- The card an operation or a scheduled payment names; NULL: the account itself. Always a card of
-- the row's own account (the triggers of section 3), so money never follows the card.
ALTER TABLE transactions ADD COLUMN card_id TEXT REFERENCES cards(id) ON DELETE RESTRICT;
CREATE INDEX idx_transactions_card ON transactions(card_id) WHERE card_id IS NOT NULL;
ALTER TABLE scheduled_payments ADD COLUMN card_id TEXT
  REFERENCES cards(id) ON DELETE RESTRICT;
CREATE INDEX idx_scheduled_payments_card ON scheduled_payments(card_id)
  WHERE card_id IS NOT NULL;

-- 2. Cashback ----------------------------------------------------------------------------------
-- The cashback the owner typed for one operation, in the currency that moved on the account. An
-- expectation, never income. The currency comes first: the CHECK of the amount reads it.
ALTER TABLE transactions ADD COLUMN cashback_currency TEXT
  CHECK (cashback_currency IS NULL
         OR (length(cashback_currency) = 3 AND cashback_currency NOT GLOB '*[^A-Z]*'));
ALTER TABLE transactions ADD COLUMN cashback_e4 INTEGER
  CHECK ((cashback_e4 IS NULL) = (cashback_currency IS NULL)
         AND (cashback_e4 IS NULL OR cashback_e4 >= 0));

-- «Category — N %», always or only in one month: on a card, or on an account while it has no
-- cards (`card_id` NULL). `category_id` NULL: everything else; `month` NULL: always.
-- `percent_e4` is in 1/10000 of a percent — 1.5 % is 15000 — from 0 to 100 %.
CREATE TABLE cashback_rules (
  id                 TEXT PRIMARY KEY,
  payment_method_id  TEXT NOT NULL REFERENCES payment_methods(id) ON DELETE CASCADE,
  card_id            TEXT REFERENCES cards(id) ON DELETE CASCADE,
  category_id        TEXT REFERENCES categories(id) ON DELETE CASCADE,
  month              TEXT CHECK (month IS NULL OR month GLOB '[0-9][0-9][0-9][0-9]-[01][0-9]'),
  percent_e4         INTEGER NOT NULL CHECK (percent_e4 BETWEEN 0 AND 1000000)
);
-- One rule per holder, month and category.
CREATE UNIQUE INDEX idx_cashback_rules_key ON cashback_rules(
  payment_method_id, COALESCE(card_id, ''), COALESCE(month, ''), COALESCE(category_id, ''));
CREATE INDEX idx_cashback_rules_card ON cashback_rules(card_id) WHERE card_id IS NOT NULL;
CREATE INDEX idx_cashback_rules_category ON cashback_rules(category_id)
  WHERE category_id IS NOT NULL;

-- 3. A card names a card of the row's own account ----------------------------------------------
-- The app checks this before it writes; these catch every other writer. A merge of accounts moves
-- the cards first and the rows that name them after, so it never meets them.
CREATE TRIGGER card_of_account_transactions_insert BEFORE INSERT ON transactions
WHEN NEW.card_id IS NOT NULL AND NOT EXISTS (
  SELECT 1 FROM cards WHERE id = NEW.card_id AND payment_method_id IS NEW.payment_method_id)
BEGIN SELECT RAISE(ABORT, 'card_of_another_account'); END;

CREATE TRIGGER card_of_account_transactions_update
BEFORE UPDATE OF card_id, payment_method_id ON transactions
WHEN NEW.card_id IS NOT NULL AND NOT EXISTS (
  SELECT 1 FROM cards WHERE id = NEW.card_id AND payment_method_id IS NEW.payment_method_id)
BEGIN SELECT RAISE(ABORT, 'card_of_another_account'); END;

CREATE TRIGGER card_of_account_scheduled_insert BEFORE INSERT ON scheduled_payments
WHEN NEW.card_id IS NOT NULL AND NOT EXISTS (
  SELECT 1 FROM cards WHERE id = NEW.card_id AND payment_method_id IS NEW.payment_method_id)
BEGIN SELECT RAISE(ABORT, 'card_of_another_account'); END;

CREATE TRIGGER card_of_account_scheduled_update
BEFORE UPDATE OF card_id, payment_method_id ON scheduled_payments
WHEN NEW.card_id IS NOT NULL AND NOT EXISTS (
  SELECT 1 FROM cards WHERE id = NEW.card_id AND payment_method_id IS NEW.payment_method_id)
BEGIN SELECT RAISE(ABORT, 'card_of_another_account'); END;

CREATE TRIGGER card_of_account_cashback_insert BEFORE INSERT ON cashback_rules
WHEN NEW.card_id IS NOT NULL AND NOT EXISTS (
  SELECT 1 FROM cards WHERE id = NEW.card_id AND payment_method_id IS NEW.payment_method_id)
BEGIN SELECT RAISE(ABORT, 'card_of_another_account'); END;

CREATE TRIGGER card_of_account_cashback_update
BEFORE UPDATE OF card_id, payment_method_id ON cashback_rules
WHEN NEW.card_id IS NOT NULL AND NOT EXISTS (
  SELECT 1 FROM cards WHERE id = NEW.card_id AND payment_method_id IS NEW.payment_method_id)
BEGIN SELECT RAISE(ABORT, 'card_of_another_account'); END;

-- 4. Planning ----------------------------------------------------------------------------------
-- A scheduled payment may belong to an event: its due dates up to the event's end are part of
-- that event's budget. An event deleted lets its payments go.
ALTER TABLE scheduled_payments ADD COLUMN event_id TEXT
  REFERENCES events(id) ON DELETE SET NULL;
CREATE INDEX idx_scheduled_payments_event ON scheduled_payments(event_id)
  WHERE event_id IS NOT NULL;

-- The month a goal's monthly plan counts from; NULL: from the month of its first contribution.
-- The update gives every goal that already has a plan the month of the update: money put in
-- before the plan was known is not counted as paid ahead of it.
ALTER TABLE goals ADD COLUMN plan_start_month TEXT
  CHECK (plan_start_month IS NULL
         OR plan_start_month GLOB '[0-9][0-9][0-9][0-9]-[01][0-9]');

-- The account an expected income is to come to; NULL: the account of the latest income received
-- for it, else the main account. An account deleted leaves it to that rule.
ALTER TABLE expected_income ADD COLUMN payment_method_id TEXT
  REFERENCES payment_methods(id) ON DELETE SET NULL;

-- 5. Debts -------------------------------------------------------------------------------------
-- The instant a debt was deleted; NULL: it is not. A deleted debt leaves every list, reminder and
-- figure of the debts, while the operations that point at it count as they did and the money of
-- its journal stays in the balances.
ALTER TABLE debts ADD COLUMN deleted_at TEXT;

-- 6. Reconciliations ---------------------------------------------------------------------------
-- The first count of an (account, currency) is its starting point: the balance is what was
-- counted, and the count is neither income nor spending, so it has no expected balance and
-- nothing to record. Only a later count has a difference, and it follows the books.
-- `records_difference`: 1 — the count keeps one operation equal to its difference, none at zero;
-- 0 — only the numbers follow, no operation is written; NULL — a starting point, a starting
-- balance given outside the sheet, or a count of one total.
ALTER TABLE reconciliation_balances ADD COLUMN records_difference INTEGER
  CHECK (records_difference IS NULL
         OR (records_difference IN (0, 1) AND expected_e4 IS NOT NULL));

-- Where starting balances given outside the sheet came from: the setup of the accounts, the
-- balance of a new account, a merge of two accounts. For the words of the history only; nothing
-- is computed from it. NULL: a sheet, a total, or starting balances written before this column.
ALTER TABLE reconciliations ADD COLUMN origin TEXT
  CHECK (origin IS NULL OR (kind = 'opening' AND origin IN ('setup', 'account', 'merge')));
