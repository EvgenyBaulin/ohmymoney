-- Planning and reconciliation. Forward only.
--
-- No new tables: the table list of the schema and the 18 files of the export stay exactly as
-- the specification lists them. An operation made by «Mark as paid» or by a reconciliation
-- points back at what made it through `transactions.external_id`
-- (`sched:<payment>:<due date>`, `reconcile:<reconciliation>`), the way the surplus and the
-- shortfall of a reimbursement already do; the partial unique index on `external_id` makes a
-- due date impossible to pay twice.

-- Rollover of a limit counts from the month the limit started; before it there is nothing
-- to carry. NULL: a limit made before this migration, which carries nothing.
ALTER TABLE budgets ADD COLUMN start_month TEXT;
-- One limit per category, per «for whom» value, and one bad-spending limit.
CREATE UNIQUE INDEX idx_budgets_target
  ON budgets(scope, COALESCE(category_id, ''), COALESCE(for_whom, ''));

-- The window between two reconciliations is an instant, not a day: coffee bought after a
-- morning reconciliation belongs to the next one.
ALTER TABLE reconciliations ADD COLUMN reconciled_at TEXT;
-- The optional breakdown by currency, JSON:
-- [{"currency":"USD","amount_e4":…,"rub_per_unit":"…","rub_e4":…}], or NULL.
ALTER TABLE reconciliations ADD COLUMN breakdown TEXT;
CREATE INDEX idx_reconciliations_date ON reconciliations(date);

CREATE UNIQUE INDEX idx_expected_income_links_pair
  ON expected_income_links(expected_income_id, transaction_id);
CREATE INDEX idx_expected_income_links_tx ON expected_income_links(transaction_id);

-- Undo and deletion find the journal lines of an operation by it.
CREATE INDEX idx_debt_entries_transaction
  ON debt_entries(transaction_id) WHERE transaction_id IS NOT NULL;
