import AppCore
import CoreCSV
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

// Synthetic data only: drives of the form 9999…, made-up sums.

/// The update to the numbers of a receipt and the English names of the categories
/// (`0023_receipt_numbers_and_category_english`) only adds: a database of the previous schema keeps
/// every value, and the new fields travel through the records, the CSV and the exchange.
///
/// The previous schema is whatever comes before this file, so the test reads the same whether
/// or not another migration lands between it and 0022.
@Suite("Schema 23 comes in without touching a value")
struct Migration0023Tests {
  static let name = "0023_receipt_numbers_and_category_english"

  private static var older: FilteredSchemaSource {
    let before = TestSupport.migrationNames.filter { $0 < name }
    return FilteredSchemaSource(upTo: before.last ?? "")
  }

  private static func temporaryURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("migration-0023-\(UUID().uuidString).sqlite")
  }

  private static func remove(_ url: URL) {
    for suffix in ["", "-wal", "-shm"] {
      try? FileManager.default.removeItem(atPath: url.path + suffix)
    }
  }

  static let numbers = ReceiptNumbers(
    fiscalDrive: "9999078900001111", documentNumber: "0000000042", fiscalSign: "0123456789",
    operation: 1)!

  @Test func aNewDatabaseHasTheColumnsAndAPlainIndex() throws {
    let stack = try TestSupport.makeStack()
    #expect(try stack.appliedMigrations().contains(Self.name))
    try stack.writer.read { (db: Database) throws in
      let operations = try db.columns(in: "transactions").map(\.name)
      for column in ["receipt_fn", "receipt_i", "receipt_fp", "receipt_n"] {
        #expect(operations.contains(column), "\(column)")
      }
      let categories = try db.columns(in: "categories").map(\.name)
      for column in ["name_en", "name_en_source"] {
        #expect(categories.contains(column), "\(column)")
      }
      let index = try #require(
        try db.indexes(on: "transactions").first { $0.name == "idx_transactions_receipt" })
      #expect(!index.isUnique, "two devices that read one receipt apart must both apply")
      #expect(index.columns == ["receipt_fn", "receipt_i"])
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
            INSERT INTO categories (id, kind, name, sort, archived)
            VALUES ('22222222-2222-4222-8222-222222222222', 'expense', 'Кафе', 0, 0);
            INSERT INTO transactions
              (id, kind, occurred_at, amount_e4, amount_rub_e4, note, created_at, updated_at)
            VALUES ('11111111-1111-4111-8111-111111111111', 'expense', '2026-10-20 10:00:00.000',
              1500000, 1500000, 'кофе', '2026-10-20 10:00:00.000', '2026-10-20 10:00:00.000');
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
      let operation = try #require(
        try CoreKit.Transaction.fetchOne(db, key: "11111111-1111-4111-8111-111111111111"))
      #expect(operation.receipt == nil, "an operation the update finds holds no receipt")
      let category = try #require(
        try CoreKit.Category.fetchOne(db, key: "22222222-2222-4222-8222-222222222222"))
      #expect(category.translation == nil && category.englishName == nil)
    }
    // Every category the update finds is due for its English name.
    let due = try CategoryEnglishNames(writer: stack.writer, translator: StubTranslator()).due()
    #expect(due.map(\.name) == ["Кафе"])
  }

  @Test func theNewFieldsRoundTripThroughTheRecords() async throws {
    let stack = try TestSupport.makeStack()
    var made = try TestSupport.makeEntry()
    made.transaction.receipt = Self.numbers
    let entry = made
    let category = CoreKit.Category(
      kind: .expense, name: "Продукты",
      translation: CategoryTranslation(english: "Groceries", source: "Продукты"))
    try await stack.writer.write { db in
      try entry.transaction.insert(db)
      try category.insert(db)
    }
    try await stack.writer.read { (db: Database) throws in
      let read = try #require(try CoreKit.Transaction.fetchOne(db, key: entry.id.uuidString))
      #expect(read.receipt == Self.numbers)
      #expect(read.receipt?.documentNumber == "42", "kept without the leading zeros")
      #expect(read.receipt?.fiscalSign == "123456789")
      #expect(read.receipt?.operation == 1)
      #expect(try CoreKit.Category.fetchOne(db, key: category.id.uuidString) == category)
    }
  }

  @Test func aCategorySavedFromACopyWithoutTheEnglishNameKeepsIt() throws {
    let stack = try TestSupport.makeStack()
    var category = CoreKit.Category(kind: .expense, name: "Такси")
    let references = ReferenceRepository(writer: stack.writer)
    try references.save(category)
    try CategoryEnglishNames(writer: stack.writer, translator: StubTranslator())
      .write("Taxi", of: category.id.uuidString, madeOf: "Такси")
    // The screen still holds the copy read before the name was made.
    category.essential = true
    try references.save(category)
    let read = try #require(try references.categories().first { $0.id == category.id })
    #expect(read.englishName == "Taxi")
    #expect(read.essential == true)
  }

  @Test func aNumberThatDoesNotReadIsNoReceipt() throws {
    let stack = try TestSupport.makeStack()
    let entry = try TestSupport.makeEntry()
    try stack.writer.write { db in
      try entry.transaction.insert(db)
      try db.execute(
        sql: "UPDATE transactions SET receipt_fn = 'не число', receipt_i = '42' WHERE id = ?",
        arguments: [entry.id.uuidString])
    }
    let read = try #require(
      try stack.writer.read { db in try CoreKit.Transaction.fetchOne(db, key: entry.id.uuidString) }
    )
    #expect(read.receipt == nil)
  }

  @Test func theHolderOfAReceiptIsFoundInTheDatabaseAndADeletedOneDoesNotCount() throws {
    let stack = try TestSupport.makeStack()
    var holder = try TestSupport.makeEntry()
    holder.transaction.receipt = Self.numbers
    var deleted = try TestSupport.makeEntry()
    deleted.transaction.receipt = Self.numbers
    deleted.transaction.deletedAt = Date(timeIntervalSince1970: 1_789_000_500)
    var other = try TestSupport.makeEntry()
    other.transaction.receipt = ReceiptNumbers(
      fiscalDrive: "9999078900001111", documentNumber: "43")
    try stack.writer.write { db in
      try holder.transaction.insert(db)
      try deleted.transaction.insert(db)
      try other.transaction.insert(db)
    }
    let repository = TransactionRepository(writer: stack.writer)
    let fromPaper = try #require(
      ReceiptNumbers(fiscalDrive: "9999078900001111", documentNumber: "42"))
    #expect(try repository.operations(holdingReceipt: fromPaper).map(\.id) == [holder.id])
  }

  @Test func theNewColumnsGoToTheOutboxOfTheExchange() throws {
    let device = try TestDevice("mac")
    try device.insertOperation("t1", note: "кофе")
    try device.sql(
      "INSERT INTO categories (id, kind, name, sort, archived) VALUES ('c1', 'expense', 'Кафе', 0, 0)"
    )
    try device.sql("DELETE FROM sync_outbox")
    try device.sql(
      "UPDATE transactions SET receipt_fn = '9999078900001111', receipt_i = '42' WHERE id = 't1'")
    try device.sql(
      "UPDATE categories SET name_en = 'Cafes', name_en_source = 'Кафе' WHERE id = 'c1'")
    let queued = try device.stack.writer.read { db in
      try String.fetchAll(
        db, sql: "SELECT DISTINCT table_name || ':' || row_key FROM sync_outbox ORDER BY 1")
    }
    #expect(queued == ["categories:c1", "transactions:t1"])
  }

  @Test func theNumbersAndTheEnglishNameReachTheOtherDevice() throws {
    let mac = try TestDevice("mac")
    let phone = try TestDevice("phone")
    let folder = InMemoryFolder()
    try mac.insertOperation("t1", note: "кофе")
    try mac.sql(
      """
      UPDATE transactions SET receipt_fn = '9999078900001111', receipt_i = '42',
        receipt_fp = '123456789', receipt_n = 1 WHERE id = 't1'
      """)
    try mac.sql(
      """
      INSERT INTO categories (id, kind, name, sort, archived, name_en, name_en_source)
      VALUES ('c1', 'expense', 'Кафе', 0, 0, 'Cafes', 'Кафе')
      """)
    _ = try mac.exchange.exchange(with: folder)
    _ = try phone.exchange.exchange(with: folder)
    let row = try phone.stack.writer.read { db in
      try Row.fetchOne(
        db,
        sql: "SELECT receipt_fn, receipt_i, receipt_fp, receipt_n FROM transactions WHERE id = 't1'"
      )
    }
    #expect(row?["receipt_fn"] == "9999078900001111")
    #expect(row?["receipt_i"] == "42")
    #expect(row?["receipt_fp"] == "123456789")
    #expect(row?["receipt_n"] == 1)
    let english = try phone.stack.writer.read { db in
      try String.fetchOne(db, sql: "SELECT name_en FROM categories WHERE id = 'c1'")
    }
    #expect(english == "Cafes")
  }

  @Test func twoDevicesWordingTheEnglishNameApartIsNoConflict() {
    #expect(SyncConflict.isService("name_en"))
    #expect(SyncConflict.isService("name_en_source"))
    #expect(!SyncConflict.differs("name_en", .string("Cafes"), .string("Cafe")))
    #expect(SyncConflict.differs("name", .string("Кафе"), .string("Кафе и бары")))
    #expect(SyncConflict.differs("receipt_i", .string("42"), .string("43")))
  }

  /// Both devices hold the same category; then each makes its own English name of it.
  private static func apartOnTheEnglishName() throws -> (
    mac: TestDevice, phone: TestDevice, folder: InMemoryFolder
  ) {
    let mac = try TestDevice("mac")
    let phone = try TestDevice("phone")
    let folder = InMemoryFolder()
    try mac.sql(
      "INSERT INTO categories (id, kind, name, sort, archived) VALUES ('c1', 'expense', 'Кафе', 0, 0)"
    )
    try mac.stamp("2026-11-10T10:00:00Z")
    _ = try mac.exchange.exchange(with: folder)
    _ = try phone.exchange.exchange(with: folder)
    try CategoryEnglishNames(writer: mac.stack.writer, translator: StubTranslator())
      .write("Cafes", of: "c1", madeOf: "Кафе")
    try mac.stamp("2026-11-10T10:05:00Z")
    try CategoryEnglishNames(writer: phone.stack.writer, translator: StubTranslator())
      .write("Cafe", of: "c1", madeOf: "Кафе")
    try phone.stamp("2026-11-10T10:06:00Z")
    return (mac, phone, folder)
  }

  private static func english(_ device: TestDevice) throws -> String? {
    try device.stack.writer.read { db in
      try String.fetchOne(db, sql: "SELECT name_en FROM categories WHERE id = 'c1'")
    }
  }

  @Test func englishNamesMadeApartStayOnTheirDevicesWithoutAConflict() throws {
    let (mac, phone, folder) = try Self.apartOnTheEnglishName()
    #expect(try mac.outboxCount() == 0 && phone.outboxCount() == 0)
    for _ in 0..<2 {
      #expect(try mac.exchange.exchange(with: folder).conflictsOpen == 0)
      #expect(try phone.exchange.exchange(with: folder).conflictsOpen == 0)
    }
    #expect(try mac.exchange.conflicts().isEmpty && phone.exchange.conflicts().isEmpty)
    #expect(try Self.english(mac) == "Cafes")
    #expect(try Self.english(phone) == "Cafe")
  }

  @Test func theOwnersNextEditCarriesTheEnglishNameToTheOtherDevice() throws {
    let (mac, phone, folder) = try Self.apartOnTheEnglishName()
    try mac.sql("UPDATE categories SET essential = 1 WHERE id = 'c1'")
    try mac.stamp("2026-11-10T10:10:00Z")
    _ = try mac.exchange.exchange(with: folder)
    let outcome = try phone.exchange.exchange(with: folder)
    #expect(outcome.conflictsOpen == 0)
    #expect(try Self.english(phone) == "Cafes")
    let source = try phone.stack.writer.read { db in
      try String.fetchOne(db, sql: "SELECT name_en_source FROM categories WHERE id = 'c1'")
    }
    #expect(source == "Кафе")
  }

  @Test func aRenameOnOneDeviceWhileTheOtherTranslatesIsNoConflict() throws {
    let (mac, phone, folder) = try Self.apartOnTheEnglishName()
    try phone.sql("UPDATE categories SET name = 'Кафе и бары' WHERE id = 'c1'")
    try phone.stamp("2026-11-10T10:07:00Z")
    for _ in 0..<2 {
      #expect(try mac.exchange.exchange(with: folder).conflictsOpen == 0)
      #expect(try phone.exchange.exchange(with: folder).conflictsOpen == 0)
    }
    for device in [mac, phone] {
      let name = try device.stack.writer.read { db in
        try String.fetchOne(db, sql: "SELECT name FROM categories WHERE id = 'c1'")
      }
      #expect(name == "Кафе и бары", "the owner's rename is kept on \(device.id)")
    }
    let due = try CategoryEnglishNames(writer: mac.stack.writer, translator: StubTranslator()).due()
    #expect(due.map(\.id) == ["c1"], "the English name of the old name is made again")
  }

  @Test func theAnonymizedCopyHasNoReceiptNumbersAndKeepsTheEnglishName() throws {
    let stack = try TestSupport.makeStack()
    var entry = try TestSupport.makeEntry()
    entry.transaction.receipt = Self.numbers
    let category = CoreKit.Category(
      kind: .expense, name: "Продукты",
      translation: CategoryTranslation(english: "Groceries", source: "Продукты"))
    try stack.writer.write { db in
      try entry.transaction.insert(db)
      try category.insert(db)
    }
    try SQLAnonymizer().anonymize(copy: ExportCopyDatabase(writer: stack.writer))
    try stack.writer.read { db in
      let row = try #require(
        try Row.fetchOne(
          db,
          sql: "SELECT receipt_fn, receipt_i, receipt_fp, receipt_n FROM transactions WHERE id = ?",
          arguments: [entry.id.uuidString]))
      for column in ["receipt_fn", "receipt_i", "receipt_fp", "receipt_n"] {
        #expect((row[column] as DatabaseValue).isNull, "\(column)")
      }
      let english = try String.fetchOne(
        db, sql: "SELECT name_en FROM categories WHERE id = ?",
        arguments: [category.id.uuidString])
      #expect(english == "Groceries")
    }
  }

  @Test func theCSVCarriesTheNewColumnsLastAndTheFilesStayFiftyThree() throws {
    #expect(
      Array(ExportTables.transactions.columns.suffix(4))
        == ["receipt_fn", "receipt_i", "receipt_fp", "receipt_n"])
    #expect(
      Array(ExportTables.categories.columns.suffix(4))
        == ["name_en", "name_en_source", "icon", "color"], "the mark of 0024 comes after them")
    #expect(ExportTables.all.count == 54)
    #expect(SyncTables.followed["transactions"] == "id")
    #expect(SyncTables.followed["categories"] == "id")
  }
}
