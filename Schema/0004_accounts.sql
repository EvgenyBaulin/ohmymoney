-- Accounts with several currencies, account groups, transfers, reconciliation by
-- (account, currency), refunds tied to the purchase part they take back, goals in a currency,
-- cash lines of the debt journal on an account, an archive for templates. Forward only.
--
-- Additive only: this file creates tables, adds columns and indexes, and fills new columns
-- through their defaults. It changes no value an older build wrote. What needs the app — the
-- one main account and an account for operations that have none — is the data step that runs
-- right after this file inside the same transaction
-- (`MigrationDataSteps` in AppDatabase, rules in `AccountsMigration` in the core): all of it
-- lands, or the file stays exactly as it was.
--
-- An account IS a payment method: the table and every `payment_method_id` keep their names.
-- Needs SQLite 3.37 or later: the CHECK of an added column is tested against existing rows.
-- Amounts stay INTEGER in 1/10000 (`*_e4`); currencies are upper-case ISO 4217 codes.

-- 1. Groups of accounts -------------------------------------------------------------------
-- `in_summary` = 0: the money of the group's accounts stays out of «Всего», the free sum and
-- the planning figures and is shown apart; their income and spending still count everywhere.
CREATE TABLE account_groups (
  id          TEXT PRIMARY KEY,
  name        TEXT NOT NULL CHECK (length(trim(name)) > 0),
  in_summary  INTEGER NOT NULL DEFAULT 1 CHECK (in_summary IN (0, 1)),
  -- The order the owner dragged; equal values fall back to the name.
  sort        INTEGER NOT NULL DEFAULT 0,
  archived    INTEGER NOT NULL DEFAULT 0 CHECK (archived IN (0, 1))
);

-- 2. Accounts -------------------------------------------------------------------------------
-- `currency` is the account's main currency; `other_currencies` the rest in the owner's
-- order, codes joined by commas ('USD,RUB,KZT'), '' for none. A balance is kept per
-- (account, currency). `is_default` marks the main account: exactly one live row has it,
-- kept by the app rather than by an index, since a 1.0.0 file may hold two for a moment.
-- `sort` 0 everywhere is alphabetical; a drag numbers the accounts 1…n.
ALTER TABLE payment_methods ADD COLUMN group_id TEXT
  REFERENCES account_groups(id) ON DELETE SET NULL;
ALTER TABLE payment_methods ADD COLUMN sort INTEGER NOT NULL DEFAULT 0;
ALTER TABLE payment_methods ADD COLUMN other_currencies TEXT NOT NULL DEFAULT ''
  CHECK (other_currencies NOT GLOB '*[^A-Z,]*');
CREATE INDEX idx_payment_methods_group ON payment_methods(group_id)
  WHERE group_id IS NOT NULL;

-- 3. «Списано со счёта» / «Зачислено на счёт» -------------------------------------------------
-- An operation in a currency its account does not hold moved the account's main currency by
-- this amount, as the bank showed it. Both NULL: the account holds the operation's currency
-- and moved by `amount_e4` itself. Never a leg in the operation's own currency.
ALTER TABLE transactions ADD COLUMN account_currency TEXT
  CHECK (account_currency IS NULL
         OR (length(account_currency) = 3 AND account_currency NOT GLOB '*[^A-Z]*'
             AND account_currency <> currency));
ALTER TABLE transactions ADD COLUMN account_amount_e4 INTEGER
  CHECK ((account_amount_e4 IS NULL) = (account_currency IS NULL)
         AND (account_amount_e4 IS NULL OR account_amount_e4 > 0));
CREATE INDEX idx_transactions_account ON transactions(payment_method_id, occurred_at);

-- 4. A refund taken back from one part of one purchase -------------------------------------
-- It counts in the purchase's day and month and moves money at its own moment. RESTRICT: a
-- part with a refund cannot disappear from under it, not even by the cascade of a purge.
ALTER TABLE transaction_parts ADD COLUMN refund_of_part_id TEXT
  REFERENCES transaction_parts(id) ON DELETE RESTRICT
  CHECK (refund_of_part_id IS NULL OR refund_of_part_id <> id);
CREATE INDEX idx_parts_refund_of ON transaction_parts(refund_of_part_id)
  WHERE refund_of_part_id IS NOT NULL;

-- Deleting money back finds the parts it covered by it.
CREATE INDEX idx_reimbursement_links_tx ON reimbursement_links(reimbursement_tx_id);

