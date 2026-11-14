-- Merchant codes in a bank's table of cashback categories. Forward only.
--
-- A row of «категория банка → ваша» (0021) may now name the merchant codes (MCC) the bank counts
-- in its label and the ones it leaves out, as the owner types them: «5411, 5811-5814». A purchase
-- that has a code (`transactions.mcc`, 0026) and meets a row with a list goes by the code; a
-- purchase without a code, or a row without lists, goes by the owner's category as before.
--
-- Additive only, like 0004 to 0027: two columns that start empty and no data step. No row is
-- inserted or updated, so every bank table the update finds reads exactly as it did and every
-- figure of cashback stays the same to the kopeck until the owner types a list. No CHECK on an
-- added column: adding one checks every other CHECK of the table again, and the old rows leave
-- the columns empty anyway; what a list may be is the rule of the app (`MerchantCodeList`) and of
-- the check of the database.
--
-- `include_mcc`: the codes the bank counts in the label, sorted and merged ranges separated by
-- «, » (`MerchantCodeList.text`), four digits each, «-» between the ends of a range; NULL — no
-- list. `exclude_mcc`: the codes the bank leaves out of the label, in the same form; they win over
-- `include_mcc`. A row with only `exclude_mcc` is the owner's category without those codes.
--
-- The sync triggers of `bank_cashback_categories` (0021) already write the key of a changed row
-- to the outbox, so the new columns travel with the row and need no trigger of their own.
--
-- Needs SQLite 3.37 or later, as 0004 to 0027 do.

ALTER TABLE bank_cashback_categories ADD COLUMN include_mcc TEXT;
ALTER TABLE bank_cashback_categories ADD COLUMN exclude_mcc TEXT;
