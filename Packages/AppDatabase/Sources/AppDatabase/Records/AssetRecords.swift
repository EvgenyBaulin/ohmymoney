import CoreKit
import Foundation
import GRDB

// The things valued by hand and their valuations (`Schema/0008_capital.sql`), mapped by hand
// like every other record (`RowMapping`).

/// A kind this build does not know reads as `other`, a currency left empty as rubles: one odd
/// cell must not stop the history from being read.
extension Asset: @retroactive FetchableRecord, @retroactive PersistableRecord {
  public static let databaseTableName = "assets"

  public init(row: Row) throws {
    self.init(
      id: try RowMapping.uuid(row, "id"),
      name: row["name"] ?? "",
      kind: (row["kind"] as String?).flatMap(AssetKind.init(rawValue:)) ?? .other,
      currency: RowMapping.currency(row, "currency") ?? .rub,
      note: row["note"],
      disposedOn: RowMapping.day(row, "disposed_on"),
      sort: try RowMapping.optionalInteger(row, "sort") ?? 0)
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["id"] = id.uuidString
    container["name"] = name
    container["kind"] = kind.rawValue
    container["currency"] = currency.code
    container["note"] = note
    container["disposed_on"] = disposedOn?.iso
    container["sort"] = sort
  }
}

extension AssetValuation: @retroactive FetchableRecord, @retroactive PersistableRecord {
  public static let databaseTableName = "asset_valuations"

  public init(row: Row) throws {
    self.init(
      id: try RowMapping.uuid(row, "id"),
      assetId: try RowMapping.uuid(row, "asset_id"),
      day: RowMapping.day(row, "day") ?? DateOnly(year: 1970, month: 1, day: 1),
      valueE4: try RowMapping.amount(row, "value_e4"),
      note: row["note"])
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["id"] = id.uuidString
    container["asset_id"] = assetId.uuidString
    container["day"] = day.iso
    container["value_e4"] = valueE4.raw
    container["note"] = note
  }
}
