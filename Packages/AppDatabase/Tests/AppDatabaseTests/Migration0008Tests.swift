import AppCore
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

/// The update to the capital and the safety cushion (`0008_capital`) only adds: a database of
/// 1.6 keeps every value, every account and category reads as it did — not the cushion, not
/// essential —, there are no assets yet, and each new check refuses exactly what it promises to.
@Suite("The capital and the cushion come in without touching a value")
struct Migration0008Tests {
  // MARK: Helpers

  private enum Verdict: Equatable {
    case taken
    case refused
  }

  /// What SQLite says of the statement; nothing of it stays either way.
  private func verdict(
    _ stack: DatabaseStack, _ sql: String, _ arguments: StatementArguments = []
  ) throws -> Verdict {
    var result = Verdict.taken
    try stack.writer.writeWithoutTransaction { db in
      try db.inSavepoint {
        do {
          try db.execute(sql: sql, arguments: arguments)
        } catch let error as GRDB.DatabaseError where error.resultCode == .SQLITE_CONSTRAINT {
          result = .refused
        }
        return .rollback
      }
    }
    return result
  }

  private func takes(
    _ stack: DatabaseStack, _ sql: String, _ arguments: StatementArguments = []
  ) throws -> Bool {
    try verdict(stack, sql, arguments) == .taken
  }

  /// An insert of an asset, for `takes`.
  private func asset(
    id: String = UUID().uuidString, name: String = "Car", kind: String = "vehicle",
    currency: String = "RUB"
  ) -> (String, StatementArguments) {
    (
      "INSERT INTO assets (id, name, kind, currency) VALUES (?, ?, ?, ?)",
      [id, name, kind, currency]
    )
  }

  private func insertAsset(_ stack: DatabaseStack, id: String) throws {
    try stack.writer.write { db in
      try db.execute(
        sql: "INSERT INTO assets (id, name) VALUES (?, 'Car')", arguments: [id])
    }
  }

  // MARK: 1. A new database

