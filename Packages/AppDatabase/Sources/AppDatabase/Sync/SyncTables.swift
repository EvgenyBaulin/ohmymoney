import Foundation
import GRDB

/// The tables of the books that travel between devices, each with its primary key column.
///
/// Not followed, on purpose: `settings` (the settings of one device), `rates` (fetched again on
/// each device), `ml_models` and `category_feedback` (learned on each device) and the
/// bookkeeping of the exchange itself. A table is followed only if the triggers of
/// `Schema/0012_sync.sql` write for it; a test holds the two lists together.
public enum SyncTables {
  public static let followed: [String: String] = [
    "account_groups": "id", "allocation_rules": "id", "anomaly_dismissals": "id",
    "asset_valuations": "id", "assets": "id", "banks": "id", "budgets": "id", "cards": "id",
    "cashback_rules": "id", "categories": "id", "currencies": "code",
    "custom_currencies": "code", "debt_costs": "id", "debt_entries": "id",
    "debt_instalments": "id", "debts": "id", "events": "id", "expected_income": "id",
    "expected_income_links": "id", "goals": "id", "import_batches": "id",
    "import_mappings": "id", "payment_methods": "id", "people": "id", "places": "id",
    "reconciliation_balances": "id", "reconciliations": "id", "reimbursement_links": "id",
    "scenarios": "id", "scheduled_payments": "id", "subscription_prices": "id",
    "templates": "id", "transaction_parts": "id", "transactions": "id", "transfers": "id",
  ]

  /// The bookkeeping tables of the exchange: not part of the books, left out of every copy of
  /// them (the export, the transfer archive, the readable copy).
  public static let bookkeeping: [String] = [
    "sync_meta", "sync_outbox", "sync_heads", "sync_deferred", "sync_resolutions", "sync_state",
  ]
}
