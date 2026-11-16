-- The zone a transfer and a count were recorded in, as an operation keeps its own since
-- 0011_travel. Forward only.
--
-- Additive only, like 0004 to 0032: two columns that start empty and no data step. No row is
-- inserted or updated, so every transfer and every count the update finds reads exactly as an
-- operation without a zone does: on its Moscow day. No CHECK on an added column: adding one
-- checks every other CHECK of the table again, and the old rows leave the columns empty anyway;
-- a name the system does not know reads as none in the app, so one damaged cell never moves a
-- day.
--
-- The sync triggers of `transfers` and `reconciliations` already write the key of a changed row
-- to the outbox, whatever column changed, so the new columns travel with the row and need no
-- trigger of their own.
--
-- Needs SQLite 3.37 or later, as 0004 to 0032 do.

-- 1. A transfer ----------------------------------------------------------------------------------
-- `time_zone`: the identifier of the zone the device was in when the transfer was written
-- (`Asia/Makassar`), so a night transfer on a trip stays on the day it was made after the device
-- comes home. Moscow is written as NULL, the zone every older transfer reads in. An edit that
-- keeps the moment keeps the zone; a moment moved is a new date of the device that moved it.
ALTER TABLE transfers ADD COLUMN time_zone TEXT;

-- 2. A count -------------------------------------------------------------------------------------
-- `time_zone`: the zone the device was in when the count was made, read the same way: the day of
-- `reconciled_at` in that zone is the day the count anchors the balances on. NULL: Moscow.
ALTER TABLE reconciliations ADD COLUMN time_zone TEXT;
