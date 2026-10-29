import AppCore
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

// Synthetic data only.

/// The update to schema 18 (`0018_purchases`) only adds: a database of the previous release keeps
/// every value, the new columns start empty, the new tables start empty, the lists survive the
/// round trip through the records, and the rows travel with the exchange between devices.
@Suite("The purchase tables come in without touching a value")
struct Migration0018Tests {
  private static let older = FilteredSchemaSource(upTo: "0017_attachments")
  private static let day = DateOnly(year: 2026, month: 10, day: 29)

  private static func temporaryURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("migration-0018-\(UUID().uuidString).sqlite")
  }

  private static func remove(_ url: URL) {
    for suffix in ["", "-wal", "-shm"] {
      try? FileManager.default.removeItem(atPath: url.path + suffix)
    }
  }

  @Test func aNewDatabaseHasTheColumnsEmptyAndTheTablesEmpty() throws {
    let stack = try TestSupport.makeStack()
    #expect(try stack.appliedMigrations().last == "0019_privacy")
    try stack.writer.read { (db: Database) throws in
      for table in ["wishes", "wish_prices", "shopping_items", "owned_items"] {
        #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") == 0, "\(table)")
      }
      let have = try db.columns(in: "transactions").map(\.name)
      for column in [
        "discount_e4", "regret", "regret_asked_on", "refund_waiting_until", "odometer_km",
      ] {
        #expect(have.contains(column), Comment(rawValue: column))
      }
      let people = try db.columns(in: "people").map(\.name)
      for column in ["birthday_month", "birthday_day", "birthday_year", "gift_budget_e4"] {
        #expect(people.contains(column), Comment(rawValue: column))
      }
    }
  }

  @Test func aDatabaseOfThePreviousReleaseKeepsEveryValueAndAddsNothingElse() throws {
    let url = Self.temporaryURL()
    defer { Self.remove(url) }
    let before: [String: TableContents]
    do {
      let old = try DatabaseStack(url: url, schema: Self.older)
      try old.writer.write { db in
        try db.execute(
          sql: """
            INSERT INTO transactions (id, kind, occurred_at, amount_e4, amount_rub_e4, note,
                                      created_at, updated_at)
            VALUES ('11111111-1111-4111-8111-111111111111', 'expense', '2026-10-20 10:00:00.000', 1000000, 1000000, 'Чайник',
                    '2026-10-20 10:00:00.000', '2026-10-20 10:00:00.000')
            """)
        try db.execute(
          sql: """
            INSERT INTO people (id, name, relation, aliases, archived)
            VALUES ('22222222-2222-4222-8222-222222222222', 'Мама', 'family', '', 0)
            """)
      }
      before = try old.writer.read { db in try TestSupport.contents(db) }
      try old.close()
    }
    #expect(
      try DatabaseStack.pendingMigrations(fileAt: url, schema: TestSupport.schemaSource)
        == ["0018_purchases", "0019_privacy"])
    let stack = try DatabaseStack(url: url, schema: TestSupport.schemaSource)
    defer { try? stack.close() }
    #expect(stack.applied.applied == 2)
    #expect(stack.applied.dataSteps.isEmpty)
    try stack.writer.read { (db: Database) throws in
      let after = try TestSupport.contents(db, columns: before.mapValues(\.columns))
      for (table, old) in before {
        #expect(after[table] == old, "\(table): every old value is the same byte for byte")
      }
      for column in [
        "discount_e4", "regret", "regret_asked_on", "refund_waiting_until", "odometer_km",
      ] {
        let filled = try Int.fetchOne(
          db, sql: "SELECT COUNT(*) FROM transactions WHERE \(column) IS NOT NULL")
        #expect(filled == 0, "transactions.\(column) starts empty")
      }
      let birthdays = try Int.fetchOne(
        db, sql: "SELECT COUNT(*) FROM people WHERE birthday_month IS NOT NULL")
      #expect(birthdays == 0)
      let keys = try String.fetchAll(
        db,
        sql: "SELECT key FROM settings WHERE key LIKE 'purchases.%' OR key LIKE 'regret.%' OR key LIKE 'fuel.%'"
      )
      #expect(keys.isEmpty, "no setting is written: every key reads its default")
    }
    let operation = try #require(
      try stack.writer.read { db in
        try CoreKit.Transaction.fetchOne(db, key: "11111111-1111-4111-8111-111111111111")
      })
    #expect(operation.discountE4 == nil && operation.regret == nil)
    #expect(operation.regretAskedOn == nil && operation.refundWaitingUntil == nil)
    #expect(operation.odometerKm == nil)
    let person = try #require(
      try stack.writer.read { db in
        try Person.fetchOne(db, key: "22222222-2222-4222-8222-222222222222")
      })
    #expect(person.birthday == nil && person.giftBudgetE4 == nil)
    #expect(
      try PurchaseSettingsRepository(writer: stack.writer).settings() == PurchaseSettings())
  }

  // MARK: - The records

  @Test func theColumnsOfAnOperationAndAPersonRoundTrip() throws {
    let stack = try TestSupport.makeStack()
    var operation = CoreKit.Transaction(
      kind: .expense, occurredAt: Date(timeIntervalSince1970: 1_800_000_000),
      amountE4: AmountE4(whole: 3_000))
    operation.discountE4 = AmountE4(whole: 200)
    operation.regret = .skip
    operation.regretAskedOn = Self.day
    operation.refundWaitingUntil = DateOnly(year: 2026, month: 11, day: 20)
    operation.odometerKm = 120_500
    let person = Person(
      name: "Брат", relation: .family, birthday: Birthday(month: 12, day: 31, year: nil),
      giftBudgetE4: AmountE4(whole: 7_000))
    try stack.writer.write { db in
      try operation.insert(db)
      try person.insert(db)
    }
    let back = try stack.writer.read { db in
      (
        try CoreKit.Transaction.fetchOne(db, key: operation.id.uuidString),
        try Person.fetchOne(db, key: person.id.uuidString)
      )
    }
    #expect(back.0?.discountE4 == operation.discountE4)
    #expect(back.0?.regret == .skip && back.0?.regretAskedOn == Self.day)
    #expect(back.0?.refundWaitingUntil == operation.refundWaitingUntil)
    #expect(back.0?.odometerKm == 120_500)
    #expect(back.1?.birthday == person.birthday && back.1?.giftBudgetE4 == person.giftBudgetE4)
  }

  @Test func anAnswerANewerBuildWritesReadsAsNone() throws {
    let stack = try TestSupport.makeStack()
    let id = "33333333-3333-4333-8333-333333333333"
    try stack.writer.write { db in
      try db.execute(
        sql: """
          INSERT INTO transactions (id, kind, occurred_at, amount_e4, amount_rub_e4, created_at,
                                    updated_at, regret)
          VALUES (?, 'expense', '2026-10-20 10:00:00.000', 10000, 10000, '2026-10-20 10:00:00.000',
                  '2026-10-20 10:00:00.000', 'maybe')
          """, arguments: [id])
    }
    let read = try stack.writer.read { db in try CoreKit.Transaction.fetchOne(db, key: id) }
    #expect(read != nil && read?.regret == nil)
  }

  @Test func aWishKeepsItsPriceHistoryAndLeavesWithoutIt() throws {
    let stack = try TestSupport.makeStack()
    let wishes = WishRepository(writer: stack.writer)
    let wish = Wish(
      name: "Кофемашина", priceE4: AmountE4(whole: 30_000), priority: 1, createdOn: Self.day)
    try wishes.insert(wish)
    #expect(try wishes.prices(of: wish.id).map(\.priceE4) == [AmountE4(whole: 30_000)])
    // The same price again adds nothing; a new one adds a row and becomes the price now.
    try wishes.notePrice(of: wish.id, AmountE4(whole: 30_000), on: Self.day)
    try wishes.notePrice(
      of: wish.id, AmountE4(whole: 27_500), on: DateOnly(year: 2026, month: 11, day: 3))
    #expect(try wishes.prices(of: wish.id).count == 2)
    #expect(try wishes.wish(id: wish.id)?.priceE4 == AmountE4(whole: 27_500))
    #expect(try wishes.wishes().count == 1)
    try wishes.delete(ids: [wish.id])
    #expect(try wishes.allPrices().isEmpty, "the prices go with their wish")
  }

  @Test func aBoughtWishLeavesTheListButStaysInTheTable() throws {
    let stack = try TestSupport.makeStack()
    let wishes = WishRepository(writer: stack.writer)
    let operation = CoreKit.Transaction(
      kind: .expense, occurredAt: Date(timeIntervalSince1970: 1_800_000_000),
      amountE4: AmountE4(whole: 100))
    try stack.writer.write { db in try operation.insert(db) }
    let wish = Wish(name: "Лампа", createdOn: Self.day)
    try wishes.insert(wish)
    try wishes.markBought(id: wish.id, by: operation.id, expectedE4: AmountE4(whole: 90))
    #expect(try wishes.wishes().isEmpty)
    #expect(try wishes.wishes(includeBought: true).first?.expectedE4 == AmountE4(whole: 90))
    #expect(try wishes.wish(boughtBy: operation.id)?.id == wish.id)
    // The operation really removed leaves the wish, no longer bought by anything.
    try stack.writer.write { db in
      try db.execute(sql: "DELETE FROM transactions WHERE id = ?", arguments: [operation.id.uuidString])
    }
    #expect(try wishes.wish(id: wish.id)?.boughtTransactionId == nil)
  }

  @Test func theShoppingListAndTheThingsKeepTheirOrderAndMarks() throws {
    let stack = try TestSupport.makeStack()
    let shopping = ShoppingRepository(writer: stack.writer)
    let milk = ShoppingItem(name: "Молоко", createdOn: Self.day, sort: 1)
    let bread = ShoppingItem(name: "Хлеб", createdOn: Self.day, sort: 2)
    try shopping.insert(milk)
    try shopping.insert(bread)
    try shopping.setDone(id: milk.id, true)
    #expect(try shopping.items().map(\.name) == ["Хлеб", "Молоко"], "the ticked go last")
    #expect(try shopping.items(includeDone: false).map(\.name) == ["Хлеб"])
    #expect(try shopping.clearDone() == 1)
    #expect(try shopping.items().count == 1)

    let things = OwnedItemRepository(writer: stack.writer)
    let bike = OwnedItem(name: "Велосипед", boughtOn: Self.day, priceE4: AmountE4(whole: 40_000))
    try things.insert(bike)
    try things.markSold(id: bike.id, on: DateOnly(year: 2027, month: 4, day: 1), by: nil)
    #expect(try things.item(id: bike.id)?.isSold == true)
    #expect(try things.items().count == 1)
  }

  // MARK: - The exchange

  @Test func everyWriteToTheNewTablesIsRecordedForTheExchange() throws {
    let device = try TestDevice("mac")
    try device.sql("DELETE FROM sync_outbox")
    try device.sql(
      "INSERT INTO wishes (id, name, created_on) VALUES ('w1', 'Лампа', '2026-10-29')")
    try device.sql(
      "INSERT INTO wish_prices (id, wish_id, on_date, price_e4) VALUES ('p1', 'w1', '2026-10-29', 5)")
    try device.sql(
      "INSERT INTO shopping_items (id, name, created_on) VALUES ('s1', 'Хлеб', '2026-10-29')")
    try device.sql("INSERT INTO owned_items (id, name) VALUES ('o1', 'Велосипед')")
    func queued() throws -> [String] {
      try device.stack.writer.read { db in
        try String.fetchAll(
          db,
          sql: "SELECT table_name || ':' || row_key FROM sync_outbox ORDER BY table_name, row_key")
      }
    }
    let all = ["owned_items:o1", "shopping_items:s1", "wish_prices:p1", "wishes:w1"]
    #expect(try queued() == all)
    try device.sql("DELETE FROM sync_outbox")
    try device.sql("UPDATE wishes SET note = 'x'")
    try device.sql("UPDATE wish_prices SET price_e4 = 6")
    try device.sql("UPDATE shopping_items SET done = 1")
    try device.sql("UPDATE owned_items SET note = 'x'")
    #expect(try queued() == all)
    try device.sql("DELETE FROM sync_outbox")
    try device.sql("DELETE FROM shopping_items")
    try device.sql("DELETE FROM owned_items")
    try device.sql("DELETE FROM wishes")
    #expect(try queued().contains("wishes:w1") && queued().contains("owned_items:o1"))
  }

  @Test func theRowsAndTheColumnsArriveEqualOnAnotherDevice() throws {
    let mac = try TestDevice("mac")
    let phone = try TestDevice("phone")
    let folder = InMemoryFolder()
    try mac.insertOperation("t1", note: "куртка")
    try mac.sql(
      """
      UPDATE transactions SET discount_e4 = 1000, regret = 'no', regret_asked_on = '2026-10-29',
        refund_waiting_until = '2026-11-12', odometer_km = 90000
      """)
    try mac.sql(
      "INSERT INTO wishes (id, name, created_on, bought_transaction_id) VALUES ('w1', 'Лампа', '2026-10-29', 't1')"
    )
    try mac.sql(
      "INSERT INTO wish_prices (id, wish_id, on_date, price_e4) VALUES ('p1', 'w1', '2026-10-29', 5)")
    try mac.sql(
      "INSERT INTO shopping_items (id, name, created_on) VALUES ('s1', 'Хлеб', '2026-10-29')")
    try mac.sql("INSERT INTO owned_items (id, name, sale_transaction_id) VALUES ('o1', 'Лампа', 't1')")
    _ = try mac.exchange.exchange(with: folder)
    _ = try phone.exchange.exchange(with: folder)
    for table in ["wishes", "wish_prices", "shopping_items", "owned_items"] {
      #expect(try phone.count(table) == 1, "\(table)")
    }
    #expect(try phone.books() == mac.books())
  }
}
