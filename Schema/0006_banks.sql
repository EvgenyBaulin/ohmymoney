-- Banks above the accounts: «bank → account → card». Forward only.
--
-- Additive only, like 0004 and 0005: this file creates a table and adds columns that start
-- empty or with the value a new account starts with. It changes no value an older build wrote,
-- but for the cashback rules, which belong to the account now: the data step moves the rules
-- the cards held up to their account, as the same rows, or drops them (section 3). What needs
-- the app — a bank for every account, and the account filed under it — is the data step that
-- runs right after this file inside the same transaction (`MigrationDataSteps` in AppDatabase,
-- rules in `BanksMigration` and `CashbackRulesMigration` in the core): all of it lands, or the
-- file stays exactly as it was.
--
-- Needs SQLite 3.37 or later, as 0004 and 0005 do. Instants are UTC text, as GRDB writes them.

-- 1. Banks -------------------------------------------------------------------------------------
-- A bank owns no money: the balances, the operations and the counts stay on its accounts, as the
-- cards stay on theirs. It is what the owner names first, and what a list of choices says while
-- the bank has one account and one card. `name` is unique among the live banks — kept by the app,
-- as the names of accounts and cards are, since the archive keeps names the way every list does.
-- `sort` is the place in the lists, ahead of the name (0 everywhere is alphabetical).
CREATE TABLE banks (
  id        TEXT PRIMARY KEY,
  name      TEXT NOT NULL CHECK (length(trim(name)) > 0),
  sort      INTEGER NOT NULL DEFAULT 0,
  archived  INTEGER NOT NULL DEFAULT 0 CHECK (archived IN (0, 1))
);

-- 2. The bank of an account --------------------------------------------------------------------
-- Every account the app or the update makes has one. NULL is an account a hand edit or another
-- program left without: it is read as a bank of its own name, and the app files it on the next
-- open. RESTRICT: a bank with an account under it — archived or not — is never deleted; an
-- account deleted leaves its bank where it was.
ALTER TABLE payment_methods ADD COLUMN bank_id TEXT
  REFERENCES banks(id) ON DELETE RESTRICT;
CREATE INDEX idx_payment_methods_bank ON payment_methods(bank_id)
  WHERE bank_id IS NOT NULL;

-- 3. The cashback of an account ----------------------------------------------------------------
-- The rules of the bank belong to the account, and its cards follow them (`cashback_rules`
-- already holds a rule of an account as a row with no `card_id`): the data step moves the rules
-- the cards held up to their account where every card would repeat them, and drops what a
-- payment on a debt can no longer earn. The settings below are the account's too.
--
-- How the bank rounds the cashback of one purchase: to whole units or to the cent, to the
-- nearest, down or up. A new account, and every account the update finds, starts with whole
-- units and the nearest.
ALTER TABLE payment_methods ADD COLUMN cashback_precision TEXT NOT NULL DEFAULT 'whole'
  CHECK (cashback_precision IN ('whole', 'cents'));
ALTER TABLE payment_methods ADD COLUMN cashback_direction TEXT NOT NULL DEFAULT 'nearest'
  CHECK (cashback_direction IN ('nearest', 'down', 'up'));
-- When the bank pays: NULL — not said —, 'immediately' with the purchase, or 'later' by a day of
-- the next month (`cashback_payout_day`, 1…31, where 31 is the end of any month). The day goes
-- with 'later' and with nothing else.
ALTER TABLE payment_methods ADD COLUMN cashback_payout TEXT
  CHECK (cashback_payout IS NULL OR cashback_payout IN ('immediately', 'later'));
ALTER TABLE payment_methods ADD COLUMN cashback_payout_day INTEGER
  CHECK ((cashback_payout_day IS NULL) = (cashback_payout IS NOT 'later')
         AND (cashback_payout_day IS NULL OR cashback_payout_day BETWEEN 1 AND 31));
-- The account the cashback comes to as points when the bank pays it so; NULL — as money, to the
-- account itself. Points are kept as the currency of that account, one to one. RESTRICT: an
-- account that is another's points account is not deleted.
ALTER TABLE payment_methods ADD COLUMN cashback_points_account_id TEXT
  REFERENCES payment_methods(id) ON DELETE RESTRICT
  CHECK (cashback_points_account_id IS NULL OR cashback_points_account_id <> id);
CREATE INDEX idx_payment_methods_points ON payment_methods(cashback_points_account_id)
  WHERE cashback_points_account_id IS NOT NULL;

-- 4. A payment that closes its term ------------------------------------------------------------
-- «В этом месяце больше платежей не будет»: on the line of a payment, the due the payment was
-- made for is closed although the payment is smaller than the monthly one. The dues of a debt are
-- paid by money (`DebtDues`); this is the owner's word that no more money comes toward this one.
-- Only a payment carries it, and the lines of 1.2 do not: they closed their dues by counting.
ALTER TABLE debt_entries ADD COLUMN closes_term INTEGER NOT NULL DEFAULT 0
  CHECK (closes_term IN (0, 1));
