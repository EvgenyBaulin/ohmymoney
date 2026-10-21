-- Credit: instalment plans, payment steps, early repayment, the true cost of a loan, pledges, the
-- terms of a credit card, the main card of an account; income allocation and self-employment;
-- currencies outside the Bank of Russia list. Forward only.
--
-- Additive only, like 0004 to 0008: columns that start empty or with the value a new row starts
-- with, and five new tables. There is no data step and no row is inserted: every debt, account,
-- goal, category and transfer the update finds keeps reading exactly as it did. A debt the update
-- finds is marked not yet reviewed (`terms_reviewed` 0): the app asks the owner about the new
-- fields of each one and changes nothing until they answer.
--
-- Needs SQLite 3.37 or later, as 0004 to 0008 do.

-- 1. Debts --------------------------------------------------------------------------------------
-- Dues every N days from `first_due_on` (an instalment plan paid every two weeks) instead of on
-- `payment_day` of every month. The two go together.
ALTER TABLE debts ADD COLUMN step_days INTEGER
  CHECK (step_days IS NULL OR step_days BETWEEN 1 AND 366);
ALTER TABLE debts ADD COLUMN first_due_on TEXT
  CHECK ((first_due_on IS NULL) = (step_days IS NULL));
-- «Рассрочка»: something bought here and paid in this many parts. Only a purchase I owe for.
ALTER TABLE debts ADD COLUMN parts INTEGER
  CHECK (parts IS NULL OR (parts BETWEEN 2 AND 120 AND direction = 'i_owe' AND origin = 'purchase'));
-- What the plan costs above the price (interest, fee), all parts together; spent part by part.
ALTER TABLE debts ADD COLUMN markup_e4 INTEGER
  CHECK (markup_e4 IS NULL OR (markup_e4 > 0 AND parts IS NOT NULL));
-- The full cost of credit from the contract, % a year as a decimal string, to compare with ours.
ALTER TABLE debts ADD COLUMN psk TEXT
  CHECK (psk IS NULL OR (length(trim(psk)) > 0 AND direction = 'i_owe'));
-- Early repayment: 1 — the bank takes it on any day, 0 — only on a payment day.
ALTER TABLE debts ADD COLUMN prepay_any_day INTEGER NOT NULL DEFAULT 1
  CHECK (prepay_any_day IN (0, 1));
-- How many days before an early repayment the bank wants the application; NULL — one day.
ALTER TABLE debts ADD COLUMN prepay_notice_days INTEGER
  CHECK (prepay_notice_days IS NULL OR prepay_notice_days BETWEEN 0 AND 90);
-- An early repayment the owner plans: the day and the sum. The two go together.
ALTER TABLE debts ADD COLUMN planned_prepay_on TEXT
  CHECK (planned_prepay_on IS NULL OR direction = 'i_owe');
ALTER TABLE debts ADD COLUMN planned_prepay_e4 INTEGER
  CHECK ((planned_prepay_e4 IS NULL) = (planned_prepay_on IS NULL)
         AND (planned_prepay_e4 IS NULL OR planned_prepay_e4 > 0));
-- In the payoff ladder: 1 yes, 0 no, NULL — the standard rule (every debt I owe).
ALTER TABLE debts ADD COLUMN in_ladder INTEGER
  CHECK (in_ladder IS NULL OR (in_ladder IN (0, 1) AND direction = 'i_owe'));
-- A pledge or a deposit (a flat, a rental, bottles) owed back to me, and the day it is due back.
ALTER TABLE debts ADD COLUMN pledge INTEGER NOT NULL DEFAULT 0
  CHECK (pledge IN (0, 1) AND (pledge = 0 OR direction = 'owed_to_me'));
ALTER TABLE debts ADD COLUMN return_by TEXT
  CHECK (return_by IS NULL OR direction = 'owed_to_me');
-- 1: the owner has seen the fields of this version for the debt (or the debt was made by it).
ALTER TABLE debts ADD COLUMN terms_reviewed INTEGER NOT NULL DEFAULT 0
  CHECK (terms_reviewed IN (0, 1));

-- A payment above its due and what the owner chose: a shorter term, a smaller payment, or the
-- next dues paid ahead.
ALTER TABLE debt_entries ADD COLUMN prepay TEXT
  CHECK (prepay IS NULL OR (prepay IN ('term', 'payment', 'forward') AND kind = 'payment'));

-- What a due asks for, typed from the bank's app: from due `from_index` (0 the first) on, until the
-- next step. It wins over the sum worked out, until a later step of either kind.
CREATE TABLE debt_instalments (
  id          TEXT PRIMARY KEY,
  debt_id     TEXT NOT NULL REFERENCES debts(id) ON DELETE CASCADE,
  from_index  INTEGER NOT NULL CHECK (from_index >= 0),
  amount_e4   INTEGER NOT NULL CHECK (amount_e4 >= 0),
  UNIQUE (debt_id, from_index)
);

