import AppCore
import CoreAnalytics
import CoreCSV
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

// Synthetic data only.

/// The update to merchant codes in a bank's table of cashback categories
/// (`0028_bank_cashback_merchant_codes`) only adds two columns: a database of the previous schema
/// keeps every value, and the new columns start empty. They travel through the record, the CSV,
/// the archive's database and the exchange, and the anonymized copy keeps them.
///
/// The previous schema is whatever comes before this file, so the test reads the same whether or
/// not another migration lands after it.
@Suite("Schema 28 comes in without touching a value")
struct Migration0028Tests {
  static let name = "0028_bank_cashback_merchant_codes"
  static let bank = "61616161-6161-4616-8616-616161616161"
  static let category = "62626262-6262-4626-8626-626262626262"
  static let mapping = "63636363-6363-4636-8636-636363636363"
  static let plain = "64646464-6464-4646-8646-646464646464"

  private static var older: FilteredSchemaSource {
    let before = TestSupport.migrationNames.filter { $0 < name }
    return FilteredSchemaSource(upTo: before.last ?? "")
  }

  private static func temporaryURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("migration-0028-\(UUID().uuidString).sqlite")
  }

  private static func remove(_ url: URL) {
    for suffix in ["", "-wal", "-shm"] {
      try? FileManager.default.removeItem(atPath: url.path + suffix)
    }
  }

  /// A bank, an expense category and two rows of the bank's table, as schema 21 wrote them.
  private static let seed = """
    INSERT INTO banks (id, name) VALUES ('\(bank)', 'Bank');
    INSERT INTO categories (id, kind, name) VALUES ('\(category)', 'expense', 'Cafes');
    INSERT INTO bank_cashback_categories (id, bank_id, label, category_id)
      VALUES ('\(mapping)', '\(bank)', 'Restaurants', '\(category)');
    INSERT INTO bank_cashback_categories (id, bank_id, label, category_id)
      VALUES ('\(plain)', '\(bank)', 'Fast food', '\(category)');
    """

  private static let filled = """
    UPDATE bank_cashback_categories SET include_mcc = '5811-5814', exclude_mcc = '5813'
      WHERE id = '\(mapping)';
    """

  @Test func aNewDatabaseHasTheColumnsWithoutChecks() throws {
    let stack = try TestSupport.makeStack()
    #expect(try stack.appliedMigrations().contains(Self.name))
    #expect(try stack.appliedMigrations().count >= 28)
    try stack.writer.read { (db: Database) throws in
      for column in ["include_mcc", "exclude_mcc"] {
        let found = try #require(
          try db.columns(in: "bank_cashback_categories").first { $0.name == column })
        #expect(found.type.uppercased() == "TEXT", "\(column)")
        #expect(!found.isNotNull, "\(column) can stay empty")
        let sql =
          try String.fetchOne(
            db,
            sql: "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?",
            arguments: ["bank_cashback_categories"]) ?? ""
        #expect(!sql.contains("\(column) TEXT CHECK"), "an added column carries no CHECK")
      }
      // The key of the table is the one 0021 made: one row per bank, label and category.
      let index =
        try String.fetchOne(
          db,
          sql: "SELECT sql FROM sqlite_master WHERE name = 'idx_bank_cashback_categories_key'")
        ?? ""
      #expect(index.contains("bank_id, label, category_id"))
    }
  }

  @Test func aDatabaseOfThePreviousSchemaKeepsEveryValueAndTheListsAreEmpty() throws {
    let url = Self.temporaryURL()
    defer { Self.remove(url) }
    let before: [String: TableContents]
    do {
      let old = try DatabaseStack(url: url, schema: Self.older)
      try old.writer.write { db in try db.execute(sql: Self.seed) }
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
      let stored = try Row.fetchAll(
        db, sql: "SELECT include_mcc, exclude_mcc FROM bank_cashback_categories")
      #expect(stored.count == 2)
      #expect(stored.allSatisfy { ($0["include_mcc"] as String?) == nil })
      #expect(stored.allSatisfy { ($0["exclude_mcc"] as String?) == nil })
      let rows = try BankCategoryMapping.fetchAll(db)
      #expect(rows.count == 2 && rows.allSatisfy { !$0.hasCodes })
    }
  }

  @Test func theListsRoundTripThroughTheRecordAndAnEmptyListIsNull() throws {
    let stack = try TestSupport.makeStack()
    try stack.writer.write { db in
      try db.execute(sql: Self.seed)
      try db.execute(sql: Self.filled)
    }
    try stack.writer.read { (db: Database) throws in
      let row = try #require(try BankCategoryMapping.fetchOne(db, key: Self.mapping))
      #expect(row.includeCodes == MerchantCodeList(parsing: "5811-5814"))
      #expect(row.excludeCodes == MerchantCodeList(parsing: "5813"))
      #expect(try BankCategoryMapping.fetchOne(db, key: Self.plain)?.hasCodes == false)
    }
    // Saving the records back writes the same text, and a row without lists stays NULL.
    try stack.writer.write { db in
      for row in try BankCategoryMapping.fetchAll(db) { try row.save(db) }
    }
    let kept = try stack.writer.read { db in
      try Row.fetchAll(
        db,
        sql: "SELECT id, include_mcc, exclude_mcc FROM bank_cashback_categories ORDER BY id")
    }
    #expect(kept.map { $0["include_mcc"] as String? } == ["5811-5814", nil])
    #expect(kept.map { $0["exclude_mcc"] as String? } == ["5813", nil])
    // Taking the lists away writes NULL, never an empty text.
    try stack.writer.write { db in
      var row = try #require(try BankCategoryMapping.fetchOne(db, key: Self.mapping))
      row.includeCodes = .empty
      row.excludeCodes = MerchantCodeList(parsing: "5814, 742, 5811-5813")!
      try row.save(db)
    }
    let edited = try stack.writer.read { db in
      try Row.fetchOne(
        db, sql: "SELECT include_mcc, exclude_mcc FROM bank_cashback_categories WHERE id = ?",
        arguments: [Self.mapping])
    }
    #expect(edited?["include_mcc"] as String? == nil)
    #expect(edited?["exclude_mcc"] as String? == "0742, 5811-5814")
    // The repository of the sheet gives the lists to the dataset.
    let book = try CashbackChoiceRepository(writer: stack.writer).book()
    #expect(book.mappings.first { $0.id.uuidString.lowercased() == Self.mapping }?.hasCodes == true)
  }

  @Test func aListThatDoesNotReadIsNoListAndTheCheckNamesIt() throws {
    let stack = try TestSupport.makeStack()
    try stack.writer.write { db in
      try db.execute(sql: Self.seed)
      try db.execute(
        sql: """
          UPDATE bank_cashback_categories SET include_mcc = 'cafes', exclude_mcc = 5813
            WHERE id = '\(Self.mapping)';
          UPDATE bank_cashback_categories SET exclude_mcc = X'00' WHERE id = '\(Self.plain)';
          """)
    }
    try stack.writer.read { (db: Database) throws in
      // The row still maps its label; the list that does not read is none, the number reads.
      let row = try #require(try BankCategoryMapping.fetchOne(db, key: Self.mapping))
      #expect(row.includeCodes.isEmpty)
      #expect(row.excludeCodes == MerchantCodeList(parsing: "5813"))
      #expect(try BankCategoryMapping.fetchOne(db, key: Self.plain)?.hasCodes == false)
      #expect(try CashbackChoiceRepository.book(db).mappings.count == 2)
    }
    let report = try DatabaseCheck.run(stack.writer)
    let finding = try #require(report.findings.first { $0.rule == .merchantCodesUnreadable })
    #expect(finding.count == 2 && !finding.isRepairable)
    #expect(finding.table == "bank_cashback_categories")
    #expect(Set(finding.ids.map { $0.lowercased() }) == [Self.mapping, Self.plain])
    // The CSV still writes a row that reads, with the text of the database.
    let healthy = try TestSupport.makeStack()
    try healthy.writer.write { db in
      try db.execute(sql: Self.seed)
      try db.execute(sql: Self.filled)
    }
    #expect(try DatabaseCheck.run(healthy.writer).isHealthy)
  }

  @Test func theListsGoLastInTheCSVAndTheNumberOfFilesIsUnchanged() throws {
    #expect(ExportTables.all.count == 55)
    #expect(
      ExportTables.bankCashbackCategories.columns == [
        "id", "bank_id", "label", "category_id", "include_mcc", "exclude_mcc",
      ])
    let stack = try TestSupport.makeStack()
    try stack.writer.write { db in
      try db.execute(sql: Self.seed)
      try db.execute(sql: Self.filled)
      // A row whose category does not read still goes out, lists and all.
      try db.execute(
        sql: """
          INSERT INTO bank_cashback_categories (id, bank_id, label, category_id, include_mcc)
            VALUES ('65656565-6565-4656-8656-656565656565', '\(Self.bank)', 'Odd', 'not-a-uuid',
                    '5411');
          """)
    }
    let tables = try ExportRepository(writer: stack.writer).tables()
    let file = try #require(
      tables.first { $0.fileName == ExportTables.bankCashbackCategories.fileName })
    let text = String(decoding: file.data, as: UTF8.self)
    #expect(text.hasPrefix(ExportTables.bankCashbackCategories.columns.joined(separator: ",")))
    let rows = try CSVReader.dictionaries(from: file.data)
    #expect(rows.count == 3)
    let coded = try #require(rows.first { $0["id"]?.lowercased() == Self.mapping })
    #expect(coded["include_mcc"] == "5811-5814" && coded["exclude_mcc"] == "5813")
    let bare = try #require(rows.first { $0["id"]?.lowercased() == Self.plain })
    #expect(bare["include_mcc"] == "" && bare["exclude_mcc"] == "")
    let odd = try #require(rows.first { $0["label"] == "Odd" })
    #expect(odd["include_mcc"] == "5411" && odd["exclude_mcc"] == "")
    // A list with a comma inside one cell is quoted, so the file keeps six columns.
    let mapping = BankCategoryMapping(
      bankId: UUID(), label: "X", categoryId: UUID(),
      includeCodes: MerchantCodeList(parsing: "5411, 5811-5814")!)
    #expect(ExportTables.row(mapping).count == ExportTables.bankCashbackCategories.columns.count)
    #expect(Array(ExportTables.row(mapping).suffix(2)) == ["5411, 5811-5814", ""])
  }

  @Test func theListsTravelToTheOtherDeviceWithTheirRow() throws {
    let mac = try TestDevice("mac")
    let phone = try TestDevice("phone")
    let folder = InMemoryFolder()
    try mac.sql(Self.seed)
    _ = try mac.exchange.exchange(with: folder)
    _ = try phone.exchange.exchange(with: folder)
    try mac.sql(Self.filled)
    let queued = try mac.stack.writer.read { (db: Database) throws in
      try String.fetchAll(db, sql: "SELECT DISTINCT table_name FROM sync_outbox ORDER BY 1")
    }
    #expect(queued == ["bank_cashback_categories"])
    _ = try mac.exchange.exchange(with: folder)
    _ = try phone.exchange.exchange(with: folder)
    try phone.stack.writer.read { (db: Database) throws in
      let row = try #require(try BankCategoryMapping.fetchOne(db, key: Self.mapping))
      #expect(row.includeCodes.text == "5811-5814" && row.excludeCodes.text == "5813")
    }
    #expect(try mac.books() == phone.books())
    #expect(!SyncConflict.isService("include_mcc") && !SyncConflict.isService("exclude_mcc"))
  }

  @Test func theAnonymizedCopyKeepsTheCodes() throws {
    let stack = try TestSupport.makeStack()
    try stack.writer.write { db in
      try db.execute(sql: Self.seed)
      try db.execute(sql: Self.filled)
    }
    try SQLAnonymizer().anonymize(copy: ExportCopyDatabase(writer: stack.writer))
    try stack.writer.read { (db: Database) throws in
      let row = try #require(try BankCategoryMapping.fetchOne(db, key: Self.mapping))
      #expect(row.includeCodes.text == "5811-5814" && row.excludeCodes.text == "5813")
    }
  }
}
