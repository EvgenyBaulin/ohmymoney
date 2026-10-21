import Foundation
import GRDB

/// The weekly check of the live database and its safe repair.
///
/// The check reads and never writes. It asks SQLite (`integrity_check`, the foreign keys) and
/// the rules the app keeps on top of it: the parts of an operation add up to its amount, a
/// reconciliation of accounts has its balances, a transfer joins two accounts. It does not
/// recompute the differences of reconciliations — they are caught up at every calculation.
///
/// The repair touches only rows that hold nothing of the owner's alone — a part with no
/// operation, a link with no part — and deletes them in one write. Anything that has money in it
/// is reported and left.
public enum DatabaseCheck {
  public enum Rule: String, Sendable, CaseIterable, Hashable, Codable {
    /// `PRAGMA integrity_check` did not say «ok».
    case sqliteIntegrity
    /// A row points at a row that is not there.
    case foreignKeys
    /// The parts of an operation do not add up to its amount, or it has none.
    case partsSum
    /// A reconciliation of accounts or an opening with no balances.
    case reconciliationWithoutBalances
    /// A transfer from an account to itself in one currency.
    case transferToItself
  }

  public struct Finding: Sendable, Hashable, Codable {
    public var rule: Rule
    /// The table the rows are in, when the rule is about one.
    public var table: String?
    public var count: Int
    /// What the repair would delete is exactly these rows.
    public var isRepairable: Bool
    /// The first few ids of the rows, for the report of the owner's own eyes. They hold no
    /// names and no amounts.
    public var ids: [String]

    public init(rule: Rule, table: String?, count: Int, isRepairable: Bool, ids: [String]) {
      self.rule = rule
      self.table = table
      self.count = count
      self.isRepairable = isRepairable
      self.ids = ids
    }
  }

  public struct Report: Sendable, Equatable, Codable {
    public var operations: Int
    public var accounts: Int
    public var findings: [Finding]

    public init(operations: Int, accounts: Int, findings: [Finding]) {
      self.operations = operations
      self.accounts = accounts
      self.findings = findings
    }

    public var isHealthy: Bool { findings.isEmpty }
    /// How many rows are wrong in all.
    public var problemCount: Int { findings.reduce(0) { $0 + $1.count } }
    public var repairableCount: Int {
      findings.filter(\.isRepairable).reduce(0) { $0 + $1.count }
    }
    public var hasRepairs: Bool { repairableCount > 0 }
  }

  /// The tables whose orphan rows are only join rows or the pieces of an operation that is
  /// not there: nothing the owner can see, and so safe to delete.
  public static let repairableTables: [String] = [
    "transaction_parts", "reimbursement_links", "reconciliation_balances", "subscription_prices",
    "expected_income_links",
  ]

  private static let idsShown = 5

  /// Checks the database. Reads only.
  public static func run(_ writer: any DatabaseReader) throws -> Report {
    try writer.read { db in try run(db) }
  }

  public static func run(_ db: Database) throws -> Report {
    var findings: [Finding] = []

    let integrity = try String.fetchAll(db, sql: "PRAGMA integrity_check")
    if integrity != ["ok"] {
      findings.append(
        Finding(
          rule: .sqliteIntegrity, table: nil, count: max(1, integrity.count), isRepairable: false,
          ids: []))
    }

    var byTable: [String: [Int64]] = [:]
    for row in try Row.fetchAll(db, sql: "PRAGMA foreign_key_check") {
      guard let table: String = row["table"], let rowid: Int64 = row["rowid"] else { continue }
      byTable[table, default: []].append(rowid)
    }
    for table in byTable.keys.sorted() {
      let rowids = byTable[table] ?? []
      findings.append(
        Finding(
          rule: .foreignKeys, table: table, count: rowids.count,
          isRepairable: repairableTables.contains(table),
          ids: rowids.prefix(idsShown).map { String($0) }))
    }

    let sums = try Row.fetchAll(
      db,
      sql: """
        SELECT t.id AS id FROM transactions t
        LEFT JOIN (SELECT transaction_id, SUM(amount_e4) AS total, COUNT(*) AS parts
                   FROM transaction_parts GROUP BY transaction_id) p ON p.transaction_id = t.id
        WHERE t.deleted_at IS NULL AND (p.parts IS NULL OR p.total <> t.amount_e4)
        ORDER BY t.id
        """)
    if !sums.isEmpty {
      findings.append(
        Finding(
          rule: .partsSum, table: "transactions", count: sums.count, isRepairable: false,
          ids: sums.prefix(idsShown).map { $0["id"] }))
    }

    let bare = try Row.fetchAll(
      db,
      sql: """
        SELECT r.id AS id FROM reconciliations r
        WHERE r.kind IN ('accounts', 'opening')
          AND NOT EXISTS (SELECT 1 FROM reconciliation_balances b WHERE b.reconciliation_id = r.id)
        ORDER BY r.id
        """)
    if !bare.isEmpty {
      findings.append(
        Finding(
          rule: .reconciliationWithoutBalances, table: "reconciliations", count: bare.count,
          isRepairable: false, ids: bare.prefix(idsShown).map { $0["id"] }))
    }

    let selfTransfers = try Row.fetchAll(
      db,
      sql: """
        SELECT id FROM transfers
        WHERE from_payment_method_id = to_payment_method_id AND from_currency = to_currency
        ORDER BY id
        """)
    if !selfTransfers.isEmpty {
      findings.append(
        Finding(
          rule: .transferToItself, table: "transfers", count: selfTransfers.count,
          isRepairable: false, ids: selfTransfers.prefix(idsShown).map { $0["id"] }))
    }

    let operations =
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transactions WHERE deleted_at IS NULL") ?? 0
    let accounts =
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM payment_methods WHERE archived = 0") ?? 0
    return Report(operations: operations, accounts: accounts, findings: findings)
  }

  /// Deletes the rows of the repairable findings in one write, and returns how many went. A
  /// row that is not an orphan is never deleted: the rows are asked again inside the write.
  @discardableResult
  public static func repair(_ writer: any DatabaseWriter) throws -> Int {
    try writer.write { db in
      var removed = 0
      var byTable: [String: [Int64]] = [:]
      for row in try Row.fetchAll(db, sql: "PRAGMA foreign_key_check") {
        guard let table: String = row["table"], let rowid: Int64 = row["rowid"],
          repairableTables.contains(table)
        else { continue }
        byTable[table, default: []].append(rowid)
      }
      for (table, rowids) in byTable {
        for chunk in stride(from: 0, to: rowids.count, by: 500) {
          let part = rowids[chunk..<min(chunk + 500, rowids.count)]
          try db.execute(
            sql:
              "DELETE FROM \"\(table)\" WHERE rowid IN (\(databaseQuestionMarks(count: part.count)))",
            arguments: StatementArguments(Array(part)))
          removed += db.changesCount
        }
      }
      return removed
    }
  }
}

extension DatabaseStack {
  /// The check of this database (`DatabaseCheck.run`); reads only.
  public func checkDatabase() throws -> DatabaseCheck.Report {
    try DatabaseCheck.run(writer)
  }

  /// The repair of this database (`DatabaseCheck.repair`).
  @discardableResult
  public func repairDatabase() throws -> Int {
    try DatabaseCheck.repair(writer)
  }
}
