import CoreKit
import Foundation
import GRDB

/// The rows of the attachments and the answers to «how did the week go»
/// (`Schema/0017_attachments.sql`). It knows nothing of the files: `AttachmentService` joins the
/// two.
public struct AttachmentRepository: Sendable {
  private let writer: any DatabaseWriter

  public init(writer: any DatabaseWriter) {
    self.writer = writer
  }

  // MARK: Attachments

  /// Every row, oldest first. A row a newer build wrote that this one can not read is left out and
  /// stays in the database.
  public func all() throws -> [AttachedFile] {
    try writer.read { db in try Self.rows(db, sql: "SELECT * FROM attachments ORDER BY added_at, id") }
  }

  /// The digests every row names, including rows this build can not read.
  public func allHashes() throws -> Set<String> {
    try writer.read { db in
      Set(
        try String.fetchAll(db, sql: "SELECT DISTINCT content_hash FROM attachments")
          .map { $0.lowercased() })
    }
  }

  /// The files of one owner; the trash only when asked.
  public func attachments(
    of kind: AttachmentOwnerKind, id: UUID, includingTrash: Bool = false
  ) throws -> [AttachedFile] {
    try writer.read { db in
      try Self.rows(
        db,
        sql: """
          SELECT * FROM attachments WHERE owner_kind = ? AND owner_id = ?
          \(includingTrash ? "" : "AND trashed_at IS NULL") ORDER BY added_at, id
          """,
        arguments: [kind.rawValue, id.uuidString])
    }
  }

  public func trash() throws -> [AttachedFile] {
    try writer.read { db in
      try Self.rows(
        db, sql: "SELECT * FROM attachments WHERE trashed_at IS NOT NULL ORDER BY trashed_at, id")
    }
  }

  public func attachment(id: UUID) throws -> AttachedFile? {
    try writer.read { db in try Self.rows(db, sql: "SELECT * FROM attachments WHERE id = ?", arguments: [id.uuidString]).first }
  }

  /// How many rows name this content.
  public func references(toHash hash: String) throws -> Int {
    try writer.read { db in
      try Int.fetchOne(
        db, sql: "SELECT COUNT(*) FROM attachments WHERE content_hash = ?",
        arguments: [hash.lowercased()]) ?? 0
    }
  }

  public func insert(_ attachment: AttachedFile) throws {
    try writer.write { db in try attachment.insert(db) }
  }

  public func update(_ attachment: AttachedFile) throws {
    try writer.write { db in try attachment.update(db) }
  }

  public func moveToTrash(id: UUID, at date: Date) throws {
    try writer.write { db in
      try db.execute(
        sql: "UPDATE attachments SET trashed_at = ? WHERE id = ? AND trashed_at IS NULL",
        arguments: [StoredInstant.databaseValue(date), id.uuidString])
    }
  }

  public func restoreFromTrash(id: UUID) throws {
    try writer.write { db in
      try db.execute(
        sql: "UPDATE attachments SET trashed_at = NULL WHERE id = ?", arguments: [id.uuidString])
    }
  }

  /// Removes rows; no such row is no error. Returns the rows that were there.
  @discardableResult
  public func delete(ids: [UUID]) throws -> [AttachedFile] {
    try writer.write { db in
      var removed: [AttachedFile] = []
      for id in ids {
        guard
          let row = try Self.rows(
            db, sql: "SELECT * FROM attachments WHERE id = ?", arguments: [id.uuidString]
          ).first
        else { continue }
        _ = try AttachedFile.deleteOne(db, key: id.uuidString)
        removed.append(row)
      }
      return removed
    }
  }

  // MARK: Settings

  public func settings() throws -> AttachmentSettings {
    try writer.read { db in
      AttachmentSettings(
        storedValues: try SettingsRepository.values(of: AttachmentSettings.storageKeys, db: db))
    }
  }

  public func save(_ settings: AttachmentSettings) throws {
    try writer.write { db in
      for (key, value) in settings.storedValues {
        try SettingsRepository.set(key, to: value, in: db)
      }
    }
  }

  // MARK: The answers of the weeks

  public func answer(week: String) throws -> WeekAnswer? {
    try writer.read { db in try WeekAnswer.fetchOne(db, key: week) }
  }

  public func answers() throws -> [WeekAnswer] {
    try writer.read { db in try WeekAnswer.fetchAll(db, sql: "SELECT * FROM week_answers ORDER BY week") }
  }

  /// One answer a week: a second one replaces the first.
  public func save(_ answer: WeekAnswer) throws {
    try writer.write { db in try answer.save(db) }
  }

  public func removeAnswer(week: String) throws {
    _ = try writer.write { db in try WeekAnswer.deleteOne(db, key: week) }
  }

  private static func rows(
    _ db: Database, sql: String, arguments: StatementArguments = StatementArguments()
  ) throws -> [AttachedFile] {
    try Row.fetchAll(db, sql: sql, arguments: arguments).compactMap { try? AttachedFile(row: $0) }
  }
}