-- What else a loan costs: a fee for issuing it, insurance, anything else; once, every month or
-- every year from `day`. `in_loan`: held back from the money the bank gave (only once).
-- `transaction_id`: the expense written for a cost paid once.
CREATE TABLE debt_costs (
  id              TEXT PRIMARY KEY,
  debt_id         TEXT NOT NULL REFERENCES debts(id) ON DELETE CASCADE,
  kind            TEXT NOT NULL CHECK (kind IN ('fee', 'insurance', 'other')),
  name            TEXT,
  amount_e4       INTEGER NOT NULL CHECK (amount_e4 > 0),
  every           TEXT NOT NULL DEFAULT 'once' CHECK (every IN ('once', 'monthly', 'yearly')),
  day             TEXT NOT NULL,
  in_loan         INTEGER NOT NULL DEFAULT 0
                  CHECK (in_loan IN (0, 1) AND (in_loan = 0 OR every = 'once')),
  transaction_id  TEXT REFERENCES transactions(id) ON DELETE SET NULL,
  sort            INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX idx_debt_costs_debt ON debt_costs(debt_id);

-- 2. Accounts: a credit card, the main card -----------------------------------------------------
-- The terms of a credit card, in the main currency of the account. A limit makes it one; every
-- other term goes with a limit. The grace period: 'statement' — the statement of every month on
-- `credit_statement_day` is due in `credit_pay_days`; 'purchase' — `credit_grace_days` from the
-- first purchase not yet repaid.
ALTER TABLE payment_methods ADD COLUMN credit_limit_e4 INTEGER
  CHECK (credit_limit_e4 IS NULL OR credit_limit_e4 > 0);
ALTER TABLE payment_methods ADD COLUMN credit_grace TEXT
  CHECK ((credit_grace IS NULL) = (credit_limit_e4 IS NULL)
         AND (credit_grace IS NULL OR credit_grace IN ('statement', 'purchase')));
ALTER TABLE payment_methods ADD COLUMN credit_statement_day INTEGER
  CHECK ((credit_statement_day IS NULL) = (credit_grace IS NOT 'statement')
         AND (credit_statement_day IS NULL OR credit_statement_day BETWEEN 1 AND 31));
ALTER TABLE payment_methods ADD COLUMN credit_pay_days INTEGER
  CHECK ((credit_pay_days IS NULL) = (credit_grace IS NOT 'statement')
         AND (credit_pay_days IS NULL OR credit_pay_days BETWEEN 1 AND 60));
ALTER TABLE payment_methods ADD COLUMN credit_grace_days INTEGER
  CHECK ((credit_grace_days IS NULL) = (credit_grace IS NOT 'purchase')
         AND (credit_grace_days IS NULL OR credit_grace_days BETWEEN 1 AND 366));
-- Yearly rates in percent as decimal strings: purchases, and cash and transfers.
ALTER TABLE payment_methods ADD COLUMN credit_purchase_rate TEXT
  CHECK (credit_purchase_rate IS NULL
         OR (length(trim(credit_purchase_rate)) > 0 AND credit_limit_e4 IS NOT NULL));
ALTER TABLE payment_methods ADD COLUMN credit_cash_rate TEXT
  CHECK (credit_cash_rate IS NULL
         OR (length(trim(credit_cash_rate)) > 0 AND credit_limit_e4 IS NOT NULL));
-- The minimum payment: a percent of the debt, not below a floor.
ALTER TABLE payment_methods ADD COLUMN credit_min_percent TEXT
  CHECK (credit_min_percent IS NULL
         OR (length(trim(credit_min_percent)) > 0 AND credit_limit_e4 IS NOT NULL));
ALTER TABLE payment_methods ADD COLUMN credit_min_floor_e4 INTEGER
  CHECK (credit_min_floor_e4 IS NULL OR (credit_min_floor_e4 >= 0 AND credit_limit_e4 IS NOT NULL));
-- The fee for cash and transfers: a percent and a fixed sum on top.
ALTER TABLE payment_methods ADD COLUMN credit_cash_fee_percent TEXT
  CHECK (credit_cash_fee_percent IS NULL
         OR (length(trim(credit_cash_fee_percent)) > 0 AND credit_limit_e4 IS NOT NULL));
ALTER TABLE payment_methods ADD COLUMN credit_cash_fee_fixed_e4 INTEGER
  CHECK (credit_cash_fee_fixed_e4 IS NULL
         OR (credit_cash_fee_fixed_e4 >= 0 AND credit_limit_e4 IS NOT NULL));
-- 1: cash and transfers have no grace period — interest from the first day.
ALTER TABLE payment_methods ADD COLUMN credit_cash_no_grace INTEGER NOT NULL DEFAULT 0
  CHECK (credit_cash_no_grace IN (0, 1) AND (credit_cash_no_grace = 0 OR credit_limit_e4 IS NOT NULL));
-- The card a purchase on the account is made with unless it says otherwise. Always a card of this
-- account (the triggers below).
ALTER TABLE payment_methods ADD COLUMN main_card_id TEXT REFERENCES cards(id) ON DELETE SET NULL;

CREATE TRIGGER main_card_of_account_insert BEFORE INSERT ON payment_methods
  WHEN NEW.main_card_id IS NOT NULL
BEGIN
  SELECT RAISE(ABORT, 'main_card_of_account');
END;
CREATE TRIGGER main_card_of_account_update BEFORE UPDATE OF main_card_id ON payment_methods
  WHEN NEW.main_card_id IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM cards WHERE id = NEW.main_card_id AND payment_method_id = NEW.id)
