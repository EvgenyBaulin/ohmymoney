import AppCore
import CoreAnalytics
import CoreCSV
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

// Synthetic data only.

/// The update to the merchant code and the commission of an operation, the valuations of things,
/// the picture of a wish and the fee without a card (`0026_mcc_fee_valuations_wish_image`) only
/// adds: a database of the previous schema keeps every value, and the new columns start empty.
/// The new columns and the new table travel through the records, the CSV, the archive's database
/// and the exchange.
///
/// The previous schema is whatever comes before this file, so the test reads the same whether
/// or not another migration lands after it.
@Suite("Schema 26 comes in without touching a value")
struct Migration0026Tests {
  static let name = "0026_mcc_fee_valuations_wish_image"
  static let operation = "11111111-1111-4111-8111-111111111111"
  static let account = "55555555-5555-4555-8555-555555555555"
  static let wish = "22222222-2222-4222-8222-222222222222"
  static let item = "33333333-3333-4333-8333-333333333333"
  static let asset = "44444444-4444-4444-8444-444444444444"

  private static var older: FilteredSchemaSource {
    let before = TestSupport.migrationNames.filter { $0 < name }
    return FilteredSchemaSource(upTo: before.last ?? "")
  }

  private static func temporaryURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("migration-0026-\(UUID().uuidString).sqlite")
  }

  private static func remove(_ url: URL) {
    for suffix in ["", "-wal", "-shm"] {
      try? FileManager.default.removeItem(atPath: url.path + suffix)
    }
  }

  private static let seed = """
    INSERT INTO payment_methods (id, name) VALUES ('\(account)', 'Account');
    INSERT INTO transactions
      (id, kind, occurred_at, amount_e4, amount_rub_e4, note, created_at, updated_at)
    VALUES ('\(operation)', 'expense', '2026-10-20 10:00:00.000', 1000000, 1000000, 'coffee',
            '2026-10-20 10:00:00.000', '2026-10-20 10:00:00.000');
    INSERT INTO wishes (id, name, currency, created_on) VALUES ('\(wish)', 'Desk', 'RUB', '2026-10-01');
    INSERT INTO owned_items (id, name, bought_on, price_e4, currency)
      VALUES ('\(item)', 'Laptop', '2026-01-01', 7000000, 'RUB');
    INSERT INTO bank_conditions (id, payment_method_id, free_cash_e4)
      VALUES ('66666666-6666-4666-8666-666666666666', '\(account)', 1000000);
    """

  @Test func aNewDatabaseHasTheColumnsTheTableTheTriggersAndTheKey() throws {
    let stack = try TestSupport.makeStack()
    #expect(try stack.appliedMigrations().contains(Self.name))
    #expect(try stack.appliedMigrations().count >= 26)
    try stack.writer.read { (db: Database) throws in
      for (table, column, type) in [
        ("transactions", "mcc", "TEXT"), ("transactions", "fee_e4", "INTEGER"),
        ("bank_conditions", "no_card_fee_e4", "INTEGER"), ("wishes", "image_url", "TEXT"),
      ] {
        let found = try #require(try db.columns(in: table).first { $0.name == column })
        #expect(found.type.uppercased() == type, "\(table).\(column)")
        #expect(!found.isNotNull, "\(table).\(column) can stay empty")
        let sql =
          try String.fetchOne(
            db, sql: "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?",
            arguments: [table]) ?? ""
        #expect(!sql.contains("\(column) TEXT CHECK"), "an added column carries no CHECK")
        #expect(!sql.contains("\(column) INTEGER CHECK"), "an added column carries no CHECK")
      }
      #expect(
        try db.columns(in: "thing_valuations").map(\.name) == [
          "id", "owner_kind", "owner_id", "valued_on", "value_e4", "currency", "note",
          "recorded_at",
        ])
      let triggers = try String.fetchAll(
        db,
        sql: """
          SELECT name FROM sqlite_master WHERE type = 'trigger'
            AND (tbl_name = 'thing_valuations' OR name LIKE 'thing_valuations_%') ORDER BY name
          """)
      #expect(
        triggers == [
          "sync_thing_valuations_delete", "sync_thing_valuations_insert",
          "sync_thing_valuations_update", "thing_valuations_asset_gone",
          "thing_valuations_owned_item_gone",
        ])
    }
  }

  @Test func aDatabaseOfThePreviousSchemaKeepsEveryValueAndTheNewFieldsAreEmpty() throws {
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
      let operation = try #require(try CoreKit.Transaction.fetchAll(db).first)
      #expect(operation.mcc == nil && operation.feeE4 == nil)
      let wish = try #require(try Wish.fetchAll(db).first)
      #expect(wish.imageURL == nil)
      let conditions = try #require(try BankConditions.fetchAll(db).first)
      #expect(conditions.noCardFeeE4 == nil && conditions.freeCashE4 == AmountE4(whole: 100))
      #expect(try ThingValuationRepository.all(db).isEmpty)
    }
  }

  @Test func theCodeAndTheFeeOfAnOperationRoundTripAndAnEditKeepsThem() throws {
    let stack = try TestSupport.makeStack()
    var draft = TransactionDraft(
      kind: .expense, occurredAt: Date(timeIntervalSince1970: 1_789_000_000),
      amount: AmountE4(whole: 100), mcc: "742", feeE4: AmountE4(raw: 12_500))
    draft.normalizeSinglePart()
    let entry = try draft.materialize(timeZone: TimeZone(identifier: "UTC")!)
    #expect(entry.transaction.mcc == "0742")
    let repository = TransactionRepository(writer: stack.writer)
    try repository.insert([entry])
    let read = try #require(try repository.entry(id: entry.transaction.id))
    #expect(read.transaction.mcc == "0742" && read.transaction.feeE4 == AmountE4(raw: 12_500))
    let stored = try stack.writer.read { db in
      try Row.fetchOne(db, sql: "SELECT mcc, fee_e4 FROM transactions")
    }
    #expect(stored?["mcc"] as String? == "0742" && stored?["fee_e4"] as Int64? == 12_500)
    // Reopening for an edit and rebuilding keeps both.
    let reopened = TransactionDraft(entry: read)
    #expect(reopened.mcc == "0742" && reopened.feeE4 == AmountE4(raw: 12_500))
    let rebuilt = try reopened.materialize(
      id: entry.transaction.id, timeZone: TimeZone(identifier: "UTC")!)
    #expect(rebuilt.transaction.mcc == "0742" && rebuilt.transaction.feeE4 == AmountE4(raw: 12_500))
  }

  @Test func aCodeThatIsNoCodeReadsAsNone() throws {
    let stack = try TestSupport.makeStack()
    try stack.writer.write { db in try db.execute(sql: Self.seed) }
    try stack.writer.write { db in
      try db.execute(sql: "UPDATE transactions SET mcc = 'abc', fee_e4 = 'bad'")
    }
    let operation = try #require(
      try TransactionRepository(writer: stack.writer).entry(id: UUID(uuidString: Self.operation)!))
    #expect(operation.transaction.mcc == "abc" || operation.transaction.mcc == nil)
    #expect(operation.transaction.feeE4 == nil)
  }

  @Test func theFeeWithoutACardAndThePictureRoundTrip() throws {
    let stack = try TestSupport.makeStack()
    try stack.writer.write { db in try db.execute(sql: Self.seed) }
    let account = try #require(UUID(uuidString: Self.account))
    let conditions = BankConditions(
      accountId: account, note: nil, noCardFeeE4: AmountE4(whole: 150))
    let repository = BankConditionsRepository(writer: stack.writer)
    try repository.save(conditions)
    #expect(try repository.conditions(account: account)?.noCardFeeE4 == AmountE4(whole: 150))
    var empty = try #require(try repository.conditions(account: account))
    empty.noCardFeeE4 = nil
    try repository.save(empty)
    #expect(try repository.conditions(account: account)?.noCardFeeE4 == nil)
  }

  @Test func theNewColumnsAndTheTableGoLastInTheCSVAndTheFilesAreFiftyFive() throws {
    #expect(ExportTables.all.count == 55)
    #expect(ExportTables.all.last == ExportTables.thingValuations)
    let stack = try TestSupport.makeStack()
    try stack.writer.write { db in
      try db.execute(sql: Self.seed)
      try db.execute(
        sql: """
          UPDATE transactions SET mcc = '0742', fee_e4 = 12500;
          UPDATE wishes SET image_url = 'https://shop.example/image.jpg';
          UPDATE bank_conditions SET no_card_fee_e4 = 1500000;
          INSERT INTO thing_valuations
            (id, owner_kind, owner_id, valued_on, value_e4, currency, note, recorded_at)
          VALUES ('77777777-7777-4777-8777-777777777777', 'owned_item', '\(Self.item)',
                  '2026-09-01', 8000000, 'EUR', 'market', '2026-09-01 10:00:00.000');
          """)
    }
    let tables = try ExportRepository(writer: stack.writer).tables()
    func rows(_ table: ExportTable) throws -> [[String: String]] {
      let file = try #require(tables.first { $0.fileName == table.fileName })
      let text = String(decoding: file.data, as: UTF8.self)
      #expect(text.hasPrefix(table.columns.joined(separator: ",")))
      return try CSVReader.dictionaries(from: file.data)
    }
    let operation = try #require(try rows(ExportTables.transactions).first)
    #expect(operation["mcc"] == "0742" && operation["fee"] == "1.25")
    #expect(try rows(ExportTables.wishes).first?["image_url"] == "https://shop.example/image.jpg")
    #expect(try rows(ExportTables.bankConditions).first?["no_card_fee"] == "150")
    let valuation = try #require(try rows(ExportTables.thingValuations).first)
    #expect(valuation["value"] == "800" && valuation["currency"] == "EUR")
    #expect(valuation["owner_kind"] == "owned_item" && valuation["owner_id"] == Self.item)
  }

  @Test func theNewTableIsFollowedAndTheNewColumnsTravelToTheOtherDevice() throws {
    #expect(SyncTables.followed["thing_valuations"] == "id")
    #expect(DatabaseStack.ledgerTables.contains("thing_valuations"))
    let mac = try TestDevice("mac")
    let phone = try TestDevice("phone")
    let folder = InMemoryFolder()
    try mac.sql(Self.seed)
    _ = try mac.exchange.exchange(with: folder)
    _ = try phone.exchange.exchange(with: folder)
    try mac.sql("UPDATE transactions SET mcc = '5411', fee_e4 = 12500")
    try mac.sql("UPDATE wishes SET image_url = 'https://shop.example/image.jpg'")
    try mac.sql("UPDATE bank_conditions SET no_card_fee_e4 = 1500000")
    try mac.sql(
      """
      INSERT INTO thing_valuations
        (id, owner_kind, owner_id, valued_on, value_e4, currency, note, recorded_at)
      VALUES ('77777777-7777-4777-8777-777777777777', 'owned_item', '\(Self.item)',
              '2026-09-01', 8000000, 'EUR', 'market', '2026-09-01 10:00:00.000')
      """)
    let queued = try mac.stack.writer.read { (db: Database) throws in
      try String.fetchAll(db, sql: "SELECT DISTINCT table_name FROM sync_outbox ORDER BY 1")
    }
    #expect(
      Set(queued) == ["bank_conditions", "thing_valuations", "transactions", "wishes"])
    _ = try mac.exchange.exchange(with: folder)
    _ = try phone.exchange.exchange(with: folder)
    try phone.stack.writer.read { (db: Database) throws in
      let operation = try #require(try CoreKit.Transaction.fetchAll(db).first)
      #expect(operation.mcc == "5411" && operation.feeE4 == AmountE4(raw: 12_500))
      #expect(try Wish.fetchAll(db).first?.imageURL == "https://shop.example/image.jpg")
      #expect(try BankConditions.fetchAll(db).first?.noCardFeeE4 == AmountE4(whole: 150))
      let value = try #require(try ThingValuationRepository.all(db).first)
      #expect(value.amountE4 == AmountE4(whole: 800) && value.currency == CurrencyCode("EUR"))
    }
    #expect(try mac.books() == phone.books())
    // Deleting the owner takes its valuations with it, on the other device too.
    try mac.sql("DELETE FROM owned_items WHERE id = ?", [Self.item])
    _ = try mac.exchange.exchange(with: folder)
    _ = try phone.exchange.exchange(with: folder)
    #expect(try phone.count("thing_valuations") == 0)
    #expect(try mac.count("thing_valuations") == 0)
  }

  @Test func theAnonymizedCopyKeepsTheCodeTheFeeAndTheValuationsButNotTheirWords() throws {
    let stack = try TestSupport.makeStack()
    try stack.writer.write { db in
      try db.execute(sql: Self.seed)
      try db.execute(
        sql: """
          UPDATE transactions SET mcc = '0742', fee_e4 = 12500;
          UPDATE wishes SET image_url = 'https://shop.example/private.jpg';
          UPDATE bank_conditions SET no_card_fee_e4 = 1500000;
          INSERT INTO thing_valuations
            (id, owner_kind, owner_id, valued_on, value_e4, currency, note, recorded_at)
          VALUES ('77777777-7777-4777-8777-777777777777', 'owned_item', '\(Self.item)',
                  '2026-09-01', 8000000, 'EUR', 'private words', '2026-09-01 10:00:00.000');
          """)
    }
    try SQLAnonymizer().anonymize(copy: ExportCopyDatabase(writer: stack.writer))
    try stack.writer.read { (db: Database) throws in
      let operation = try #require(try CoreKit.Transaction.fetchAll(db).first)
      #expect(operation.mcc == "0742" && operation.feeE4 == AmountE4(raw: 12_500))
      #expect(try BankConditions.fetchAll(db).first?.noCardFeeE4 == AmountE4(whole: 150))
      #expect(try Wish.fetchAll(db).first?.imageURL == nil)
      let value = try #require(try ThingValuationRepository.all(db).first)
      #expect(value.note == nil && value.amountE4 == AmountE4(whole: 800))
    }
  }

  @Test func aPeriodCopyKeepsOnlyTheValuationsOfThePeriod() throws {
    let stack = try TestSupport.makeStack()
    try stack.writer.write { db in
      try db.execute(sql: Self.seed)
      for (id, day) in [
        ("77777777-7777-4777-8777-777777777777", "2026-09-01"),
        ("88888888-8888-4888-8888-888888888888", "2025-01-01"),
      ] {
        try db.execute(
          sql: """
            INSERT INTO thing_valuations
              (id, owner_kind, owner_id, valued_on, value_e4, currency, recorded_at)
            VALUES (?, 'owned_item', ?, ?, 8000000, 'EUR', '2026-09-01 10:00:00.000')
            """, arguments: [id, Self.item, day])
      }
      try ExportCopyMaker.cut(
        ExportCopyRequest(
          scope: .period(
            DayRange(
              DateOnly(year: 2026, month: 1, day: 1), DateOnly(year: 2026, month: 12, day: 31))),
          anonymize: false, includeHidden: true, includeAttachments: true, password: "x"),
        db: db)
    }
    #expect(
      try ThingValuationRepository(writer: stack.writer).all().map(\.day)
        == [DateOnly(year: 2026, month: 9, day: 1)])
  }

  @Test func theCheckOfTheDatabaseFindsNothingWrongInAHealthyValuationBook() throws {
    let stack = try TestSupport.makeStack()
    try stack.writer.write { db in
      try db.execute(
        sql: """
          INSERT INTO owned_items (id, name, bought_on, price_e4, currency)
            VALUES ('\(Self.item)', 'Laptop', '2026-01-01', 7000000, 'RUB');
          INSERT INTO thing_valuations
            (id, owner_kind, owner_id, valued_on, value_e4, currency, recorded_at)
          VALUES ('77777777-7777-4777-8777-777777777777', 'owned_item', '\(Self.item)',
                  '2026-09-01', 8000000, 'EUR', '2026-09-01 10:00:00.000')
          """)
    }
    #expect(try DatabaseCheck.run(stack.writer).isHealthy)
  }
}