  @Test func aNewDatabaseHasTheColumnsAndTablesWithTheirDefaults() throws {
    let stack = try TestSupport.makeStack()
    #expect(try stack.appliedMigrations().last == "0014_import_year_questions_subscriptions")
    #expect(try stack.appliedMigrations().count == 14)
    #expect(stack.applied.onDisk == 14)
    let accountId = UUID().uuidString
    let categoryId = UUID().uuidString
    let assetId = UUID().uuidString
    let valuationId = UUID().uuidString
    try stack.writer.write { db in
      try db.execute(
        sql: """
          INSERT INTO payment_methods (id, name) VALUES (?, 'Card');
          INSERT INTO categories (id, kind, name) VALUES (?, 'expense', 'Food');
          INSERT INTO assets (id, name) VALUES (?, 'Laptop');
          INSERT INTO asset_valuations (id, asset_id, day, value_e4)
            VALUES (?, ?, '2026-10-11', 1000000);
          """, arguments: [accountId, categoryId, assetId, valuationId, assetId])
    }
    try stack.writer.read { (db: Database) throws in
      #expect(
        try Int64.fetchOne(
          db, sql: "SELECT cushion FROM payment_methods WHERE id = ?", arguments: [accountId])
          == 0)
      #expect(
        try Row.fetchOne(
          db, sql: "SELECT essential FROM categories WHERE id = ?", arguments: [categoryId])?[
            "essential"] as DatabaseValue? == .null)
      let row = try #require(
        try Row.fetchOne(db, sql: "SELECT * FROM assets WHERE id = ?", arguments: [assetId]))
      #expect(row["kind"] as String? == "other")
      #expect(row["currency"] as String? == "RUB")
      #expect(row["sort"] as Int64? == 0)
      #expect((row["note"] as DatabaseValue).isNull)
      #expect((row["disposed_on"] as DatabaseValue).isNull)
      // The records read them as nothing marked.
      #expect(try PaymentMethod.fetchOne(db, key: accountId)?.cushion == false)
      #expect(try CoreKit.Category.fetchOne(db, key: categoryId)?.essential == nil)
      let read = try #require(try Asset.fetchOne(db, key: assetId))
      #expect(read.kind == .other && read.currency == .rub && read.disposedOn == nil)
      let valuation = try #require(try AssetValuation.fetchOne(db, key: valuationId))
      #expect(valuation.valueE4 == AmountE4(whole: 100))
      #expect(valuation.day == DateOnly(year: 2026, month: 10, day: 11))
      let indexes = try String.fetchAll(
        db,
        sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'asset_valuations'"
      )
      #expect(indexes.contains("idx_asset_valuations_asset"))
    }
  }

  // MARK: 2. From 1.6

  /// A database of 1.6 (`0007_debts_and_deposits`) is updated and keeps every value it had,
  /// byte for byte; the new columns start empty or false and no row is added.
  @Test func aDatabaseOfTheVersionBeforeKeepsEveryValue() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("migration-0008-\(UUID().uuidString).sqlite")
    defer {
      for suffix in ["", "-wal", "-shm"] {
        try? FileManager.default.removeItem(atPath: url.path + suffix)
      }
    }
    let older = try DatabaseStack(
      url: url, schema: FilteredSchemaSource(upTo: "0007_debts_and_deposits"))
    #expect(try older.appliedMigrations().last == "0007_debts_and_deposits")
    let card = PaymentMethod(name: "Card", kind: .card, currency: .rub)
    let savings = PaymentMethod(
      name: "Savings", kind: .account, currency: .rub,
      interest: DepositTerms(rate: 16, period: .monthly))
    let food = CoreKit.Category(kind: .expense, name: "Food", quality: .neutral)
    let market = CoreKit.Category(parentId: food.id, kind: .expense, name: "Market")
    let salary = CoreKit.Category(kind: .income, name: "Salary")
    try older.writer.write { db in
      for account in [card, savings] { try LegacyWriter.insert(account, db: db) }
      for category in [food, market, salary] { try LegacyWriter.insert(category, db: db) }
      try db.execute(
        sql: "INSERT INTO settings (key, value) VALUES ('currencies.default', 'RUB')")
    }
    let before = try older.writer.read { db in try TestSupport.contents(db) }
    #expect(before["assets"] == nil)
    try older.close()

    let stack = try DatabaseStack(url: url, schema: TestSupport.schemaSource)
    defer { try? stack.close() }
    #expect(try stack.appliedMigrations().last == "0014_import_year_questions_subscriptions")
    #expect(stack.applied.applied == 7)
    try stack.writer.read { (db: Database) throws in
      let after = try TestSupport.contents(db, columns: before.mapValues(\.columns))
      for (table, old) in before {
        #expect(after[table] == old, "\(table) changed")
      }
      #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
      #expect(
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM payment_methods WHERE cushion <> 0") == 0)
      #expect(
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM categories WHERE essential IS NOT NULL")
          == 0)
      #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM assets") == 0)
      #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset_valuations") == 0)
      #expect(
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM settings WHERE key LIKE 'cushion.%'") == 0)
      // Every account and category reads as it did.
      #expect(try PaymentMethod.fetchAll(db).allSatisfy { !$0.cushion })
      #expect(try CoreKit.Category.fetchAll(db).allSatisfy { $0.essential == nil })
      let dataset = try DatasetRepository.dataset(db, version: 0)
      #expect(dataset.assets.isEmpty && dataset.assetValuations.isEmpty)
      #expect(dataset.capitalSettings == .standard)
    }
    #expect(try DatabaseStack.check(fileAt: url, schema: TestSupport.schemaSource) == .sound)
  }

  // MARK: 3. The checks

  @Test func theCushionIsZeroOrOne() throws {
    let stack = try TestSupport.makeStack()
    for value in [0, 1] {
      #expect(
        try takes(
          stack, "INSERT INTO payment_methods (id, name, cushion) VALUES (?, ?, ?)",
          [UUID().uuidString, "A \(value)", value]))
    }
    for value: DatabaseValueConvertible? in [2, -1, nil, "yes"] {
      #expect(
        !(try takes(
          stack, "INSERT INTO payment_methods (id, name, cushion) VALUES (?, ?, ?)",
          [UUID().uuidString, "B", value])), "\(String(describing: value))")
    }
  }

  @Test func onlyAnExpenseCategoryIsEssential() throws {
    let stack = try TestSupport.makeStack()
    let insert = "INSERT INTO categories (id, kind, name, essential) VALUES (?, ?, ?, ?)"
    #expect(try takes(stack, insert, [UUID().uuidString, "expense", "Food", 1]))
    #expect(try takes(stack, insert, [UUID().uuidString, "expense", "Cafe", 0]))
    #expect(try takes(stack, insert, [UUID().uuidString, "expense", "Other", nil]))
    #expect(try takes(stack, insert, [UUID().uuidString, "income", "Salary", 0]))
    #expect(try takes(stack, insert, [UUID().uuidString, "income", "Bonus", nil]))
    #expect(!(try takes(stack, insert, [UUID().uuidString, "income", "Gift", 1])))
    #expect(!(try takes(stack, insert, [UUID().uuidString, "expense", "Rent", 2])))
    #expect(!(try takes(stack, insert, [UUID().uuidString, "expense", "Fuel", -1])))
  }

  @Test func anAssetHasANameAKindAndACurrencyCode() throws {
    let stack = try TestSupport.makeStack()
    for kind in AssetKind.allCases {
      let (sql, arguments) = asset(kind: kind.rawValue)
      #expect(try takes(stack, sql, arguments), "\(kind)")
    }
    for (name, kind, currency) in [
      ("", "vehicle", "RUB"), ("   ", "vehicle", "RUB"), ("Car", "boat", "RUB"),
      ("Car", "vehicle", "rub"), ("Car", "vehicle", "RU"), ("Car", "vehicle", "RUBL"),
      ("Car", "vehicle", "R1B"), ("Car", "vehicle", ""),
    ] {
      let (sql, arguments) = asset(name: name, kind: kind, currency: currency)
      #expect(!(try takes(stack, sql, arguments)), "\(name) \(kind) \(currency)")
    }
    #expect(
      !(try takes(stack, "INSERT INTO assets (id, name) VALUES (?, NULL)", [UUID().uuidString])))
  }

  @Test func aValuationIsNeverBelowZeroAndOnePerDay() throws {
    let stack = try TestSupport.makeStack()
    let assetId = UUID().uuidString
    try insertAsset(stack, id: assetId)
    let insert = "INSERT INTO asset_valuations (id, asset_id, day, value_e4) VALUES (?, ?, ?, ?)"
    #expect(try takes(stack, insert, [UUID().uuidString, assetId, "2026-10-01", 0]))
    #expect(!(try takes(stack, insert, [UUID().uuidString, assetId, "2026-10-01", -1])))
    #expect(!(try takes(stack, insert, [UUID().uuidString, assetId, "2026-10-01", nil])))
    #expect(!(try takes(stack, insert, [UUID().uuidString, assetId, nil, 10])))
    // Of an asset that is not there.
    #expect(!(try takes(stack, insert, [UUID().uuidString, UUID().uuidString, "2026-10-01", 10])))
    // One per asset and day: a second of the same day is refused, another day or asset is not.
    try stack.writer.write { db in
      try db.execute(sql: insert, arguments: [UUID().uuidString, assetId, "2026-10-01", 100])
    }
    #expect(!(try takes(stack, insert, [UUID().uuidString, assetId, "2026-10-01", 200])))
    #expect(try takes(stack, insert, [UUID().uuidString, assetId, "2026-10-02", 200]))
    let other = UUID().uuidString
    try insertAsset(stack, id: other)
    #expect(try takes(stack, insert, [UUID().uuidString, other, "2026-10-01", 200]))
  }

  @Test func deletingAnAssetDeletesItsValuations() throws {
    let stack = try TestSupport.makeStack()
    let car = UUID().uuidString
    let flat = UUID().uuidString
    try insertAsset(stack, id: car)
    try insertAsset(stack, id: flat)
    try stack.writer.write { db in
      try db.execute(
        sql: """
          INSERT INTO asset_valuations (id, asset_id, day, value_e4) VALUES
            (?, ?, '2026-01-01', 10), (?, ?, '2026-02-01', 20), (?, ?, '2026-01-01', 30)
          """,
        arguments: [
          UUID().uuidString, car, UUID().uuidString, car, UUID().uuidString, flat,
        ])
      try db.execute(sql: "DELETE FROM assets WHERE id = ?", arguments: [car])
    }
    try stack.writer.read { (db: Database) throws in
      #expect(try String.fetchAll(db, sql: "SELECT asset_id FROM asset_valuations") == [flat])
    }
  }

  // MARK: 4. The records

  @Test func theRecordsRoundTripEveryNewColumn() throws {
    let stack = try TestSupport.makeStack()
    let account = PaymentMethod(name: "Savings", kind: .account, cushion: true)
    let food = CoreKit.Category(kind: .expense, name: "Food", essential: true)
    let cafe = CoreKit.Category(parentId: food.id, kind: .expense, name: "Cafe", essential: false)
    let car = Asset(
      name: "Car", kind: .vehicle, currency: .eur, note: "bought\nused",
      disposedOn: DateOnly(year: 2027, month: 1, day: 31), sort: 3)
    let valuation = AssetValuation(
      assetId: car.id, day: DateOnly(year: 2026, month: 10, day: 31),
      valueE4: AmountE4(raw: 123_456_789), note: "dealer")
    try stack.writer.write { db in
      try account.insert(db)
      try food.insert(db)
      try cafe.insert(db)
      try car.insert(db)
      try valuation.insert(db)
    }
    try stack.writer.read { (db: Database) throws in
      #expect(try PaymentMethod.fetchOne(db, key: account.id.uuidString) == account)
      #expect(try CoreKit.Category.fetchOne(db, key: food.id.uuidString) == food)
      #expect(try CoreKit.Category.fetchOne(db, key: cafe.id.uuidString) == cafe)
      #expect(try Asset.fetchOne(db, key: car.id.uuidString) == car)
      #expect(try AssetValuation.fetchOne(db, key: valuation.id.uuidString) == valuation)
      let dataset = try DatasetRepository.dataset(db, version: 0)
      #expect(dataset.assets == [car])
      #expect(dataset.assetValuations == [valuation])
    }
  }

  /// A value only a hand edit leaves — a kind this build does not know, a mark that is not a
  /// number — reads as nothing said, never stopping the history from being read.
  @Test func aValueOnlyAHandEditLeavesReadsAsNothing() throws {
    let stack = try TestSupport.makeStack()
    let assetId = UUID().uuidString
    let categoryId = UUID().uuidString
    try stack.writer.writeWithoutTransaction { db in
      try db.execute(sql: "PRAGMA ignore_check_constraints = ON")
      try db.execute(
        sql: """
          INSERT INTO assets (id, name, kind, currency) VALUES (?, 'Boat', 'boat', ' ');
          INSERT INTO categories (id, kind, name, essential) VALUES (?, 'expense', 'Odd', 'maybe');
          """, arguments: [assetId, categoryId])
      try db.execute(sql: "PRAGMA ignore_check_constraints = OFF")
    }
    try stack.writer.read { (db: Database) throws in
      let asset = try #require(try Asset.fetchOne(db, key: assetId))
      #expect(asset.kind == .other)
      #expect(asset.currency == .rub)
      #expect(try CoreKit.Category.fetchOne(db, key: categoryId)?.essential == nil)
    }
  }

  /// The settings of the cushion are read with the dataset; what is written reads back.
  @Test func theSettingsOfTheCushionComeWithTheDataset() throws {
    let stack = try TestSupport.makeStack()
    let settings = CapitalSettings(
      targetMonths: 6, targetMonth: MonthKey(year: 2027, month: 3), outOfFreeMoney: true,
      historyMonths: 9)
    _ = try PlanningRepository(writer: stack.writer).apply(
      PlanningChange(settings: settings.storedValues))
    let dataset = try stack.writer.read { db in try DatasetRepository.dataset(db, version: 0) }
    #expect(dataset.capitalSettings == settings)
  }
}
