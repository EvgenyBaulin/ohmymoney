-- The numbers of a cash receipt on an operation, and the English name of a category. Forward only.
--
-- Additive only, like 0004 to 0022: six new columns that start empty, one plain index, and no
-- data step. No row is inserted or updated, so every operation and every category the update
-- finds reads exactly as it did. No CHECK on an added column: adding one checks every other CHECK
-- of the table again, and the old rows leave these columns empty anyway.
--
-- The sync triggers of `transactions` and `categories` already write the key of a changed row to
-- the outbox, whatever column changed, so the new columns travel with the row and need no trigger
-- of their own.
--
-- Needs SQLite 3.37 or later, as 0004 to 0022 do.

-- The fiscal numbers a Russian cash receipt carries in its QR code: the fiscal drive (`fn`), the
-- number of the document on it (`i`, «ФД») and the fiscal sign (`fp`, «ФП»). Kept as decimal
-- digits without leading zeros — the printed receipt has them, the code does not — so that the
-- same receipt read twice is told by plain text equality. `fn` and `i` together are the key of
-- one receipt: an operation holding them is the receipt already recorded, and the same receipt
-- does not make a second one. `fp` is the check of that key. All NULL: no receipt was read for
-- the operation.
ALTER TABLE transactions ADD COLUMN receipt_fn TEXT;
ALTER TABLE transactions ADD COLUMN receipt_i TEXT;
ALTER TABLE transactions ADD COLUMN receipt_fp TEXT;
-- The kind of settlement of the receipt (`n`): 1 a sale, 2 a refund of a sale, 3 a payout,
-- 4 a refund of a payout; NULL: none read.
ALTER TABLE transactions ADD COLUMN receipt_n INTEGER;
-- Not unique: two devices that read the same receipt apart each write their operation, and the
-- exchange must still apply both; a deleted operation keeps its numbers too.
CREATE INDEX idx_transactions_receipt ON transactions(receipt_fn, receipt_i)
  WHERE receipt_fn IS NOT NULL;

-- The English name of a category, made by the device itself from the owner's name (on-device
-- language model or the system translator) for the language model and the exchange; never shown.
-- Each device writes its own outside the exchange journal; it travels with the owner's next edit
-- of the row.
-- `name_en_source` is the owner's name it was made from: when the two differ the category was
-- renamed since — by this device, an undo, another device or an import — and the English name is
-- made again. Both NULL: not translated yet.
ALTER TABLE categories ADD COLUMN name_en TEXT;
ALTER TABLE categories ADD COLUMN name_en_source TEXT;
