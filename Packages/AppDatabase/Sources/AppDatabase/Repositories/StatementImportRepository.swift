import AppCore
import CoreKit
import Foundation
import GRDB

/// A statement that was loaded, as the list of imports shows it.
public struct StoredImport: Sendable, Hashable, Identifiable {
  public var record: StatementImportRecord
  /// A hash of the file, so the same file loaded twice is noticed; `nil` for an import made
  /// before the hash was kept.
  public var fileHash: String?
  /// When the import was undone: its operations are gone, the row stays in the list.
  public var undoneAt: Date?

  public var id: String { record.id }
  public var isUndone: Bool { undoneAt != nil }
}

/// One operation an import added, for undoing the import: only an operation nobody touched since
/// goes with it, the others are asked about.
public struct ImportedRow: Sendable, Hashable {
  public var operationId: UUID
  /// Edited after it was added (its `updated_at` is not its `created_at`).
  public var touched: Bool
  public var deleted: Bool
}

/// A held line of the bank that is now posted: the stored line takes the new status and the
/// day the bank posted it.
public struct StatementStatusWrite: Sendable, Hashable {
  public var operationId: UUID
  public var status: StatementStatus
  public var postedOn: DateOnly?

  public init(operationId: UUID, status: StatementStatus, postedOn: DateOnly?) {
    self.operationId = operationId
    self.status = status
    self.postedOn = postedOn
  }
}

/// The books of the loading of statements (`Schema/0014_import_year_questions_subscriptions.sql`):
/// the list of imports, what an account already holds for the finding of duplicates, who the
/// owner is as banks write it, and the owner's own profiles of files. The operations themselves
/// are written through the operation store like any other, with `Transaction.source`,
/// `bankStatus`, `postedOn`, `dedupKey` and `importBatchId` set.
public struct StatementImportRepository: Sendable {
  private let writer: any DatabaseWriter

  public init(writer: any DatabaseWriter) {
    self.writer = writer
  }

  // MARK: - Imports

  /// Every import, newest first. A row made by the earliest builds has no account, no profile
  /// and no period: it reads with empty ids and no period.
  public func imports() throws -> [StoredImport] {
    try writer.read { db in
      try Row.fetchAll(db, sql: "SELECT * FROM import_batches ORDER BY imported_at DESC, id")
        .compactMap { try? Self.stored($0) }
    }
  }

  /// Writes the row of an import. `record.id` is the id operations point at, a UUID.
  public func record(_ record: StatementImportRecord, fileHash: String? = nil) throws {
    guard UUID(uuidString: record.id) != nil else { throw UnreadableValue(column: "id") }
    try writer.write { db in try Self.insert(record, fileHash: fileHash, db: db) }
  }

  static func insert(_ record: StatementImportRecord, fileHash: String?, db: Database) throws {
    try db.execute(
      sql: """
        INSERT INTO import_batches (
          id, source_file_name, imported_at, rows_total, rows_imported, rows_skipped,
          payment_method_id, profile_id, period_from, period_to, rows_declined, rows_unparsed,
          file_hash)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
          source_file_name = excluded.source_file_name, imported_at = excluded.imported_at,
          rows_total = excluded.rows_total, rows_imported = excluded.rows_imported,
          rows_skipped = excluded.rows_skipped, payment_method_id = excluded.payment_method_id,
          profile_id = excluded.profile_id, period_from = excluded.period_from,
          period_to = excluded.period_to, rows_declined = excluded.rows_declined,
          rows_unparsed = excluded.rows_unparsed, file_hash = excluded.file_hash
        """,
      arguments: [
        record.id, record.fileName, StoredInstant.databaseValue(record.importedAt),
        record.rowCount, record.newCount, record.duplicateCount,
        UUID(uuidString: record.accountID)?.uuidString, record.profileID,
        record.periodFrom?.iso, record.periodTo?.iso, record.declinedCount, record.unparsedCount,
        fileHash,
      ])
  }

  /// Marks the import as undone. The operations it added are taken away by the operation
  /// store (one step of ⌘Z), the row stays so the list says what happened.
  public func markUndone(id: String, at moment: Date = Date()) throws {
    try writer.write { db in
      try db.execute(
        sql: "UPDATE import_batches SET undone_at = ? WHERE id = ?",
        arguments: [StoredInstant.databaseValue(moment), id])
    }
  }

  /// Takes the row of an import away (⌘Z of the loading of a statement). The operations that
  /// point at it are not deleted: the schema empties their link.
  public func deleteImport(id: String) throws {
    try writer.write { db in
      try db.execute(sql: "DELETE FROM import_batches WHERE id = ?", arguments: [id])
    }
  }

  /// Takes the mark back (⌘Z of the undoing of an import).
  public func clearUndone(id: String) throws {
    try writer.write { db in
      try db.execute(
        sql: "UPDATE import_batches SET undone_at = NULL WHERE id = ?", arguments: [id])
    }
  }

