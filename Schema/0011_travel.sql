-- Travel: the time zone an operation was recorded in, the currencies of a trip and the foreign
-- terms of a card. Forward only.
--
-- Additive only, like 0004 to 0010: new columns that start empty and no data step. No row is
-- inserted or updated, so every operation, event and card the update finds reads exactly as it
-- did: an operation without a zone reads as recorded in Moscow, an event without a trip currency
-- or a budget currency reads as before, a card without foreign terms is left out of the
-- comparison of cards abroad. No CHECK on any column: adding a column with one checks every
-- other CHECK of the table again.
--
-- The trip mode itself is the setting `trip.activeEventId` of the `settings` table, which needs
-- no column.
--
-- Needs SQLite 3.37 or later, as 0004 to 0010 do.

-- 1. Operations: the zone they were recorded in ---------------------------------------------------
-- The identifier of the time zone the Mac was in when the operation was recorded
-- (`Asia/Makassar`). NULL — Moscow, the zone every operation of the earlier versions was
-- recorded in. The instant stays UTC; the day and the time of day an operation is shown on are
-- read in this zone, so a dinner at 21:00 in Bali stays on its day after the Mac comes home.
ALTER TABLE transactions ADD COLUMN time_zone TEXT;

-- 2. Events: the currencies of a trip -------------------------------------------------------------
-- `trip_currency`: the one currency of a trip (three capital Latin letters); NULL — none.
-- `budget_currency`: the currency `budget_e4` is kept in; NULL — the default currency of the
-- moment the update ran, read at the time (the planning reads it so, nothing is rewritten here).
ALTER TABLE events ADD COLUMN trip_currency TEXT;
ALTER TABLE events ADD COLUMN budget_currency TEXT;

-- 3. Cards: what the card costs abroad ------------------------------------------------------------
-- `fx_fee_e4`: the fee of the bank for converting a purchase, in 1/10000 of a percent (1.5 % is
-- 15 000). `atm_fee_percent_e4`: the percent of a cash withdrawal abroad, same unit.
-- `atm_fee_fixed_e4` and `atm_fee_fixed_currency`: the fixed part of it, in that currency. All
-- NULL — the owner has not typed the terms; the card is left out of the comparison abroad.
ALTER TABLE cards ADD COLUMN fx_fee_e4 INTEGER;
ALTER TABLE cards ADD COLUMN atm_fee_percent_e4 INTEGER;
ALTER TABLE cards ADD COLUMN atm_fee_fixed_e4 INTEGER;
ALTER TABLE cards ADD COLUMN atm_fee_fixed_currency TEXT;
