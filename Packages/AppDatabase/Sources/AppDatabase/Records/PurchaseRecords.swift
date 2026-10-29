import CoreKit
import Foundation
import GRDB

// The wishes, their prices, the shopping list and the things outside the capital
// (`Schema/0018_purchases.sql`), mapped by hand like every other record (`RowMapping`).

/// A price that does not read is none: one damaged cell must not stop the list from being read.
private func readable(_ row: Row, _ column: String) -> AmountE4? {
  (try? RowMapping.optionalAmount(row, column)) ?? nil
}

extension Wish: @retroactive FetchableRecord, @retroactive PersistableRecord {
  public static let databaseTableName = "wishes"

  public init(row: Row) throws {
    self.init(
      id: try RowMapping.uuid(row, "id"), name: row["name"] ?? "",
      priceE4: readable(row, "price_e4"),
      currency: RowMapping.currency(row, "currency") ?? .rub,
      priority: (try? RowMapping.optionalInteger(row, "priority")).flatMap { $0 } ?? 0,
      url: row["url"], note: row["note"],
      createdOn: RowMapping.day(row, "created_on") ?? DateOnly(year: 1970, month: 1, day: 1),
      boughtTransactionId: RowMapping.optionalUUID(row, "bought_transaction_id"),
      expectedE4: readable(row, "expected_e4"),
      archived: try RowMapping.flag(row, "archived", fallback: false),
      sort: (try? RowMapping.optionalInteger(row, "sort")).flatMap { $0 } ?? 0)
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["id"] = id.uuidString
    container["name"] = name
    container["price_e4"] = priceE4?.raw
    container["currency"] = currency.code
    container["priority"] = priority
    container["url"] = url
    container["note"] = note
    container["created_on"] = createdOn.iso
    container["bought_transaction_id"] = boughtTransactionId?.uuidString
    container["expected_e4"] = expectedE4?.raw
    container["archived"] = archived
    container["sort"] = sort
  }
}

/// A row without a readable price or day fails the read of that row (`UnreadableValue`): a price
/// of nothing on no day says nothing. The repository reads rows one by one and leaves it out,
/// untouched in the database.
extension WishPrice: @retroactive FetchableRecord, @retroactive PersistableRecord {
  public static let databaseTableName = "wish_prices"

  public init(row: Row) throws {
    guard let day = RowMapping.day(row, "on_date") else { throw UnreadableValue(column: "on_date") }
    guard let price = try RowMapping.optionalAmount(row, "price_e4") else {
      throw UnreadableValue(column: "price_e4")
    }
    self.init(
      id: try RowMapping.uuid(row, "id"), wishId: try RowMapping.uuid(row, "wish_id"),
      onDate: day, priceE4: price)
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["id"] = id.uuidString
    container["wish_id"] = wishId.uuidString
    container["on_date"] = onDate.iso
    container["price_e4"] = priceE4.raw
  }
}

extension ShoppingItem: @retroactive FetchableRecord, @retroactive PersistableRecord {
  public static let databaseTableName = "shopping_items"

  public init(row: Row) throws {
    self.init(
      id: try RowMapping.uuid(row, "id"), name: row["name"] ?? "", note: row["note"],
      done: try RowMapping.flag(row, "done", fallback: false),
      createdOn: RowMapping.day(row, "created_on") ?? DateOnly(year: 1970, month: 1, day: 1),
      sort: (try? RowMapping.optionalInteger(row, "sort")).flatMap { $0 } ?? 0)
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["id"] = id.uuidString
    container["name"] = name
    container["note"] = note
    container["done"] = done
    container["created_on"] = createdOn.iso
    container["sort"] = sort
  }
}

extension OwnedItem: @retroactive FetchableRecord, @retroactive PersistableRecord {
  public static let databaseTableName = "owned_items"

  public init(row: Row) throws {
    self.init(
      id: try RowMapping.uuid(row, "id"), name: row["name"] ?? "",
      boughtOn: RowMapping.day(row, "bought_on"), priceE4: readable(row, "price_e4"),
      currency: RowMapping.currency(row, "currency") ?? .rub,
      tagId: RowMapping.optionalUUID(row, "tag_id"), soldOn: RowMapping.day(row, "sold_on"),
      saleTransactionId: RowMapping.optionalUUID(row, "sale_transaction_id"), note: row["note"],
      archived: try RowMapping.flag(row, "archived", fallback: false))
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["id"] = id.uuidString
    container["name"] = name
    container["bought_on"] = boughtOn?.iso
    container["price_e4"] = priceE4?.raw
    container["currency"] = currency.code
    container["tag_id"] = tagId?.uuidString
    container["sold_on"] = soldOn?.iso
    container["sale_transaction_id"] = saleTransactionId?.uuidString
    container["note"] = note
    container["archived"] = archived
  }
}