  /// The import of a file with this hash that has not been undone, if any: the same file twice.
  public func liveImport(withHash hash: String) throws -> StoredImport? {
    try writer.read { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT * FROM import_batches WHERE file_hash = ? AND undone_at IS NULL
          ORDER BY imported_at DESC, id
          """,
        arguments: [hash]
      )
      .compactMap { try? Self.stored($0) }.first
    }
  }

  /// The operations an import added, in the order they were made.
  public func operations(ofImport id: String) throws -> [ImportedRow] {
    try writer.read { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT id, created_at, updated_at, deleted_at FROM transactions
          WHERE import_batch_id = ? ORDER BY created_at, id
          """,
        arguments: [id]
      )
      .compactMap { row -> ImportedRow? in
        guard let operation = RowMapping.optionalUUID(row, "id") else { return nil }
        let created: String? = row["created_at"]
        let updated: String? = row["updated_at"]
        let deleted: DatabaseValue = row["deleted_at"]
        return ImportedRow(
          operationId: operation, touched: created != updated, deleted: !deleted.isNull)
      }
    }
  }

  private static func stored(_ row: Row) throws -> StoredImport {
    let record = StatementImportRecord(
      id: row["id"] ?? "", accountID: row["payment_method_id"] ?? "",
      profileID: row["profile_id"] ?? "", fileName: row["source_file_name"] ?? "",
      importedAt: try RowMapping.instant(row, "imported_at"),
      periodFrom: RowMapping.day(row, "period_from"), periodTo: RowMapping.day(row, "period_to"),
      rowCount: try RowMapping.optionalInteger(row, "rows_total") ?? 0,
      newCount: try RowMapping.optionalInteger(row, "rows_imported") ?? 0,
      duplicateCount: try RowMapping.optionalInteger(row, "rows_skipped") ?? 0,
      declinedCount: try RowMapping.optionalInteger(row, "rows_declined") ?? 0,
      unparsedCount: try RowMapping.optionalInteger(row, "rows_unparsed") ?? 0)
    return StoredImport(
      record: record, fileHash: row["file_hash"],
      undoneAt: try RowMapping.optionalInstant(row, "undone_at"))
  }

  // MARK: - What an account holds

  /// The operations of an account that came from a statement and are alive, for the finding of
  /// duplicates (`StatementDeduplicator.diff`). The amount is signed the way a statement signs
  /// it: an expense is negative. The place is the name of the place, else the note, folded.
  public func existing(account: UUID) throws -> [StatementExisting] {
    try writer.read { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT t.id, t.kind, t.occurred_at, t.time_zone, t.amount_e4, t.dedup_key,
                 t.bank_status, t.note, p.name AS place_name
          FROM transactions t LEFT JOIN places p ON p.id = t.place_id
          WHERE t.payment_method_id = ? AND t.dedup_key IS NOT NULL AND t.deleted_at IS NULL
          ORDER BY t.occurred_at, t.id
          """,
        arguments: [account.uuidString]
      )
      .compactMap { row -> StatementExisting? in
        guard let key: String = row["dedup_key"], let id: String = row["id"],
          let moment = try? RowMapping.instant(row, "occurred_at")
        else { return nil }
        let magnitude = AmountE4(raw: row["amount_e4"] ?? 0)
        let signed =
          (row["kind"] as String?) == TransactionKind.expense.rawValue
          ? AmountE4(raw: -magnitude.raw) : magnitude
        let place: String = row["place_name"] ?? row["note"] ?? ""
        return StatementExisting(
          id: id, key: StatementDedupKey(value: key),
          status: (row["bank_status"] as String?).flatMap(StatementStatus.init(rawValue:))
            ?? .posted,
          day: TravelDay.day(of: moment, zoneId: row["time_zone"]), amount: signed,
          placeKey: NameKey.fold(place))
      }
    }
  }

  /// The operations the owner typed by hand on an account in a span of days, for the matching
  /// with the bank's lines (`StatementManualMatcher`).
  public func manualEntries(
    account: UUID, from: DateOnly, to: DateOnly
  ) throws -> [StatementManualEntry] {
    try writer.read { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT id, kind, occurred_at, time_zone, amount_e4, currency FROM transactions
          WHERE payment_method_id = ? AND dedup_key IS NULL AND deleted_at IS NULL
            AND (source IS NULL OR source = 'manual') AND kind IN ('expense', 'income')
          ORDER BY occurred_at, id
          """,
        arguments: [account.uuidString]
      )
      .compactMap { row -> StatementManualEntry? in
        guard let id: String = row["id"], let moment = try? RowMapping.instant(row, "occurred_at")
        else { return nil }
        let day = TravelDay.day(of: moment, zoneId: row["time_zone"])
        guard day >= from, day <= to else { return nil }
        let magnitude = AmountE4(raw: row["amount_e4"] ?? 0)
        let signed =
          (row["kind"] as String?) == TransactionKind.expense.rawValue
          ? AmountE4(raw: -magnitude.raw) : magnitude
        return StatementManualEntry(
          id: id, day: day, amount: signed, currency: CurrencyCode(row["currency"] ?? "RUB"))
      }
    }
  }

  /// A held line the bank has now posted: its status and posting day, in one write. Returns the
  /// values it had, so ⌘Z can put them back.
  @discardableResult
  public func apply(
    _ writes: [StatementStatusWrite], at moment: Date = Date()
  ) throws
    -> [StatementStatusWrite]
  {
    try writer.write { db in
      var before: [StatementStatusWrite] = []
      for write in writes {
        guard
          let row = try Row.fetchOne(
            db, sql: "SELECT bank_status, posted_on FROM transactions WHERE id = ?",
            arguments: [write.operationId.uuidString])
        else { continue }
        before.append(
          StatementStatusWrite(
            operationId: write.operationId,
            status: (row["bank_status"] as String?).flatMap(StatementStatus.init(rawValue:))
              ?? .posted,
            postedOn: RowMapping.day(row, "posted_on")))
        try db.execute(
          sql:
            "UPDATE transactions SET bank_status = ?, posted_on = ?, updated_at = ? WHERE id = ?",
          arguments: [
            write.status.rawValue, write.postedOn?.iso, StoredInstant.databaseValue(moment),
            write.operationId.uuidString,
          ])
      }
      return before
    }
  }

  // MARK: - Who the owner is

  /// The phones, names, contracts and cards of the owner's own. Personal data: in no CSV, no
  /// exchange file and no report.
  public func identity() throws -> StatementIdentity {
    try writer.read { db in
      var items: [String: [String]] = [:]
      for row in try Row.fetchAll(
        db, sql: "SELECT kind, value FROM identity_items ORDER BY created_at, id")
      {
        items[row["kind"] ?? "", default: []].append(row["value"] ?? "")
      }
      return StatementIdentity(
        phones: items["phone"] ?? [], names: items["name"] ?? [],
        contractNumbers: items["contract"] ?? [], cardMasks: items["card"] ?? [])
    }
  }

  /// Makes the table hold exactly `identity`: values already there keep their row, new ones are
  /// added, the others go. Returns what was there before.
  @discardableResult
  public func save(
    _ identity: StatementIdentity, at moment: Date = Date()
  ) throws
    -> StatementIdentity
  {
    let before = try self.identity()
    try writer.write { db in
      let wanted: [(String, [String])] = [
        ("phone", identity.phones), ("name", identity.names),
        ("contract", identity.contractNumbers), ("card", identity.cardMasks),
      ]
      for (kind, values) in wanted {
        let clean = Self.distinct(values)
        let have = try Row.fetchAll(
          db, sql: "SELECT id, value FROM identity_items WHERE kind = ?", arguments: [kind])
        let keep = Set(clean)
        for row in have where !keep.contains(row["value"] as String? ?? "") {
          try db.execute(
            sql: "DELETE FROM identity_items WHERE id = ?", arguments: [row["id"] as String?])
        }
        let present = Set(have.map { $0["value"] as String? ?? "" })
        for value in clean where !present.contains(value) {
          try db.execute(
            sql: "INSERT INTO identity_items (id, kind, value, created_at) VALUES (?, ?, ?, ?)",
            arguments: [UUID().uuidString, kind, value, StoredInstant.databaseValue(moment)])
        }
      }
    }
    return before
  }

  private static func distinct(_ values: [String]) -> [String] {
    var seen = Set<String>()
    return values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty && seen.insert($0).inserted }
  }

  // MARK: - The owner's profiles of files

  /// The profiles the owner made, by name. A profile this build can not read is left out and
  /// stays in the database.
  public func profiles() throws -> [StatementProfile] {
    try writer.read { db in
      try Row.fetchAll(db, sql: "SELECT payload FROM statement_profiles ORDER BY bank_name, id")
        .compactMap { row -> StatementProfile? in
          guard let text: String = row["payload"] else { return nil }
          return try? JSONDecoder().decode(StatementProfile.self, from: Data(text.utf8))
        }
    }
  }

  public func save(_ profile: StatementProfile, at moment: Date = Date()) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let payload = String(decoding: try encoder.encode(profile), as: UTF8.self)
    let stamp = StoredInstant.databaseValue(moment)
    try writer.write { db in
      try db.execute(
        sql: """
          INSERT INTO statement_profiles (id, bank_name, payload, created_at, updated_at)
          VALUES (?, ?, ?, ?, ?)
          ON CONFLICT(id) DO UPDATE SET
            bank_name = excluded.bank_name, payload = excluded.payload,
            updated_at = excluded.updated_at
          """,
        arguments: [profile.id, profile.bankName, payload, stamp, stamp])
    }
  }

  public func deleteProfile(id: String) throws {
    try writer.write { db in
      try db.execute(sql: "DELETE FROM statement_profiles WHERE id = ?", arguments: [id])
    }
  }
}
