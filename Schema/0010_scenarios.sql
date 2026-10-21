-- «What if»: saved scenarios and the order of the goals. Forward only.
--
-- Additive only, like 0004 to 0009: one new table that starts empty and one column that starts
-- with the value every goal reads as today. There is no data step and no row is inserted or
-- updated: every goal, debt, account and operation the update finds keeps reading exactly as it
-- did, and the goals keep their order (by name) until the owner drags one.
--
-- Needs SQLite 3.37 or later, as 0004 to 0009 do.

-- 1. Scenarios -----------------------------------------------------------------------------------
-- A scenario the owner saved: a name, the place in the list, the changes it makes to the plan
-- (`spec_json`, canonical JSON the planning writes and reads; the database keeps it as text) and
-- the numbers it was last worked out against (`baseline_json`, '' until it is). Instants are UTC
-- text `YYYY-MM-DD HH:MM:SS.SSS`. A scenario deleted is kept with `deleted_at` set, so ⌘Z brings
-- it back whole. No foreign keys — a scenario names accounts, goals and debts inside its JSON, and
-- one of them gone does not remove the scenario — and no unique name: any number of scenarios
-- may share one.
CREATE TABLE scenarios (
  id             TEXT PRIMARY KEY,
  name           TEXT NOT NULL,
  sort           INTEGER NOT NULL DEFAULT 0,
  spec_json      TEXT NOT NULL,
  baseline_json  TEXT NOT NULL DEFAULT '',
  created_at     TEXT NOT NULL,
  updated_at     TEXT NOT NULL,
  deleted_at     TEXT
);
CREATE INDEX idx_scenarios_live ON scenarios(deleted_at, sort);

-- 2. Goals: the owner's order --------------------------------------------------------------------
-- The place the owner dragged a goal to; 0 everywhere means alphabetical, as before. No CHECK:
-- adding a column with one checks every other CHECK of the table again.
ALTER TABLE goals ADD COLUMN sort INTEGER NOT NULL DEFAULT 0;
