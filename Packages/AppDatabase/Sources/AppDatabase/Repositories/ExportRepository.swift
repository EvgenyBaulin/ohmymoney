import AppCore
import CoreKit
import Foundation
import GRDB

/// Turns the database into the CSV files of the export and of the transfer archive.
/// Lives in the storage layer so nothing above it has to know about GRDB.
public struct ExportRepository: Sendable {
  public struct Table: Sendable {
    public let fileName: String
    public let data: Data

    public init(fileName: String, data: Data) {
      self.fileName = fileName
      self.data = data
    }

    /// The table name as the manifest and the schema spell it.
    public var name: String { String(fileName.dropLast(4)) }
  }

  private let writer: any DatabaseWriter

  public init(writer: any DatabaseWriter) {
    self.writer = writer
  }

  /// Every table of the export, in a stable order, each with all its rows. A table
  /// without rows is written with its header row, so the set is always complete.
  public func tables() throws -> [Table] {
    try writer.read(Self.tables)
  }

  public func rowCounts() throws -> [String: Int] {
    try writer.read(Self.rowCounts)
  }

  /// What the transfer archive carries of the database: a copy of it and its tables as CSV
  /// with their row counts.
  public struct Snapshot: Sendable {
    public let tables: [Table]
    public let rowCounts: [String: Int]
  }

