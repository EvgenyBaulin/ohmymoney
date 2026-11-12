import AppCore
import CoreCSV
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

// Synthetic data only.

/// The update to someone else's card (`0022_borrowed_card`) only adds: a database of the previous
/// schema keeps every value, every account it finds stays the owner's own, and the new fields
/// travel through the records, the CSV and the exchange.
///
/// The previous schema is whatever comes before this file, so the test reads the same whether
/// or not another migration lands between it and 0021.
@Suite("Schema 22 comes in without touching a value")
struct Migration0022Tests {
  static let name = "0022_borrowed_card"

  private static var older: FilteredSchemaSource {
    let before = TestSupport.migrationNames.filter { $0 < name }
    return FilteredSchemaSource(upTo: before.last ?? "")
  }

  private static func temporaryURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("migration-0022-\(UUID().uuidString).sqlite")
  }

  private static func remove(_ url: URL) {
    for suffix in ["", "-wal", "-shm"] {
      try? FileManager.default.removeItem(atPath: url.path + suffix)
    }
  }

  @Test func aNewDatabaseHasTheColumns() throws {
    let stack = try TestSupport.makeStack()
    #expect(try stack.appliedMigrations().contains(Self.name))
    try stack.writer.read { (db: Database) throws in
      let columns = try db.columns(in: "payment_methods").map(\.name)
      for column in ["borrowed", "borrowed_person_id", "borrowed_income_category_id"] {
        #expect(columns.contains(column), "\(column)")
      }
    }
  }

  @Test func aDatabaseOfThePreviousSchemaKeepsEveryValue() throws {
    let url = Self.temporaryURL()
    defer { Self.remove(url) }
    let before: [String: TableContents]
    do {
      let old = try DatabaseStack(url: url, schema: Self.older)
      try old.writer.write { db in
        try db.execute(
          sql: """
            INSERT INTO payment_methods (id, name, kind, is_default, archived)
            VALUES ('11111111-1111-4111-8111-111111111111', 'Карта', 'card', 1, 0)
            """)
      }
      before = try old.writer.read { db in try TestSupport.contents(db) }
      try old.close()
    }
    #expect(
      try DatabaseStack.pendingMigrations(fileAt: url, schema: TestSupport.schemaSource)
        == TestSupport.migrationNames.filter { $0 >= Self.name })
    let stack = try DatabaseStack(url: url, schema: TestSupport.schemaSource)
    defer { try? stack.close() }
    #expect(stack.applied.dataSteps.isEmpty)
    try stack.writer.read { (db: Database) throws in
      let after = try TestSupport.contents(db, columns: before.mapValues(\.columns))
      for (table, old) in before {
        #expect(after[table] == old, "\(table): every old value is the same byte for byte")
      }
    }
    let account = try #require(
      try stack.writer.read { db in
        try PaymentMethod.fetchOne(db, key: "11111111-1111-4111-8111-111111111111")
      })
    #expect(account.borrowed == nil, "an account the update finds stays the owner's own")
    #expect(account.hasBalance)
  }

  @Test func theNewFieldsRoundTripThroughTheRecords() async throws {
    let stack = try TestSupport.makeStack()
    let person = Person(name: "Папа")
    let income = CoreKit.Category(kind: .income, name: "Помощь семьи")
    let card = PaymentMethod(
      name: "Карта папы",
      borrowed: BorrowedCardTerms(personId: person.id, incomeCategoryId: income.id))
    let unsaid = PaymentMethod(name: "Корпоративная", borrowed: BorrowedCardTerms())
    let own = PaymentMethod(name: "Моя")
    try await stack.writer.write { db in
      try person.insert(db)
      try income.insert(db)
      try card.insert(db)
      try unsaid.insert(db)
      try own.insert(db)
    }
    try await stack.writer.read { (db: Database) throws in
      #expect(try PaymentMethod.fetchOne(db, key: card.id.uuidString) == card)
      #expect(try PaymentMethod.fetchOne(db, key: unsaid.id.uuidString) == unsaid)
      #expect(try PaymentMethod.fetchOne(db, key: own.id.uuidString) == own)
    }
    let dataset = try await DatasetRepository(writer: stack.writer).load(version: 1)
    #expect(dataset.paymentMethods.first { $0.id == card.id }?.isBorrowed == true)
    #expect(dataset.paymentMethods.first { $0.id == own.id }?.isBorrowed == false)
  }

  @Test func aReferenceThatDoesNotReadIsNoneAndAZeroFlagIsTheOwnersOwn() throws {
    let stack = try TestSupport.makeStack()
    let card = PaymentMethod(name: "Карта")
    let zero = PaymentMethod(name: "Ноль")
    try stack.writer.write { db in
      try card.insert(db)
      try zero.insert(db)
      try db.execute(
        sql: """
          UPDATE payment_methods SET borrowed = 1, borrowed_person_id = 'not an id',
            borrowed_income_category_id = ''
          WHERE id = ?
          """, arguments: [card.id.uuidString])
      try db.execute(
        sql: "UPDATE payment_methods SET borrowed = 0 WHERE id = ?",
        arguments: [zero.id.uuidString])
    }
    let read = try #require(
      try stack.writer.read { db in try PaymentMethod.fetchOne(db, key: card.id.uuidString) })
    #expect(read.borrowed == BorrowedCardTerms())
    let readZero = try #require(
      try stack.writer.read { db in try PaymentMethod.fetchOne(db, key: zero.id.uuidString) })
    #expect(readZero.borrowed == nil)
  }

  @Test func theCSVCarriesTheNewColumnsLastAndTheFilesStayFiftyThree() throws {
    #expect(
      Array(ExportTables.paymentMethods.columns.suffix(3))
        == ["borrowed", "borrowed_person_id", "borrowed_income_category_id"])
    #expect(ExportTables.all.count == 55)
    let person = UUID()
    let category = UUID()
    let card = PaymentMethod(
      name: "Карта папы",
      borrowed: BorrowedCardTerms(personId: person, incomeCategoryId: category))
    let row = ExportTables.row(card)
    #expect(row.count == ExportTables.paymentMethods.columns.count)
    #expect(Array(row.suffix(3)) == ["true", person.uuidString, category.uuidString])
    #expect(Array(ExportTables.row(PaymentMethod(name: "Моя")).suffix(3)) == ["false", "", ""])
    #expect(!ExportTables.paymentMethods.columns.contains { $0.hasSuffix("_e4") })
  }

  @Test func theNewColumnsTravelWithTheAccount() throws {
    #expect(SyncTables.followed["payment_methods"] == "id")
  }
}
