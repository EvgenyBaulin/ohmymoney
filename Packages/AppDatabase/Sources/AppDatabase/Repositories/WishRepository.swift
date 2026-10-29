import CoreKit
import Foundation
import GRDB

/// «Хочу купить» (`wishes`) and the history of the price of each (`wish_prices`)
/// (`Schema/0018_purchases.sql`).
public struct WishRepository: Sendable {
  private let writer: any DatabaseWriter

  public init(writer: any DatabaseWriter) {
    self.writer = writer
  }

  // MARK: Wishes

  /// The wishes in the owner's order (`sort`, then the most wanted, then the oldest). A row this
  /// build can not read is left out and stays in the database. Bought and archived wishes only
  /// when asked.
  public func wishes(includeBought: Bool = false, includeArchived: Bool = false) throws -> [Wish] {
    try writer.read { db in
      try Self.wishRows(db, sql: "SELECT * FROM wishes ORDER BY sort, priority, created_on, id")
        .filter { (includeBought || !$0.isBought) && (includeArchived || !$0.archived) }
    }
  }

  public func wish(id: UUID) throws -> Wish? {
    try writer.read { db in
      try Self.wishRows(db, sql: "SELECT * FROM wishes WHERE id = ?", arguments: [id.uuidString])
        .first
    }
  }

  /// The wish an operation bought, if any.
  public func wish(boughtBy transactionId: UUID) throws -> Wish? {
    try writer.read { db in
      try Self.wishRows(
        db, sql: "SELECT * FROM wishes WHERE bought_transaction_id = ?",
        arguments: [transactionId.uuidString]
      ).first
    }
  }

  /// Adds a wish; its first price, when it has one, is noted on the day it was added.
  public func insert(_ wish: Wish) throws {
    try writer.write { db in
      try wish.insert(db)
      if let price = wish.priceE4 {
        try WishPrice(wishId: wish.id, onDate: wish.createdOn, priceE4: price).insert(db)
      }
    }
  }

  public func update(_ wish: Wish) throws {
    try writer.write { db in try wish.update(db) }
  }

  /// Notes the new price of a wish on a day and makes it the price now. The same price as the
  /// last one noted adds no row.
  @discardableResult
  public func notePrice(of wishId: UUID, _ price: AmountE4, on day: DateOnly) throws -> Bool {
    try writer.write { db in
      guard var wish = try Self.wishRows(
        db, sql: "SELECT * FROM wishes WHERE id = ?", arguments: [wishId.uuidString]
      ).first else { return false }
      let last = try Self.priceRows(
        db, sql: "SELECT * FROM wish_prices WHERE wish_id = ? ORDER BY on_date DESC, rowid DESC",
        arguments: [wishId.uuidString]
      ).first
      if last?.priceE4 != price {
        try WishPrice(wishId: wishId, onDate: day, priceE4: price).insert(db)
      }
      wish.priceE4 = price
      try wish.update(db)
      return true
    }
  }

  /// Marks the wish as bought by an operation, with the price the owner expected.
  public func markBought(
    id: UUID, by transactionId: UUID, expectedE4: AmountE4?
  ) throws {
    try writer.write { db in
      try db.execute(
        sql: "UPDATE wishes SET bought_transaction_id = ?, expected_e4 = ? WHERE id = ?",
        arguments: [transactionId.uuidString, expectedE4?.raw, id.uuidString])
    }
  }

  /// Deletes the wishes and, with them, their prices.
  public func delete(ids: [UUID]) throws {
    try writer.write { db in
      for id in ids { _ = try Wish.deleteOne(db, key: id.uuidString) }
    }
  }

  // MARK: Prices

  /// The prices noted for a wish, the oldest first.
  public func prices(of wishId: UUID) throws -> [WishPrice] {
    try writer.read { db in
      try Self.priceRows(
        db, sql: "SELECT * FROM wish_prices WHERE wish_id = ? ORDER BY on_date, rowid",
        arguments: [wishId.uuidString])
    }
  }

  /// Every price of every wish, the oldest first.
  public func allPrices() throws -> [WishPrice] {
    try writer.read { db in
      try Self.priceRows(db, sql: "SELECT * FROM wish_prices ORDER BY wish_id, on_date, rowid")
    }
  }

  public func deletePrice(id: UUID) throws {
    _ = try writer.write { db in try WishPrice.deleteOne(db, key: id.uuidString) }
  }