  /// Copies the database to `destination` through the backup API and reads the tables and
  /// their row counts in the same read transaction, so the three describe one state of the
  /// database however much another connection writes meanwhile. Read one after another, they
  /// were three states: a rate stored in between failed the archive's own check of its counts,
  /// or left the CSV files describing another state than the database beside them.
  public func snapshot(to destination: URL) throws -> Snapshot {
    try FileManager.default.createDirectory(
      at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    // A log left beside an earlier file of that name would be read as the copy's own.
    for path in DatabaseStack.databaseFiles(of: destination)
    where FileManager.default.fileExists(atPath: path) {
      try FileManager.default.removeItem(atPath: path)
    }
    let target = try DatabaseQueue(path: destination.path)
    defer { try? target.close() }
    return try target.writeWithoutTransaction { copy in
      try writer.read { db in
        try db.backup(to: copy)
        return Snapshot(tables: try Self.tables(db), rowCounts: try Self.rowCounts(db))
      }
    }
  }

  private static func tables(_ db: Database) throws -> [Table] {
    try ExportTables.all.map { table in
      Table(fileName: table.fileName, data: try data(for: table, db: db))
    }
  }

  private static func rowCounts(_ db: Database) throws -> [String: Int] {
    var counts: [String: Int] = [:]
    for table in ExportTables.all {
      let name = String(table.fileName.dropLast(4))
      counts[name] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(name)") ?? 0
    }
    return counts
  }

  private static func data(for table: ExportTable, db: Database) throws -> Data {
    var csv = CSVWriter(columns: table.columns)
    switch table.fileName {
    case ExportTables.transactions.fileName:
      for row in try CoreKit.Transaction.fetchAll(db) { csv.append(ExportTables.row(row)) }
    case ExportTables.transactionParts.fileName:
      for row in try TransactionPart.fetchAll(db) { csv.append(ExportTables.row(row)) }
    case ExportTables.reimbursementLinks.fileName:
      for row in try ReimbursementLink.fetchAll(db) { csv.append(ExportTables.row(row)) }
    case ExportTables.people.fileName:
      for row in try Person.fetchAll(db) { csv.append(ExportTables.row(row)) }
    case ExportTables.paymentMethods.fileName:
      for row in try PaymentMethod.fetchAll(db) { csv.append(ExportTables.row(row)) }
    case ExportTables.places.fileName:
      for row in try Place.fetchAll(db) { csv.append(ExportTables.row(row)) }
    case ExportTables.events.fileName:
      for row in try Event.fetchAll(db) { csv.append(ExportTables.row(row)) }
    case ExportTables.categories.fileName:
      for row in try CoreKit.Category.fetchAll(db) { csv.append(ExportTables.row(row)) }
    case ExportTables.templates.fileName:
      for row in try Template.fetchAll(db) { csv.append(ExportTables.row(row)) }
    case ExportTables.goals.fileName:
      for row in try Goal.fetchAll(db) { csv.append(ExportTables.row(row)) }
    case ExportTables.debts.fileName:
      for row in try Debt.fetchAll(db) { csv.append(ExportTables.row(row)) }
    case ExportTables.debtEntries.fileName:
      for row in try DebtEntry.fetchAll(db) { csv.append(ExportTables.row(row)) }
    case ExportTables.rates.fileName:
      for row in try Rate.fetchAll(db) { csv.append(ExportTables.row(row)) }
    case ExportTables.scheduledPayments.fileName:
      for row in try ScheduledPayment.fetchAll(db) { csv.append(ExportTables.row(row)) }
    case ExportTables.subscriptionPrices.fileName:
      for row in try SubscriptionPrice.fetchAll(db) { csv.append(ExportTables.row(row)) }
    case ExportTables.expectedIncome.fileName:
      for row in try ExpectedIncome.fetchAll(db) { csv.append(ExportTables.row(row)) }
    case ExportTables.budgets.fileName:
      for row in try Budget.fetchAll(db) { csv.append(ExportTables.row(row)) }
    case ExportTables.reconciliations.fileName:
      for row in try Reconciliation.fetchAll(db) { csv.append(ExportTables.row(row)) }
    case ExportTables.accountGroups.fileName:
      for row in try AccountGroup.fetchAll(db) { csv.append(ExportTables.row(row)) }
    case ExportTables.transfers.fileName:
      for row in try Transfer.fetchAll(db) { csv.append(ExportTables.row(row)) }
    case ExportTables.reconciliationBalances.fileName:
      for row in try ReconciledBalance.fetchAll(db) { csv.append(ExportTables.row(row)) }
    case ExportTables.cards.fileName:
      for row in try PaymentCard.fetchAll(db) { csv.append(ExportTables.row(row)) }
    case ExportTables.cashbackRules.fileName:
      for row in try CashbackRule.fetchAll(db) { csv.append(ExportTables.row(row)) }
    case ExportTables.banks.fileName:
      for row in try Bank.fetchAll(db) { csv.append(ExportTables.row(row)) }
    case ExportTables.assets.fileName:
      for row in try Asset.fetchAll(db) { csv.append(ExportTables.row(row)) }
    case ExportTables.assetValuations.fileName:
      for row in try AssetValuation.fetchAll(db) { csv.append(ExportTables.row(row)) }
    case ExportTables.debtInstalments.fileName:
      for row in try DebtInstalmentStep.fetchAll(db) { csv.append(ExportTables.row(row)) }
    case ExportTables.debtCosts.fileName:
      for row in try DebtCost.fetchAll(db) { csv.append(ExportTables.row(row)) }
    case ExportTables.allocationRules.fileName:
      for row in try AllocationRule.fetchAll(db) { csv.append(ExportTables.row(row)) }
    case ExportTables.customCurrencies.fileName:
      for row in try CustomCurrency.fetchAll(db) { csv.append(ExportTables.row(row)) }
    case ExportTables.settings.fileName:
      // Sorted by key, so the same settings are always the same file.
      for row in try Row.fetchAll(db, sql: "SELECT key, value FROM settings ORDER BY key") {
        csv.append(ExportTables.settingRow(key: row["key"] ?? "", value: row["value"] ?? ""))
      }
    case ExportTables.tags.fileName:
      for row in try Tag.fetchAll(db, sql: "SELECT * FROM tags ORDER BY created_at, id") {
        csv.append(ExportTables.row(row))
      }
    case ExportTables.partTags.fileName:
      for row in try PartTag.fetchAll(db, sql: "SELECT * FROM part_tags ORDER BY id") {
        csv.append(ExportTables.row(row))
      }
    case ExportTables.rules.fileName:
      // The text of the database as it is: a rule a newer build wrote still goes out whole.
      for row in try Row.fetchAll(db, sql: "SELECT * FROM rules ORDER BY position, id") {
        csv.append(
          [
            row["id"] ?? "", row["name"] ?? "", String(row["position"] as Int? ?? 0),
            CSVValue.string(bool: (row["enabled"] as Int? ?? 1) != 0),
            row["origin"] ?? "manual", row["conditions"] ?? "[]", row["actions"] ?? "[]",
            CSVValue.string(instant: try RowMapping.instant(row, "created_at")),
            CSVValue.string(instant: try RowMapping.instant(row, "updated_at")),
          ])
      }
    case ExportTables.dayNotes.fileName:
      for row in try DayNote.fetchAll(db, sql: "SELECT * FROM day_notes ORDER BY day") {
        csv.append(ExportTables.row(row))
      }
    case ExportTables.budgetMonthExceptions.fileName:
      for row in try Row.fetchAll(
        db, sql: "SELECT * FROM budget_month_exceptions ORDER BY month, budget_id, id")
      {
        csv.append(Self.text(row, ["id", "budget_id", "month"]) + Self.amount(row, "amount_e4"))
      }
    case ExportTables.eventBudgetItems.fileName:
      for row in try Row.fetchAll(
        db, sql: "SELECT * FROM event_budget_items ORDER BY event_id, sort, id")
      {
        csv.append(
          Self.text(row, ["id", "event_id", "title"]) + Self.amount(row, "planned_e4")
            + [String(row["sort"] as Int? ?? 0)])
      }
    case ExportTables.eventTemplates.fileName:
      // The lines as the database has them: a template a newer build wrote still goes out whole.
      for row in try Row.fetchAll(db, sql: "SELECT * FROM event_templates ORDER BY name, id") {
        csv.append(
          Self.text(row, ["id", "name", "event_kind"]) + Self.amount(row, "total_e4")
            + [row["lines"] ?? "[]"] + [try Self.instant(row, "created_at")]
            + [try Self.instant(row, "updated_at")])
      }
    case ExportTables.subscriptionTerms.fileName:
      for row in try Row.fetchAll(db, sql: "SELECT * FROM subscription_terms ORDER BY payment_id") {
        csv.append(
          [row["payment_id"] ?? ""] + Self.amount(row, "yearly_plan_e4")
            + Self.amount(row, "monthly_plan_e4") + [Self.flag(row, "floating", false)]
            + [CSVValue.string(row["tolerance_percent"] as Int?)]
            + [CSVValue.string(row["service_type"] as String?)]
            + [Self.flag(row, "needed", false), Self.flag(row, "yearly_reminder_off", false)]
            + [Self.flag(row, "owner_uses", true)])
      }
    case ExportTables.subscriptionUsage.fileName:
      for row in try Row.fetchAll(db, sql: "SELECT * FROM subscription_usage ORDER BY day, id") {
        csv.append(Self.text(row, ["id", "payment_id", "day"]))
      }
    case ExportTables.subscriptionUsers.fileName:
      for row in try Row.fetchAll(db, sql: "SELECT * FROM subscription_users ORDER BY rowid") {
        csv.append(Self.text(row, ["id", "payment_id", "person_id"]))
      }
    case ExportTables.subscriptionKeepGroups.fileName:
      for row in try Row.fetchAll(
        db, sql: "SELECT * FROM subscription_keep_groups ORDER BY type, id")
      {
        csv.append(Self.text(row, ["id", "type"]) + [row["payment_ids"] ?? "[]"])
      }
    case ExportTables.bankConditions.fileName:
      for row in try BankConditions.fetchAll(db, sql: "SELECT * FROM bank_conditions ORDER BY id") {
        csv.append(ExportTables.row(row))
      }
    case ExportTables.depositOffers.fileName:
      for row in try Row.fetchAll(db, sql: "SELECT * FROM deposit_offers ORDER BY id") {
        // An offer this build can not read still goes out, in the text of the database.
        if let offer = try? DepositOffer(row: row) {
          csv.append(ExportTables.row(offer))
        } else {
          csv.append(
            Self.text(row, ["id", "bank_name", "rate_percent"])
              + [CSVValue.string(row["term_months"] as Int?)]
              + Self.amount(row, "min_amount_e4") + Self.amount(row, "max_amount_e4")
              + [
                Self.flag(row, "new_client_only", false),
                Self.flag(row, "needs_subscription", false),
                Self.flag(row, "topup", false),
              ] + Self.text(row, ["rate_on", "note"]) + [Self.flag(row, "archived", false)])
        }
      }
    default:
      // A table the list gains before its rows are mapped still gets its header row.
      break
    }
    return csv.data()
  }

  /// The text columns of a row, in the order given; NULL is an empty cell.
  private static func text(_ row: Row, _ columns: [String]) -> [String] {
    columns.map { CSVValue.string(row[$0] as String?) }
  }

  /// An amount column (`*_e4`) as a decimal string; NULL is an empty cell.
  private static func amount(_ row: Row, _ column: String) -> [String] {
    [CSVValue.string(amount: (row[column] as Int64?).map { AmountE4(raw: $0) })]
  }

  private static func flag(_ row: Row, _ column: String, _ fallback: Bool) -> String {
    CSVValue.string(bool: (row[column] as Int?).map { $0 != 0 } ?? fallback)
  }

  private static func instant(_ row: Row, _ column: String) throws -> String {
    CSVValue.string(instant: try RowMapping.instant(row, column))
  }
}
