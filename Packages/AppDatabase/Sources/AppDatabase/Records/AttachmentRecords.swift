import AppCore
import CoreKit
import Foundation
import GRDB

// The attachments and the answers to «how did the week go» (`Schema/0017_attachments.sql`),
// mapped by hand like every other record (`RowMapping`).

/// A row whose hash is not 64 hex characters fails the read of that row: it names no file. The
/// repository reads rows one by one and leaves it out, untouched in the database.
extension AttachedFile: @retroactive FetchableRecord, @retroactive PersistableRecord {
  public static let databaseTableName = "attachments"

  public init(row: Row) throws {
    guard let hash: String = row["content_hash"], AttachmentHash.isValid(hash) else {
      throw UnreadableValue(column: "content_hash")
    }
    guard let ownerKind = (row["owner_kind"] as String?).flatMap(AttachmentOwnerKind.init) else {
      throw UnreadableValue(column: "owner_kind")
    }
    let size: Int64 = row["byte_size"] ?? 0
    self.init(
      id: try RowMapping.uuid(row, "id"), ownerKind: ownerKind,
      ownerId: try RowMapping.uuid(row, "owner_id"), contentHash: hash.lowercased(),
      fileName: row["file_name"] ?? "", byteSize: max(0, size), mediaType: row["media_type"],
      kind: AttachmentKind(stored: row["kind"]),
      addedAt: try RowMapping.instant(row, "added_at"),
      trashedAt: try RowMapping.optionalInstant(row, "trashed_at"),
      keepForever: try RowMapping.flag(row, "keep_forever", fallback: false), note: row["note"])
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["id"] = id.uuidString
    container["owner_kind"] = ownerKind.rawValue
    container["owner_id"] = ownerId.uuidString
    container["content_hash"] = contentHash
    container["file_name"] = fileName
    container["byte_size"] = byteSize
    container["media_type"] = mediaType
    container["kind"] = kind.rawValue
    container["added_at"] = StoredInstant.databaseValue(addedAt)
    container["trashed_at"] = StoredInstant.databaseValue(trashedAt)
    container["keep_forever"] = keepForever
    container["note"] = note
  }
}

extension WeekAnswer: @retroactive FetchableRecord, @retroactive PersistableRecord {
  public static let databaseTableName = "week_answers"

  public init(row: Row) throws {
    guard let week: String = row["week"], !week.isEmpty else {
      throw UnreadableValue(column: "week")
    }
    let mood: Int = row["mood"] ?? 3
    self.init(
      week: week, mood: mood, answeredAt: try RowMapping.instant(row, "answered_at"))
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["week"] = week
    container["mood"] = mood
    container["answered_at"] = StoredInstant.databaseValue(answeredAt)
  }
}