  private static func wishRows(
    _ db: Database, sql: String, arguments: StatementArguments = StatementArguments()
  ) throws -> [Wish] {
    try Row.fetchAll(db, sql: sql, arguments: arguments).compactMap { try? Wish(row: $0) }
  }

  private static func priceRows(
    _ db: Database, sql: String, arguments: StatementArguments = StatementArguments()
  ) throws -> [WishPrice] {
    try Row.fetchAll(db, sql: sql, arguments: arguments).compactMap { try? WishPrice(row: $0) }
  }
}

/// The shopping list (`shopping_items`), the second list next to the wishes.
public struct ShoppingRepository: Sendable {
  private let writer: any DatabaseWriter

  public init(writer: any DatabaseWriter) {
    self.writer = writer
  }

  /// The lines in the owner's order; the ticked ones only when asked.
  public func items(includeDone: Bool = true) throws -> [ShoppingItem] {
    try writer.read { db in
      try Row.fetchAll(db, sql: "SELECT * FROM shopping_items ORDER BY done, sort, created_on, id")
        .compactMap { try? ShoppingItem(row: $0) }
        .filter { includeDone || !$0.done }
    }
  }

  public func insert(_ item: ShoppingItem) throws {
    try writer.write { db in try item.insert(db) }
  }

  public func update(_ item: ShoppingItem) throws {
    try writer.write { db in try item.update(db) }
  }

  public func setDone(id: UUID, _ done: Bool) throws {
    try writer.write { db in
      try db.execute(
        sql: "UPDATE shopping_items SET done = ? WHERE id = ?", arguments: [done, id.uuidString])
    }
  }

  public func delete(ids: [UUID]) throws {
    try writer.write { db in
      for id in ids { _ = try ShoppingItem.deleteOne(db, key: id.uuidString) }
    }
  }

  /// Removes every ticked line; returns how many went.
  @discardableResult
  public func clearDone() throws -> Int {
    try writer.write { db in
      try db.execute(sql: "DELETE FROM shopping_items WHERE done = 1")
      return db.changesCount
    }
  }
}

/// The things outside the capital (`owned_items`).
public struct OwnedItemRepository: Sendable {
  private let writer: any DatabaseWriter

  public init(writer: any DatabaseWriter) {
    self.writer = writer
  }

  /// The things, the most recently bought first; archived ones only when asked.
  public func items(includeArchived: Bool = false) throws -> [OwnedItem] {
    try writer.read { db in
      try Row.fetchAll(
        db, sql: "SELECT * FROM owned_items ORDER BY bought_on DESC, name, id"
      ).compactMap { try? OwnedItem(row: $0) }
        .filter { includeArchived || !$0.archived }
    }
  }

  public func item(id: UUID) throws -> OwnedItem? {
    try writer.read { db in
      try Row.fetchAll(
        db, sql: "SELECT * FROM owned_items WHERE id = ?", arguments: [id.uuidString]
      ).compactMap { try? OwnedItem(row: $0) }.first
    }
  }

  public func insert(_ item: OwnedItem) throws {
    try writer.write { db in try item.insert(db) }
  }

  public func update(_ item: OwnedItem) throws {
    try writer.write { db in try item.update(db) }
  }

  /// Marks the thing as sold on a day, by the operation that brought the money in, if there is one.
  public func markSold(id: UUID, on day: DateOnly, by transactionId: UUID?) throws {
    try writer.write { db in
      try db.execute(
        sql: "UPDATE owned_items SET sold_on = ?, sale_transaction_id = ? WHERE id = ?",
        arguments: [day.iso, transactionId?.uuidString, id.uuidString])
    }
  }

  public func delete(ids: [UUID]) throws {
    try writer.write { db in
      for id in ids { _ = try OwnedItem.deleteOne(db, key: id.uuidString) }
    }
  }
}

/// The settings of the purchases (keys of the `settings` table).
public struct PurchaseSettingsRepository: Sendable {
  private let writer: any DatabaseWriter

  public init(writer: any DatabaseWriter) {
    self.writer = writer
  }

  public func settings() throws -> PurchaseSettings {
    try writer.read { db in
      PurchaseSettings(
        storedValues: try SettingsRepository.values(of: PurchaseSettings.storageKeys, db: db))
    }
  }

  public func save(_ settings: PurchaseSettings) throws {
    try writer.write { db in
      for (key, value) in settings.storedValues {
        try SettingsRepository.set(key, to: value, in: db)
      }
    }
  }
}
