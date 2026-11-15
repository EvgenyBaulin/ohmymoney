-- The capital before the books began: when and for how much an asset was bought, and when a loan
-- was taken out and for how much. Forward only.
--
-- Additive only, like 0004 to 0031: four columns that start empty and no data step. No row is
-- inserted or updated, so every asset and debt the update finds reads exactly as it did: its worth
-- starts at its first valuation and its balance at the first line of its journal. No CHECK on an
-- added column: adding one checks every other CHECK of the table again, and the old rows leave the
-- columns empty anyway; a day that does not read or a sum below zero reads as none in the app
-- (`Asset.purchase`, `Debt.opening`), so one damaged cell never stops the history from being read.
--
-- The sync triggers of `assets` and `debts` already write the key of a changed row to the outbox,
-- whatever column changed, so the new columns travel with the row and need no trigger of their
-- own.
--
-- Needs SQLite 3.37 or later, as 0004 to 0031 do.

-- 1. An asset ------------------------------------------------------------------------------------
-- `purchased_on`: the day the thing was bought (`YYYY-MM-DD`), often long before the books began.
-- `purchase_price_e4`: what it cost then, in the currency of the asset (`assets.currency`, the one
-- its valuations are in), so the price and the valuations sit on one line. Either may be left
-- empty: the owner may know one and not the other. NULL: not said.
ALTER TABLE assets ADD COLUMN purchased_on TEXT;
ALTER TABLE assets ADD COLUMN purchase_price_e4 INTEGER;

-- 2. A debt --------------------------------------------------------------------------------------
-- `opened_on`: the day the loan was taken out (`YYYY-MM-DD`), as the contract says — not the day
-- the debt was written into the app and not its first due (`first_due_on`). `original_amount_e4`:
-- what was borrowed then, in the currency of the debt; the balance the books began with is still
-- the first line of the journal, this sum does not move money. NULL: not said.
ALTER TABLE debts ADD COLUMN opened_on TEXT;
ALTER TABLE debts ADD COLUMN original_amount_e4 INTEGER;