BEGIN
  SELECT RAISE(ABORT, 'main_card_of_account');
END;
-- A card that moves to another account (a merge) stops being the main card of the first.
CREATE TRIGGER main_card_follows_card AFTER UPDATE OF payment_method_id ON cards
BEGIN
  UPDATE payment_methods SET main_card_id = NULL
   WHERE main_card_id = NEW.id AND id <> NEW.payment_method_id;
END;

-- 3. Goals: where their money lies --------------------------------------------------------------
-- The account the money of a goal is kept on, and whether a contribution from the allocation sheet
-- also moves the money there (remembered). RESTRICT: such an account is archived, not deleted.
ALTER TABLE goals ADD COLUMN account_id TEXT REFERENCES payment_methods(id) ON DELETE RESTRICT;
ALTER TABLE goals ADD COLUMN transfer_on_contribution INTEGER NOT NULL DEFAULT 0
  CHECK (transfer_on_contribution IN (0, 1)
         AND (transfer_on_contribution = 0 OR account_id IS NOT NULL));
CREATE INDEX idx_goals_account ON goals(account_id) WHERE account_id IS NOT NULL;

-- 4. Transfers: what wrote them ------------------------------------------------------------------
-- 'alloc:<income>:<uuid>' — a transfer the allocation of an income wrote.
ALTER TABLE transfers ADD COLUMN external_id TEXT;
CREATE UNIQUE INDEX idx_transfers_external ON transfers(external_id) WHERE external_id IS NOT NULL;

-- 5. Categories: the tax on an income -----------------------------------------------------------
-- The tax an income in this category owes, percent as a decimal string; NULL on a subcategory —
-- as its parent, on a category — none. `tax_npd`: the tax on professional income (НПД), with its
-- deduction, its 100-ruble rule and its due day.
ALTER TABLE categories ADD COLUMN tax_rate TEXT
  CHECK (tax_rate IS NULL OR (length(trim(tax_rate)) > 0 AND kind = 'income'));
ALTER TABLE categories ADD COLUMN tax_npd INTEGER NOT NULL DEFAULT 0
  CHECK (tax_npd IN (0, 1) AND (tax_npd = 0 OR tax_rate IS NOT NULL));

-- 6. Allocation rules ----------------------------------------------------------------------------
-- How the owner usually allocates an income: a percent of it (after the tax of self-employment) or
-- a fixed sum, into a goal, to an account, or to the safety cushion (to `payment_method_id`, or to
-- the cushion account the sheet asks for). One rule per goal, one for the cushion.
CREATE TABLE allocation_rules (
  id                 TEXT PRIMARY KEY,
  target             TEXT NOT NULL CHECK (target IN ('goal', 'account', 'cushion')),
  goal_id            TEXT REFERENCES goals(id) ON DELETE CASCADE,
  payment_method_id  TEXT REFERENCES payment_methods(id) ON DELETE CASCADE,
  mode               TEXT NOT NULL CHECK (mode IN ('percent', 'fixed')),
  percent            TEXT,
  amount_e4          INTEGER CHECK (amount_e4 IS NULL OR amount_e4 > 0),
  currency           TEXT
                     CHECK (currency IS NULL OR (length(currency) = 3 AND currency NOT GLOB '*[^A-Z]*')),
  sort               INTEGER NOT NULL DEFAULT 0,
  active             INTEGER NOT NULL DEFAULT 1 CHECK (active IN (0, 1)),
  CHECK ((goal_id IS NOT NULL) = (target = 'goal')),
  CHECK (target <> 'goal' OR payment_method_id IS NULL),
  CHECK (target <> 'account' OR payment_method_id IS NOT NULL),
  CHECK ((percent IS NOT NULL) = (mode = 'percent')),
  CHECK ((amount_e4 IS NOT NULL AND currency IS NOT NULL) = (mode = 'fixed'))
);
CREATE UNIQUE INDEX idx_allocation_rules_goal ON allocation_rules(goal_id) WHERE goal_id IS NOT NULL;
CREATE UNIQUE INDEX idx_allocation_rules_cushion ON allocation_rules(target) WHERE target = 'cushion';

-- 7. Currencies outside the Bank of Russia ------------------------------------------------------
-- Three capital Latin letters that are not an ISO 4217 code; rates are typed by hand and live in
-- `rates` with the source 'manual', one per day.
CREATE TABLE custom_currencies (
  code             TEXT PRIMARY KEY CHECK (length(code) = 3 AND code NOT GLOB '*[^A-Z]*'),
  name             TEXT NOT NULL CHECK (length(trim(name)) > 0),
  symbol           TEXT,
  fraction_digits  INTEGER NOT NULL DEFAULT 2 CHECK (fraction_digits BETWEEN 0 AND 4),
  archived         INTEGER NOT NULL DEFAULT 0 CHECK (archived IN (0, 1)),
  sort             INTEGER NOT NULL DEFAULT 0
);
