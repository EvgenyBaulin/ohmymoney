-- Privacy: the hidden account. Forward only.
--
-- Additive only, like 0004 to 0018: one new column that starts empty, and no data step. No row is
-- inserted or updated, so every account the update finds reads exactly as it did: not hidden. No
-- CHECK on an added column: adding one checks every other CHECK of the table again.
--
-- The settings the privacy features need no column: they are keys of the `settings` table, absent
-- until the owner changes them, and an absent key reads as its default: `privacy.autoHideOnCapture`
-- (`1`), `privacy.readOnly` (`0`), `privacy.journalDays` (`365`). The journal of openings is a file
-- on this Mac, not a table: it is not in the database, the archive or the CSV.
--
-- The sync triggers of `payment_methods` already write the key of a changed row to the outbox, so
-- the new column travels with the row and needs no trigger of its own.
--
-- Needs SQLite 3.37 or later, as 0004 to 0018 do.

-- `hidden`: the account is hidden -- its balance and its operations are left out of the screens
-- until the owner unlocks them, and its money is counted in the totals with a note that a part is
-- hidden. 0 or NULL: shown; 1: hidden.
ALTER TABLE payment_methods ADD COLUMN hidden INTEGER;
