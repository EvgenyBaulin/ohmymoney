import AppCore
import CoreAnalytics
import CoreKit
import Foundation
import GRDB

/// Replaces names and free texts in a copy of the database. It is handed the copy, never the live
/// database: the original does not change. Whatever it writes is cleaned out of the file's free
/// pages afterwards.
public protocol ExportCopyAnonymizing: Sendable {
  func anonymize(copy: ExportCopyDatabase) throws
}

/// The open copy of the database an anonymizer works on. `writer` is for code that speaks GRDB;
/// `execute` is for a statement that needs nothing else.
public struct ExportCopyDatabase: Sendable {
  public let writer: any DatabaseWriter

  public func execute(_ sql: String) throws {
    try writer.write { db in try db.execute(sql: sql) }
  }
}

public enum ExportCopyError: Error, Equatable {
  /// Everything that goes out of the Mac is locked: a copy without a password is not made.
  case passwordMissing
  /// The owner asked for the names to be replaced and this build has no way to do it.
  case anonymizerMissing
  /// A hidden account is still named by something the copy keeps, so it cannot be left out.
  case hiddenAccountInUse
  /// The span of days is empty.
  case periodEmpty
}

/// The cut copy of the data, as a file and as CSV tables, and what the cut took out.
public struct ExportCopyDraft: Sendable {
  /// The cut, vacuumed copy of the database, inside the folder the caller gave.
  public let databaseURL: URL
  public let tables: [ExportRepository.Table]
  public let rowCounts: [String: Int]
  /// The rows of the live database before the cut, for «осталось / не вошло».
  public let rowCountsBefore: [String: Int]
  /// The attached-file rows the copy kept (none when the files are left out).
  public let attachments: [AttachedFile]

  public var operationsLeftOut: Int { diff("transactions") }
  public var transfersLeftOut: Int { diff("transfers") }
  public var accountsLeftOut: Int { diff("payment_methods") }
  /// Planned payments, expected incomes, debt entries and goals that went with a hidden account.
  public var plansLeftOut: Int {
    ["scheduled_payments", "expected_income", "debt_entries", "goals"].map(diff).reduce(0, +)
  }

  private func diff(_ table: String) -> Int {
    (rowCountsBefore[table] ?? 0) - (rowCounts[table] ?? 0)
  }
}

/// Makes the cut copy behind «Экспорт копии». The live database is read once, through the backup
/// API; everything after happens to a temporary copy: the span of days is applied, the hidden
/// accounts are left out when asked, the names are replaced when asked, and the file is vacuumed
/// so that nothing deleted stays readable in a free page. The CSV files and the row counts are
/// then taken from the cut copy in one read.
public struct ExportCopyMaker: Sendable {
  private let repository: ExportRepository

  public init(writer: any DatabaseWriter) {
    self.repository = ExportRepository(writer: writer)
  }

  /// `folder` must exist; the files made there stay for the caller to read and remove.
  public func make(
    _ request: ExportCopyRequest, in folder: URL, anonymizer: (any ExportCopyAnonymizing)? = nil
  ) throws -> ExportCopyDraft {
    if request.anonymize && anonymizer == nil { throw ExportCopyError.anonymizerMissing }
    if case .period(let range) = request.scope, range.isEmpty { throw ExportCopyError.periodEmpty }

    let draft = folder.appendingPathComponent("draft.sqlite")
    let before = try repository.snapshot(to: draft)
    let queue = try DatabaseQueue(path: draft.path)
    defer { try? queue.close() }
    // Deleted rows must not stay readable in the free pages of the file.
    try queue.writeWithoutTransaction { db in try db.execute(sql: "PRAGMA secure_delete = ON") }
    try queue.write { db in
      // The copy is not a device taking part in the exchange, and what the exchange remembers
      // is this device's: the journal of changes keeps every old description, place and sum
      // of every row, hidden accounts and days outside the period too — none of it leaves.
      try db.execute(sql: "UPDATE sync_meta SET value = '0' WHERE key = 'recording'")
      for table in SyncTables.bookkeeping where table != "sync_meta" {
        if try db.tableExists(table) { try db.execute(sql: "DELETE FROM \(table)") }
      }
      // Where the owner stands is for this device alone, whatever the copy is for.
      for table in SyncTables.deviceLocal {
        guard try db.tableExists(table) else { continue }
        try db.execute(sql: "DELETE FROM \(table)")
      }
      try Self.cut(request, db: db)
    }
    if request.anonymize, let anonymizer {
      try anonymizer.anonymize(copy: ExportCopyDatabase(writer: queue))
    }
    try queue.writeWithoutTransaction { db in try db.execute(sql: "VACUUM") }

    let final = folder.appendingPathComponent("final.sqlite")
    let cut = try ExportRepository(writer: queue).snapshot(to: final)
    let attachments =
      request.includeAttachments ? try AttachmentRepository(writer: queue).all() : []
    return ExportCopyDraft(
      databaseURL: final, tables: cut.tables, rowCounts: cut.rowCounts,
      rowCountsBefore: before.rowCounts, attachments: attachments)
  }

  // MARK: - Cutting the copy