-- 5. Transfers between (account, currency) pairs ------------------------------------------
-- Never income, never spending. An exchange inside one account is a transfer between two of
-- its currencies. The fee is an ordinary expense that points back here by `external_id`
-- 'transfer:<id>:fee'. One currency on both ends moves one amount; a bank's cut is the fee.
CREATE TABLE transfers (
  id                      TEXT PRIMARY KEY,
  occurred_at             TEXT NOT NULL,
  from_payment_method_id  TEXT NOT NULL REFERENCES payment_methods(id) ON DELETE RESTRICT,
  from_currency           TEXT NOT NULL
                          CHECK (length(from_currency) = 3 AND from_currency NOT GLOB '*[^A-Z]*'),
  from_amount_e4          INTEGER NOT NULL CHECK (from_amount_e4 > 0),
  to_payment_method_id    TEXT NOT NULL REFERENCES payment_methods(id) ON DELETE RESTRICT,
  to_currency             TEXT NOT NULL
                          CHECK (length(to_currency) = 3 AND to_currency NOT GLOB '*[^A-Z]*'),
  to_amount_e4            INTEGER NOT NULL CHECK (to_amount_e4 > 0),
  note                    TEXT,
  created_at              TEXT NOT NULL,
  updated_at              TEXT NOT NULL,
  CHECK (from_payment_method_id <> to_payment_method_id OR from_currency <> to_currency),
  CHECK (from_currency <> to_currency OR from_amount_e4 = to_amount_e4)
);
CREATE INDEX idx_transfers_occurred ON transfers(occurred_at);
CREATE INDEX idx_transfers_from ON transfers(from_payment_method_id, occurred_at);
CREATE INDEX idx_transfers_to ON transfers(to_payment_method_id, occurred_at);

-- 6. Reconciliation by (account, currency) --------------------------------------------------
-- 'total': a 1.0.0 reconciliation of one total in rubles, kept as history; it anchors no
-- balance. 'accounts': the sheet of every account and currency. 'opening': starting balances
-- given outside the sheet (account setup, a new account, a merge). The last two need their
-- moment.
ALTER TABLE reconciliations ADD COLUMN kind TEXT NOT NULL DEFAULT 'total'
  CHECK (kind IN ('total', 'accounts', 'opening')
         AND (kind = 'total' OR reconciled_at IS NOT NULL));

-- One counted balance of one (account, currency) at the moment of its reconciliation, in that
-- currency. `expected_e4` and `difference_e4` are NULL on the first count of the pair, the
-- starting point. The operation that wrote the difference points back by `external_id`
-- 'reconcile:<reconciliation>:<this row>'.
CREATE TABLE reconciliation_balances (
  id                 TEXT PRIMARY KEY,
  reconciliation_id  TEXT NOT NULL REFERENCES reconciliations(id) ON DELETE CASCADE,
  payment_method_id  TEXT NOT NULL REFERENCES payment_methods(id) ON DELETE CASCADE,
  currency           TEXT NOT NULL CHECK (length(currency) = 3 AND currency NOT GLOB '*[^A-Z]*'),
  actual_e4          INTEGER NOT NULL,
  expected_e4        INTEGER,
  difference_e4      INTEGER,
  transaction_id     TEXT UNIQUE REFERENCES transactions(id) ON DELETE SET NULL,
  UNIQUE (reconciliation_id, payment_method_id, currency),
  CHECK ((expected_e4 IS NULL) = (difference_e4 IS NULL)),
  CHECK (difference_e4 IS NULL OR difference_e4 = actual_e4 - expected_e4),
  CHECK (transaction_id IS NULL OR (difference_e4 IS NOT NULL AND difference_e4 <> 0))
);
CREATE INDEX idx_reconciliation_balances_pair
  ON reconciliation_balances(payment_method_id, currency);

-- 7. Goals have a currency; target, plan and progress are in it. 1.0.0 goals were in rubles.
ALTER TABLE goals ADD COLUMN currency TEXT NOT NULL DEFAULT 'RUB'
  CHECK (length(currency) = 3 AND currency NOT GLOB '*[^A-Z]*');

-- 8. Money borrowed or lent through the debt journal alone (a `borrowed` line without an
-- operation): the account it went into or out of, the moment, and — when the account does not
-- hold the debt's currency — what moved on the account. NULL account: the main account.
ALTER TABLE debt_entries ADD COLUMN payment_method_id TEXT
  REFERENCES payment_methods(id) ON DELETE SET NULL;
ALTER TABLE debt_entries ADD COLUMN occurred_at TEXT;
ALTER TABLE debt_entries ADD COLUMN account_currency TEXT
  CHECK (account_currency IS NULL
         OR (length(account_currency) = 3 AND account_currency NOT GLOB '*[^A-Z]*'));
ALTER TABLE debt_entries ADD COLUMN account_amount_e4 INTEGER
  CHECK ((account_amount_e4 IS NULL) = (account_currency IS NULL)
         AND (account_amount_e4 IS NULL OR account_amount_e4 > 0));
CREATE INDEX idx_debt_entries_account ON debt_entries(payment_method_id)
  WHERE payment_method_id IS NOT NULL;

-- 9. Templates get the archive every other list has («Вернуть»).
ALTER TABLE templates ADD COLUMN archived INTEGER NOT NULL DEFAULT 0
  CHECK (archived IN (0, 1));
