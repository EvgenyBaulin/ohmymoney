-- Tax deductions: what part of the owner's spending, which loan and which account a personal
-- income tax deduction may be claimed for. Forward only.
--
-- Additive only, like 0004 to 0028: three columns that start empty and no data step. No row is
-- inserted or updated, so every operation, debt and account the update finds reads exactly as it
-- did, and the yearly report of deductions starts empty until the owner marks something. No CHECK
-- on an added column: adding one checks every other CHECK of the table again, and the old rows
-- leave the columns empty anyway; which values are known is the rule of the app
-- (`TaxDeductionKind`) and of the check of the database, so a later build may add a kind.
--
-- The sync triggers of `transaction_parts`, `debts` and `payment_methods` already write the key
-- of a changed row to the outbox, whatever column changed, so the new columns travel with the row
-- and need no trigger of their own.
--
-- Needs SQLite 3.37 or later, as 0004 to 0028 do.

-- 1. A part of an operation ----------------------------------------------------------------------
-- `tax_deduction`: the kind of social or investment deduction the money of this part counts
-- towards: `medical` (treatment and medicines), `medical_expensive` (expensive treatment, no
-- limit), `education` (the owner's own), `education_child` (a child's; `for_person_id` names the
-- child when given), `sport`, `iis` (a contribution to an individual investment account written
-- as an operation). On a part, not on the operation: one receipt of a pharmacy mixes medicines
-- with other goods. NULL: the part counts towards no deduction.
ALTER TABLE transaction_parts ADD COLUMN tax_deduction TEXT;

-- 2. A debt ---------------------------------------------------------------------------------------
-- `tax_deduction`: `mortgage_interest` — the interest paid on this loan in a year counts towards
-- the deduction for the interest of a mortgage. A mortgage is a loan with a schedule, not a kind
-- of debt, so only the owner can say which loan it is. NULL: none.
ALTER TABLE debts ADD COLUMN tax_deduction TEXT;

-- 3. An account -----------------------------------------------------------------------------------
-- `tax_deduction`: `iis` — the account is an individual investment account, and the money moved
-- into it from the owner's other accounts in a year counts as a contribution: a transfer has no
-- parts to carry the mark. NULL: none.
ALTER TABLE payment_methods ADD COLUMN tax_deduction TEXT;