  /// Applies the span of days and the hidden accounts to the open copy.
  static func cut(_ request: ExportCopyRequest, db: Database) throws {
    // A statement review list kept by an older build names accounts and totals; nothing reads it
    // now, so a copy never carries it, hidden accounts or not.
    try db.execute(
      sql: "DELETE FROM settings WHERE key = ?", arguments: [SQLAnonymizer.legacyStatementReviewKey]
    )
    if case .period(let range) = request.scope {
      // In SQL on the stored day, so a row this build cannot read is cut as well, never kept.
      try db.execute(
        sql: """
          DELETE FROM thing_valuations
          WHERE valued_on IS NULL OR valued_on < ? OR valued_on > ?
          """,
        arguments: [range.start.iso, range.end.iso])
      // The readings of meters by their day. A bill is a month's: it stays only when its whole
      // month lies inside the span — a bill of a month the span only touches tells about days
      // the copy leaves out. Its month, not `pay_by` or `recorded_at`, is what the bill is for;
      // the lines of a bill go with it.
      if try db.tableExists("utility_readings") {
        try db.execute(
          sql: "DELETE FROM utility_readings WHERE read_on IS NULL OR read_on < ? OR read_on > ?",
          arguments: [range.start.iso, range.end.iso])
        let firstWhole =
          range.start.day == 1 ? range.start.monthKey : range.start.monthKey.next
        let lastWhole =
          range.end.adding(days: 1).monthKey != range.end.monthKey
          ? range.end.monthKey : range.end.monthKey.previous
        try db.execute(
          sql: "DELETE FROM utility_bills WHERE period IS NULL OR period < ? OR period > ?",
          arguments: [firstWhole.iso, lastWhole.iso])
        try db.execute(
          sql: "DELETE FROM utility_charges WHERE bill_id NOT IN (SELECT id FROM utility_bills)")
      }
      // The day an operation is shown on, in the zone it was recorded in; a transfer has no zone
      // and is read in Moscow, as everywhere else.
      let outside = try CoreKit.Transaction.fetchAll(db)
        .filter { !range.contains(TravelDay.day(of: $0.occurredAt, zoneId: $0.timeZoneId)) }
        .map(\.id.uuidString)
      try delete(ids: outside, from: "transactions", db: db)
      let outsideTransfers = try Transfer.fetchAll(db)
        .filter { !range.contains(TravelDay.day(of: $0.occurredAt, zoneId: nil)) }
        .map(\.id.uuidString)
      try delete(ids: outsideTransfers, from: "transfers", db: db)
    }
    if !request.includeHidden { try dropHiddenAccounts(db: db) }
    if !request.includeAttachments { try db.execute(sql: "DELETE FROM attachments") }
  }

  /// The hidden accounts, their cards, operations and transfers are not in the copy. Whatever
  /// else names a hidden account is cleared first, so no reference is left dangling.
  private static func dropHiddenAccounts(db: Database) throws {
    let hidden = try String.fetchAll(db, sql: "SELECT id FROM payment_methods WHERE hidden = 1")
    guard !hidden.isEmpty else { return }
    let marks = databaseQuestionMarks(count: hidden.count)
    let arguments = StatementArguments(hidden)
    let twice = StatementArguments(hidden + hidden)
    // A bill paid by an operation of a hidden account, or tied to a payment planned on one, would
    // still tell what the account pays for: it goes, with its lines, before the operations and
    // payments do (their deletion would only clear the link and keep the bill).
    if try db.tableExists("utility_bills") {
      try db.execute(
        sql: """
          DELETE FROM utility_bills
          WHERE transaction_id IN (
              SELECT id FROM transactions WHERE payment_method_id IN (\(marks))
                OR card_id IN (SELECT id FROM cards WHERE payment_method_id IN (\(marks))))
            OR scheduled_payment_id IN (
              SELECT id FROM scheduled_payments WHERE payment_method_id IN (\(marks)))
          """, arguments: StatementArguments(hidden + hidden + hidden))
      try db.execute(
        sql: "DELETE FROM utility_charges WHERE bill_id NOT IN (SELECT id FROM utility_bills)")
    }
    try db.execute(
      sql: """
        DELETE FROM transactions WHERE payment_method_id IN (\(marks))
          OR card_id IN (SELECT id FROM cards WHERE payment_method_id IN (\(marks)))
        """, arguments: twice)
    try db.execute(
      sql: """
        DELETE FROM transfers
        WHERE from_payment_method_id IN (\(marks)) OR to_payment_method_id IN (\(marks))
        """, arguments: twice)
    // What the owner planned on a hidden account goes with it: a rent or a pay kept without its
    // account would still tell what the account is.
    for table in ["scheduled_payments", "expected_income", "debt_entries"] {
      try db.execute(
        sql: "DELETE FROM \(table) WHERE payment_method_id IN (\(marks))", arguments: arguments)
    }
    do {
      try db.execute(
        sql: "DELETE FROM goals WHERE account_id IN (\(marks))", arguments: arguments)
    } catch let error as GRDB.DatabaseError where error.resultCode == .SQLITE_CONSTRAINT {
      // A goal something still points at stays, without the account.
      try db.execute(
        sql: """
          UPDATE goals SET account_id = NULL, transfer_on_contribution = 0
          WHERE account_id IN (\(marks))
          """, arguments: arguments)
    }
    try db.execute(
      sql: """
        UPDATE payment_methods SET cashback_points_account_id = NULL
        WHERE cashback_points_account_id IN (\(marks))
        """, arguments: arguments)
    try db.execute(
      sql: """
        UPDATE payment_methods SET interest_account_id = NULL
        WHERE interest_account_id IN (\(marks))
        """, arguments: arguments)
    do {
      try db.execute(
        sql: "DELETE FROM payment_methods WHERE id IN (\(marks))", arguments: arguments)
    } catch let error as GRDB.DatabaseError where error.resultCode == .SQLITE_CONSTRAINT {
      throw ExportCopyError.hiddenAccountInUse
    }
  }

  private static func delete(ids: [String], from table: String, db: Database) throws {
    var start = 0
    while start < ids.count {
      let chunk = Array(ids[start..<min(start + 400, ids.count)])
      try db.execute(
        sql: "DELETE FROM \(table) WHERE id IN (\(databaseQuestionMarks(count: chunk.count)))",
        arguments: StatementArguments(chunk))
      start += chunk.count
    }
  }
}
