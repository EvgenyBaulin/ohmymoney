import CoreAnalytics
import CoreKit
import Foundation
import GRDB

/// What a copy would hold, counted on the live database without making the copy: the sentence
/// «Войдёт: N операций, M переводов» of the dialog, and the rows behind the numbers «не вошло».
public struct ExportCopyCounts: Equatable, Sendable {
  public var operations: Int
  public var transfers: Int
  public var accounts: Int
  public var operationsLeftOut: Int
  public var transfersLeftOut: Int
  /// Accounts the owner hid (all of them, whether they go into the copy or not).
  public var hiddenAccounts: Int
  /// Rows of attached files whose operations stay in the copy.
  public var attachments: Int
  public var attachmentBytes: Int64

  public init(
    operations: Int = 0, transfers: Int = 0, accounts: Int = 0, operationsLeftOut: Int = 0,
    transfersLeftOut: Int = 0, hiddenAccounts: Int = 0, attachments: Int = 0,
    attachmentBytes: Int64 = 0
  ) {
    self.operations = operations
    self.transfers = transfers
    self.accounts = accounts
    self.operationsLeftOut = operationsLeftOut
    self.transfersLeftOut = transfersLeftOut
    self.hiddenAccounts = hiddenAccounts
    self.attachments = attachments
    self.attachmentBytes = attachmentBytes
  }
}

/// Counts what `ExportCopyMaker` would keep, with the same two cuts: the span of days (the day an
/// operation is shown on, in the zone it was recorded in; a transfer is read in Moscow) and the
/// hidden accounts. Read-only.
public struct ExportCopyPreviewer: Sendable {
  private let writer: any DatabaseWriter

  public init(writer: any DatabaseWriter) {
    self.writer = writer
  }

  public func counts(for request: ExportCopyRequest) throws -> ExportCopyCounts {
    try writer.read { db in
      let hidden = Set(
        try String.fetchAll(db, sql: "SELECT id FROM payment_methods WHERE hidden = 1"))
      let cards = try Dictionary(
        uniqueKeysWithValues: Row.fetchAll(db, sql: "SELECT id, payment_method_id FROM cards")
          .map { (($0["id"] as String), ($0["payment_method_id"] as String?)) })
      let skipHidden = !request.includeHidden && !hidden.isEmpty

      var span: DayRange?
      if case .period(let range) = request.scope { span = range }

      var operations = 0
      var operationsAll = 0
      var kept = Set<String>()
      for transaction in try CoreKit.Transaction.fetchAll(db) {
        operationsAll += 1
        if let span,
          !span.contains(TravelDay.day(of: transaction.occurredAt, zoneId: transaction.timeZoneId))
        {
          continue
        }
        if skipHidden {
          let method = transaction.paymentMethodId?.uuidString
          let viaCard = transaction.cardId.flatMap { cards[$0.uuidString] ?? nil }
          if let method, hidden.contains(method) { continue }
          if let viaCard, hidden.contains(viaCard) { continue }
        }
        operations += 1
        kept.insert(transaction.id.uuidString)
      }

      var transfers = 0
      var transfersAll = 0
      for transfer in try Transfer.fetchAll(db) {
        transfersAll += 1
        if let span, !span.contains(TravelDay.day(of: transfer.occurredAt, zoneId: nil)) {
          continue
        }
        if skipHidden,
          hidden.contains(transfer.fromAccountId.uuidString)
            || hidden.contains(transfer.toAccountId.uuidString)
        {
          continue
        }
        transfers += 1
      }

      let accountsAll = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM payment_methods") ?? 0
      let accounts = skipHidden ? accountsAll - hidden.count : accountsAll

      var attachments = 0
      var bytes: Int64 = 0
      if request.includeAttachments {
        for file in try AttachmentRepository(writer: writer).all()
        where file.ownerKind != .transaction || kept.contains(file.ownerId.uuidString) {
          attachments += 1
          bytes += file.byteSize
        }
      }
      return ExportCopyCounts(
        operations: operations, transfers: transfers, accounts: accounts,
        operationsLeftOut: operationsAll - operations, transfersLeftOut: transfersAll - transfers,
        hiddenAccounts: hidden.count, attachments: attachments, attachmentBytes: bytes)
    }
  }
}

/// Rows per table of the live database, for «Что знает приложение». Only counts: no value of any
/// row is read. The tables of the exchange with other devices and of the schema itself are not
/// records of the owner and are left out.
public enum StorageCensus {
  public static func tableRows(writer: any DatabaseWriter) throws -> [String: Int] {
    try writer.read { db in
      let names = try String.fetchAll(
        db,
        sql: """
          SELECT name FROM sqlite_master
          WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'sync_%'
            AND name NOT LIKE 'grdb_%' AND name NOT LIKE 'schema_%'
          """)
      var rows: [String: Int] = [:]
      for name in names {
        // A table name comes from the schema itself; it is quoted all the same.
        let quoted = "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        rows[name] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(quoted)") ?? 0
      }
      return rows
    }
  }
}
