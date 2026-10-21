import CoreKit
import Foundation
import GRDB

// The saved «what if» scenarios (`Schema/0010_scenarios.sql`), mapped by hand like every other
// record (`RowMapping`). The JSON columns are opaque text here.

/// Instants are written the way every instant is (`StoredInstant`); a `created_at` or an
/// `updated_at` that cannot be read fails the read, a `deleted_at` that cannot be read too.
extension Scenario: @retroactive FetchableRecord, @retroactive PersistableRecord {
  public static let databaseTableName = "scenarios"

  public init(row: Row) throws {
    self.init(
      id: try RowMapping.uuid(row, "id"),
      name: row["name"] ?? "",
      sort: try RowMapping.optionalInteger(row, "sort") ?? 0,
      specJSON: row["spec_json"] ?? "",
      baselineJSON: row["baseline_json"] ?? "",
      createdAt: try RowMapping.instant(row, "created_at"),
      updatedAt: try RowMapping.instant(row, "updated_at"),
      deletedAt: try RowMapping.optionalInstant(row, "deleted_at"))
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["id"] = id.uuidString
    container["name"] = name
    container["sort"] = sort
    container["spec_json"] = specJSON
    container["baseline_json"] = baselineJSON
    container["created_at"] = StoredInstant.databaseValue(createdAt)
    container["updated_at"] = StoredInstant.databaseValue(updatedAt)
    container["deleted_at"] = StoredInstant.databaseValue(deletedAt)
  }
}
