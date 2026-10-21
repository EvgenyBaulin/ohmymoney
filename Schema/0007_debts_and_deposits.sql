-- Loans with a grace period and tranches, and accounts that earn interest. Forward only.
--
-- Additive only, like 0004, 0005 and 0006: this file adds columns that start empty or with the
-- value a new row starts with, and changes no value an older build wrote. There is no data step:
-- every debt and every account the update finds keeps reading exactly as it did — no interest, no
-- grace, no tranche, no deposit. The interest is never stored: the app works it out from these
-- terms and the journal when it reads them.
--
-- Needs SQLite 3.37 or later, as 0004, 0005 and 0006 do.

-- 1. The terms of a loan -----------------------------------------------------------------------
-- The bank charges interest on what is owed day by day, and a payment pays that interest first.
-- Only a debt with a rate can say so.
ALTER TABLE debts ADD COLUMN accrues_interest INTEGER NOT NULL DEFAULT 0
  CHECK (accrues_interest IN (0, 1) AND (accrues_interest = 0 OR interest_rate IS NOT NULL));
-- A grace period: until `main_from` (a day, `YYYY-MM-DD`) the dues are the grace payment, from it
-- on the main one. Only a debt I owe that is paid on a day of the month has one.
ALTER TABLE debts ADD COLUMN main_from TEXT
  CHECK (main_from IS NULL OR (direction = 'i_owe' AND payment_day IS NOT NULL));
-- What a due of the grace period is: the interest on the money drawn so far ('interest'), the
-- share of it the state education-loan programme asks by year of the loan — 40 %, 60 %, then all
-- of it ('programme'; the rest is not forgiven, it joins the principal when the main schedule
-- starts) —, both of which need a rate, or a fixed sum ('fixed', `grace_payment_e4`). The kind
-- goes with `main_from` and nothing else.
ALTER TABLE debts ADD COLUMN grace_kind TEXT
  CHECK ((grace_kind IS NULL) = (main_from IS NULL)
         AND (grace_kind IS NULL OR grace_kind IN ('interest', 'programme', 'fixed'))
         AND (grace_kind NOT IN ('interest', 'programme') OR grace_kind IS NULL
              OR interest_rate IS NOT NULL));
ALTER TABLE debts ADD COLUMN grace_payment_e4 INTEGER
  CHECK ((grace_payment_e4 IS NOT NULL) = (grace_kind IS 'fixed')
         AND (grace_payment_e4 IS NULL OR grace_payment_e4 > 0));
-- The months the main payment is worked out over, when the owner did not type it: an annuity at
-- the rate of the debt.
ALTER TABLE debts ADD COLUMN repay_months INTEGER
  CHECK (repay_months IS NULL OR (repay_months BETWEEN 1 AND 600 AND interest_rate IS NOT NULL));

-- 2. A tranche ---------------------------------------------------------------------------------
-- A part of the loan drawn later — a term of tuition paid by the bank. Only money that grows the
-- debt is one, with a positive amount: a `borrowed` line, which names the expense «Образование»
-- of its day the way a purchase on credit names its purchase (`transaction_id`), or an
-- `adjustment` written without an operation.
ALTER TABLE debt_entries ADD COLUMN tranche INTEGER NOT NULL DEFAULT 0
  CHECK (tranche IN (0, 1) AND (tranche = 0 OR (kind IN ('borrowed', 'adjustment') AND amount_e4 > 0)));

-- 3. Interest on an account --------------------------------------------------------------------
-- A deposit or a savings account: the yearly rate in percent as a decimal string, how often the
-- bank pays it ('monthly', 'quarterly', or once at the 'end' of the term) and on what day of the
-- month (1…31, 31 is the end of any month; NULL — the day it was opened, else the last day). The
-- period and the day go with the rate and nothing else.
ALTER TABLE payment_methods ADD COLUMN interest_rate TEXT
  CHECK (interest_rate IS NULL OR length(trim(interest_rate)) > 0);
ALTER TABLE payment_methods ADD COLUMN interest_period TEXT
  CHECK ((interest_period IS NULL) = (interest_rate IS NULL)
         AND (interest_period IS NULL OR interest_period IN ('monthly', 'quarterly', 'end')));
ALTER TABLE payment_methods ADD COLUMN interest_day INTEGER
  CHECK (interest_day IS NULL
         OR (interest_day BETWEEN 1 AND 31 AND interest_period IS NOT NULL
             AND interest_period IN ('monthly', 'quarterly')));
-- The account the interest is paid to; NULL — to the account itself, where it earns interest in
-- turn. RESTRICT: an account another one pays its interest to is not deleted.
ALTER TABLE payment_methods ADD COLUMN interest_account_id TEXT
  REFERENCES payment_methods(id) ON DELETE RESTRICT
  CHECK (interest_account_id IS NULL OR (interest_account_id <> id AND interest_rate IS NOT NULL));
CREATE INDEX idx_payment_methods_interest_account ON payment_methods(interest_account_id)
  WHERE interest_account_id IS NOT NULL;
-- The term of a deposit: the day it was opened and the day it ends (`YYYY-MM-DD`). Without an
-- end it is a savings account; interest paid once at the end needs one.
ALTER TABLE payment_methods ADD COLUMN deposit_opened_on TEXT
  CHECK (deposit_opened_on IS NULL OR interest_rate IS NOT NULL);
ALTER TABLE payment_methods ADD COLUMN deposit_ends_on TEXT
  CHECK ((deposit_ends_on IS NULL OR (interest_rate IS NOT NULL
          AND (deposit_opened_on IS NULL OR deposit_ends_on > deposit_opened_on)))
         AND (interest_period IS NOT 'end' OR deposit_ends_on IS NOT NULL));
