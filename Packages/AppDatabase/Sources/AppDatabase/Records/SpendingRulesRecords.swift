import CoreKit
import Foundation
import GRDB

// The tags, their links to parts, the rules and the notes of days
// (`Schema/0013_spending_rules.sql`), mapped by hand like every other record (`RowMapping`).

extension Tag: @retroactive FetchableRecord, @retroactive PersistableRecord {
  public static let databaseTableName = "tags"

  public init(row: Row) throws {
    self.init(
      id: try RowMapping.uuid(row, "id"),
      name: row["name"] ?? "",
      archived: try RowMapping.flag(row, "archived", fallback: false),
      createdAt: try RowMapping.instant(row, "created_at"))
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["id"] = id.uuidString
    container["name"] = name
    container["archived"] = archived
    container["created_at"] = StoredInstant.databaseValue(createdAt)
  }
}

/// The id of a link is the pair itself, so the same tag on the same part is one row on every
/// device.
extension PartTag: @retroactive FetchableRecord, @retroactive PersistableRecord {
  public static let databaseTableName = "part_tags"

  public init(row: Row) throws {
    self.init(
      partId: try RowMapping.uuid(row, "part_id"), tagId: try RowMapping.uuid(row, "tag_id"))
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["id"] = Self.rowId(partId: partId, tagId: tagId)
    container["part_id"] = partId.uuidString
    container["tag_id"] = tagId.uuidString
  }

  /// The primary key the schema demands: `<part id>:<tag id>`.
  static func rowId(partId: UUID, tagId: UUID) -> String {
    partId.uuidString + ":" + tagId.uuidString
  }
}

/// A rule whose conditions or actions the build can not read (written by a newer one) fails the
/// read of that row; `RulesRepository` reads rows one by one and leaves such a rule out of the
/// list, untouched in the database.
extension Rule: @retroactive FetchableRecord, @retroactive PersistableRecord {
  public static let databaseTableName = "rules"

  public init(row: Row) throws {
    guard let conditions = RuleStorage.conditions(json: row["conditions"] ?? "[]"),
      let actions = RuleStorage.actions(json: row["actions"] ?? "[]")
    else { throw UnreadableValue(column: "conditions") }
    self.init(
      id: try RowMapping.uuid(row, "id"),
      name: row["name"] ?? "",
      position: try RowMapping.optionalInteger(row, "position") ?? 0,
      enabled: try RowMapping.flag(row, "enabled", fallback: true),
      origin: RuleOrigin(rawValue: row["origin"] ?? "manual") ?? .manual,
      conditions: conditions, actions: actions,
      createdAt: try RowMapping.instant(row, "created_at"),
      updatedAt: try RowMapping.instant(row, "updated_at"))
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["id"] = id.uuidString
    container["name"] = name
    container["position"] = position
    container["enabled"] = enabled
    container["origin"] = origin.rawValue
    container["conditions"] = RuleStorage.json(conditions)
    container["actions"] = RuleStorage.json(actions)
    container["created_at"] = StoredInstant.databaseValue(createdAt)
    container["updated_at"] = StoredInstant.databaseValue(updatedAt)
  }
}

extension DayNote: @retroactive FetchableRecord, @retroactive PersistableRecord {
  public static let databaseTableName = "day_notes"

  public init(row: Row) throws {
    guard let day = RowMapping.day(row, "day") else { throw UnreadableValue(column: "day") }
    self.init(
      id: try RowMapping.uuid(row, "id"), day: day, text: row["text"] ?? "",
      createdAt: try RowMapping.instant(row, "created_at"),
      updatedAt: try RowMapping.instant(row, "updated_at"))
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["id"] = id.uuidString
    container["day"] = day.iso
    container["text"] = text
    container["created_at"] = StoredInstant.databaseValue(createdAt)
    container["updated_at"] = StoredInstant.databaseValue(updatedAt)
  }
}
