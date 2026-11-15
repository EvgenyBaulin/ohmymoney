import CoreKit
import Foundation
import GRDB

// The owner's marks on the map (`Schema/0031_place_marks.sql`), mapped by hand like every other
// record (`RowMapping`). A row whose coordinate does not read fails the read of that row
// (`UnreadableValue`); the repository leaves it out, untouched in the database.

extension PlaceMark: @retroactive FetchableRecord, @retroactive PersistableRecord {
  public static let databaseTableName = "place_marks"

  public init(row: Row) throws {
    // `amount` is the strict reader of a whole number; a coordinate is one, not money.
    guard
      let point = GeoPoint(
        latitudeE7: try RowMapping.amount(row, "latitude_e7").raw,
        longitudeE7: try RowMapping.amount(row, "longitude_e7").raw)
    else { throw UnreadableValue(column: "latitude_e7") }
    self.init(
      id: try RowMapping.uuid(row, "id"), name: row["name"] ?? "", point: point,
      radiusMeters: try RowMapping.optionalInteger(row, "radius_m") ?? PlaceMark.defaultRadius,
      placeId: RowMapping.optionalUUID(row, "place_id"),
      categoryId: RowMapping.optionalUUID(row, "category_id"),
      enabled: try RowMapping.flag(row, "enabled", fallback: true))
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["id"] = id.uuidString
    container["name"] = name
    container["latitude_e7"] = point.latitudeE7
    container["longitude_e7"] = point.longitudeE7
    container["radius_m"] = radiusMeters
    container["place_id"] = placeId?.uuidString
    container["category_id"] = categoryId?.uuidString
    container["enabled"] = enabled ? 1 : 0
  }
}
