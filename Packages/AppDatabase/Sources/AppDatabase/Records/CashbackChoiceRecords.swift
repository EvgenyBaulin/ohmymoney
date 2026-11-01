import CoreKit
import Foundation
import GRDB

// The bank's monthly choice of cashback categories (`Schema/0021_history_and_cashback_choice.sql`),
// mapped by hand like every other record (`RowMapping`).

/// A row whose bank or category does not read fails the read of that row (`UnreadableValue`):
/// the repository leaves it out, untouched in the database.
extension BankCategoryMapping: @retroactive FetchableRecord, @retroactive PersistableRecord {
  public static let databaseTableName = "bank_cashback_categories"

  public init(row: Row) throws {
    self.init(
      id: try RowMapping.uuid(row, "id"), bankId: try RowMapping.uuid(row, "bank_id"),
      label: row["label"] ?? "", categoryId: try RowMapping.uuid(row, "category_id"))
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["id"] = id.uuidString
    container["bank_id"] = bankId.uuidString
    container["label"] = label
    container["category_id"] = categoryId.uuidString
  }
}

/// A month or a percent that does not read fails the read of that row: an offer of no month or
/// of no percent says nothing.
extension CashbackOffer: @retroactive FetchableRecord, @retroactive PersistableRecord {
  public static let databaseTableName = "cashback_offers"

  public init(row: Row) throws {
    guard let month = RowMapping.month(row, "month") else {
      throw UnreadableValue(column: "month")
    }
    guard let stored = try RowMapping.optionalInteger(row, "percent_e4"),
      let percent = CashbackPercent(e4: Int64(stored))
    else { throw UnreadableValue(column: "percent_e4") }
    self.init(
      id: try RowMapping.uuid(row, "id"), accountId: try RowMapping.uuid(row, "payment_method_id"),
      cardId: RowMapping.optionalUUID(row, "card_id"), month: month, label: row["label"] ?? "",
      percent: percent, chosen: try RowMapping.flag(row, "chosen", fallback: false))
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["id"] = id.uuidString
    container["payment_method_id"] = accountId.uuidString
    container["card_id"] = cardId?.uuidString
    container["month"] = month.iso
    container["label"] = label
    container["percent_e4"] = percent.e4
    container["chosen"] = chosen
  }
}
