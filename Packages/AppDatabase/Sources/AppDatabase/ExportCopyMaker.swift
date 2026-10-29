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
      // The copy is not a device taking part in the exchange.
      try db.execute(sql: "UPDATE sync_meta SET value = '0' WHERE key = 'recording'")
      try Self.cut(request, db: db)
    }
    if request.anonymize, let anonymizer {
      try anonymizer.anonymize(copy: ExportCopyDatabase(writer: queue))
    }
    try queue.writeWithoutTransaction { db in try db.execute(sql: "VACUUM") }

    let final = folder.appendingPathComponent("final.sqlite")
    let cut = try ExportRepository(writer: queue).snapshot(to: final)
    let attachments = request.includeAttachments ? try AttachmentRepository(writer: queue).all() : []
    return ExportCopyDraft(
      databaseURL: final, tables: cut.tables, rowCounts: cut.rowCounts,
      rowCountsBefore: before.rowCounts, attachments: attachments)
  }

  // MARK: - Cutting the copy

  /// Applies the span of days and the hidden accounts to the open copy.
  static func cut(_ request: ExportCopyRequest, db: Database) throws {
    if case .period(let range) = request.scope {
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
    try db.execute(
      sql: "UPDATE goals SET account_id = NULL WHERE account_id IN (\(marks))",
      arguments: arguments)
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
