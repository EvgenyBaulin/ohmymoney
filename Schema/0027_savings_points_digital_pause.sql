-- Savings accounts that change their rate, points that burn, the digital ruble, bank subscriptions
-- that pay back and credit holidays. Forward only.
--
-- Additive only, like 0004 to 0026: new columns that start empty and no data step. No row is
-- inserted or updated, so every account, subscription and debt the update finds reads exactly as
-- it did: interest on the daily balance at one rate, points that never burn, an ordinary account,
-- a subscription without a stated benefit and a debt that is paid every month. No CHECK on an
-- added column: adding one checks every other CHECK of the table again, and the old rows leave
-- the column empty anyway; what a value may be is the rule of the app (`AccountRules`,
-- `DepositTerms`, `DebtPause`) and of the check of the database.
--
-- The `kind` of `payment_methods` keeps its CHECK (`card`, `cash`, `account`, `other`): the digital
-- ruble is an account like any other, marked by `digital_ruble`. A new kind would need the table
-- rebuilt, and a dozen tables point at it (0022 did the same for someone else's card).
--
-- The sync triggers of `payment_methods`, `subscription_terms` and `debts` already write the key
-- of a changed row to the outbox, so the new columns travel with the row and need no trigger of
-- their own.
--
-- Needs SQLite 3.37 or later, as 0004 to 0026 do.

-- 1. Interest of a savings account -----------------------------------------------------------------
-- `interest_base`: what the bank counts the interest on, `daily` (the balance at the end of each
-- day, the way 0007 worked it) or `min_balance` (the lowest balance of the month); NULL reads as
-- `daily`.
ALTER TABLE payment_methods ADD COLUMN interest_base TEXT;
-- `interest_next_rate` and `interest_next_rate_on`: the rate the bank has announced (percent, a
-- decimal string like `interest_rate`) and the first day it holds; both NULL when none is
-- announced. From that day the interest is worked out at the new rate.
ALTER TABLE payment_methods ADD COLUMN interest_next_rate TEXT;
ALTER TABLE payment_methods ADD COLUMN interest_next_rate_on TEXT;

-- 2. Points that burn ------------------------------------------------------------------------------
-- On the account that holds the points (`cashback_points_account_id` of 0006 names it): the day
-- the nearest points burn and how many, in the currency of the account. The rate of a point to the
-- ruble is the rate of that currency (`rates`, 0015), so no column keeps it. NULL: nothing burns.
ALTER TABLE payment_methods ADD COLUMN points_burn_on TEXT;
ALTER TABLE payment_methods ADD COLUMN points_burn_e4 INTEGER;

-- 3. The digital ruble and the piggy bank ----------------------------------------------------------
-- `digital_ruble`: 1 for a wallet of the digital ruble (no interest, no cashback, rubles only);
-- NULL or 0: an ordinary account. `piggy`: 1 for an account the owner puts money aside to (a
-- piggy bank, round-ups), whether or not it earns interest; NULL or 0: an ordinary account.
ALTER TABLE payment_methods ADD COLUMN digital_ruble INTEGER;
ALTER TABLE payment_methods ADD COLUMN piggy INTEGER;

-- 4. A bank subscription that pays back ------------------------------------------------------------
-- `bank_benefit_e4`: what the owner says the subscription saves or earns in a month besides
-- cashback (free transfers, interest), in the currency of the payment; NULL: none stated.
-- `bank_cashback_share`: the part of the cashback the bank paid in a month that the subscription
-- gives, in percent as a decimal string («50» — half of it); NULL: none.
ALTER TABLE subscription_terms ADD COLUMN bank_benefit_e4 INTEGER;
ALTER TABLE subscription_terms ADD COLUMN bank_cashback_share TEXT;

-- 5. A pause of the payments of a debt -------------------------------------------------------------
-- A credit holiday or a restructuring: no due falls on a day from `pause_from` through `pause_to`
-- (`YYYY-MM-DD`), and every later due moves on by the months skipped, so the term is carried over.
-- `pause_kind`: `holiday` or `restructuring`, for the owner's own eyes. NULL: no pause.
ALTER TABLE debts ADD COLUMN pause_from TEXT;
ALTER TABLE debts ADD COLUMN pause_to TEXT;
ALTER TABLE debts ADD COLUMN pause_kind TEXT;
