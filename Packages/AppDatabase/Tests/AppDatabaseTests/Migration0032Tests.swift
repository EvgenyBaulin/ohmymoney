import AppCore
import CoreCSV
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

// Synthetic data only.

/// The capital before the books began (`0032_asset_purchase_and_loan_opening`) only adds four
/// columns: a database of the previous schema keeps every value, and the new columns start empty.
/// They travel through the records, the CSV, the archive's database and the exchange; the
/// anonymized copy keeps them, and a value a hand edit damaged reads as not said without stopping
/// the read.
///
/// The previous schema is whatever comes before this file, so the test reads the same whether or
/// not another migration lands after it.
@Suite("Schema 32 comes in without touching a value")
struct Migration0032Tests {
  static let name = "0032_asset_purchase_and_loan_opening"
  static let flat = "81818181-8181-4818-8818-818181818181"
  static let valuation = "82828282-8282-4828-8828-828282828282"
  static let loan = "83838383-8383-4838-8838-838383838383"
  static let line = "84848484-8484-4848-8848-848484848484"
  static let friend = "85858585-8585-4858-8858-858585858585"

  private static var older: FilteredSchemaSource {
    let before = TestSupport.migrationNames.filter { $0 < name }
    return FilteredSchemaSource(upTo: before.last ?? "")
  }

  private static func temporaryURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("migration-0032-\(UUID().uuidString).sqlite")
  }

  private static func remove(_ url: URL) {
    for suffix in ["", "-wal", "-shm"] {
      try? FileManager.default.removeItem(atPath: url.path + suffix)
    }
  }

  /// A flat valued once, a loan with the balance the books began with, and a friend's debt, as
  /// schema 31 wrote them.
  private static let seed = """
    INSERT INTO assets (id, name, kind, currency, note) VALUES ('\(flat)', 'Flat', 'realty', 'RUB', 'home');
    INSERT INTO asset_valuations (id, asset_id, day, value_e4) VALUES ('\(valuation)', '\(flat)', '2026-01-31', 90000000000);
    INSERT INTO debts (id, direction, type, name, interest_rate, monthly_payment_e4, payment_day)
      VALUES ('\(loan)', 'i_owe', 'loan', 'Mortgage', '9.5', 450000000, 10);
    INSERT INTO debt_entries (id, debt_id, date, amount_e4, kind)
      VALUES ('\(line)', '\(loan)', '2026-01-01', 31000000000, 'borrowed');
    INSERT INTO debts (id, direction, type, name) VALUES ('\(friend)', 'i_owe', 'personal', 'Friend');
    """

  private static let filled = """
    UPDATE assets SET purchased_on = '2019-06-14', purchase_price_e4 = 65000000000 WHERE id = '\(flat)';
    UPDATE debts SET opened_on = '2018-03-01', original_amount_e4 = 42000000000 WHERE id = '\(loan)';
    """

  private static let columns: [(table: String, column: String, type: String)] = [
    ("assets", "purchased_on", "TEXT"), ("assets", "purchase_price_e4", "INTEGER"),
    ("debts", "opened_on", "TEXT"), ("debts", "original_amount_e4", "INTEGER"),
  ]

  @Test func aNewDatabaseHasTheColumnsWithoutChecks() throws {
    let stack = try TestSupport.makeStack()
    #expect(try stack.appliedMigrations().contains(Self.name))
    #expect(try stack.appliedMigrations().count >= 32)
    try stack.writer.read { (db: Database) throws in
      for (table, column, type) in Self.columns {
        let found = try #require(try db.columns(in: table).first { $0.name == column })
        #expect(found.type.uppercased() == type, "\(table).\(column)")
        #expect(!found.isNotNull, "\(table).\(column) can stay empty")
        #expect(found.defaultValueSQL == nil, "\(table).\(column) has no default")
        let sql =
          try String.fetchOne(
            db, sql: "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?",
            arguments: [table]) ?? ""
        #expect(!sql.contains("\(column) \(type) CHECK"), "an added column carries no CHECK")
      }
    }
  }

  @Test func aDatabaseOfThePreviousSchemaKeepsEveryValueAndTheColumnsAreEmpty() throws {
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
      for (table, column, _) in Self.columns {
        let filled = try Int.fetchOne(
          db, sql: "SELECT COUNT(*) FROM \(table) WHERE \(column) IS NOT NULL")
        #expect(filled == 0, "\(table).\(column)")
      }
      let assets = try Asset.fetchAll(db)
      #expect(assets.count == 1)
      #expect(assets.allSatisfy { $0.purchasedOn == nil && $0.purchasePriceE4 == nil })
      #expect(assets.allSatisfy { $0.purchase == nil })
      let debts = try Debt.fetchAll(db)
      #expect(debts.count == 2)
      #expect(debts.allSatisfy { $0.openedOn == nil && $0.originalAmountE4 == nil })
      #expect(debts.allSatisfy { $0.opening == nil })
    }
    #expect(try DatabaseCheck.run(stack.writer).isHealthy)
  }

  @Test func theValuesRoundTripThroughTheRecordsAndNoneIsNull() throws {
    let stack = try TestSupport.makeStack()
    try stack.writer.write { db in
      try db.execute(sql: Self.seed)
      try db.execute(sql: Self.filled)
    }
    try stack.writer.read { (db: Database) throws in
      let flat = try #require(try Asset.fetchOne(db, key: Self.flat))
      #expect(flat.purchasedOn == DateOnly(year: 2019, month: 6, day: 14))
      #expect(flat.purchasePriceE4 == AmountE4(whole: 6_500_000))
      #expect(
        flat.purchase
          == AssetPurchase(
            day: DateOnly(year: 2019, month: 6, day: 14), priceE4: AmountE4(whole: 6_500_000),
            currency: .rub))
      let loan = try #require(try Debt.fetchOne(db, key: Self.loan))
      #expect(loan.openedOn == DateOnly(year: 2018, month: 3, day: 1))
      #expect(loan.originalAmountE4 == AmountE4(whole: 4_200_000))
      #expect(loan.opening?.amountE4 == AmountE4(whole: 4_200_000))
      #expect(try Debt.fetchOne(db, key: Self.friend)?.opening == nil)
    }
    // Saving the records back writes the same values, and a row without them stays NULL.
    try stack.writer.write { db in
      for row in try Asset.fetchAll(db) { try row.update(db) }
      for row in try Debt.fetchAll(db) { try row.update(db) }
    }
    try stack.writer.read { (db: Database) throws in
      let asset = try #require(
        try Row.fetchOne(db, sql: "SELECT purchased_on, purchase_price_e4 FROM assets"))
      #expect(asset["purchased_on"] as String? == "2019-06-14")
      #expect(asset["purchase_price_e4"] as Int64? == 65_000_000_000)
      let debts = try Row.fetchAll(
        db, sql: "SELECT opened_on, original_amount_e4 FROM debts ORDER BY id")
      #expect(debts.map { $0["opened_on"] as String? } == ["2018-03-01", nil])
      #expect(debts.map { $0["original_amount_e4"] as Int64? } == [42_000_000_000, nil])
    }
    // Written through the record, one half alone stays as it was typed.
    try stack.writer.write { db in
      var friend = try #require(try Debt.fetchOne(db, key: Self.friend))
      friend.openedOn = DateOnly(year: 2025, month: 12, day: 30)
      try friend.update(db)
    }
    try stack.writer.read { (db: Database) throws in
      let friend = try #require(try Debt.fetchOne(db, key: Self.friend))
      #expect(friend.openedOn == DateOnly(year: 2025, month: 12, day: 30))
      #expect(friend.originalAmountE4 == nil)
      #expect(friend.opening == nil, "a day without a sum is no point to count back from")
    }
    #expect(try DatabaseCheck.run(stack.writer).isHealthy)
  }

  @Test func aValueAHandEditDamagedReadsAsNotSaidAndTheRowStays() async throws {
    let stack = try TestSupport.makeStack()
    try await stack.writer.write { db in
      try db.execute(sql: Self.seed)
      try db.execute(
        sql: """
          UPDATE assets SET purchased_on = 20190614, purchase_price_e4 = 'a lot' WHERE id = '\(Self.flat)';
          UPDATE debts SET opened_on = 'March 2018', original_amount_e4 = 1.5 WHERE id = '\(Self.loan)';
          UPDATE debts SET opened_on = '2018-03-01', original_amount_e4 = -5 WHERE id = '\(Self.friend)';
          """)
    }
    try await stack.writer.read { (db: Database) throws in
      let flat = try #require(try Asset.fetchOne(db, key: Self.flat))
      #expect(flat.name == "Flat")
      #expect(flat.purchasedOn == nil)
      #expect(flat.purchasePriceE4 == nil)
      let loan = try #require(try Debt.fetchOne(db, key: Self.loan))
      #expect(loan.name == "Mortgage")
      #expect(loan.openedOn == nil)
      #expect(loan.opening == nil)
      // A sum below zero is kept as written but is no opening.
      let friend = try #require(try Debt.fetchOne(db, key: Self.friend))
      #expect(friend.openedOn == DateOnly(year: 2018, month: 3, day: 1))
      #expect(friend.opening == nil)
    }
    let dataset = try await DatasetRepository(writer: stack.writer).load(version: 0)
    #expect(dataset.assets.count == 1)
    #expect(dataset.debts.count == 2)
  }

  @Test func theValuesGoLastInTheCSVAndTheNumberOfFilesIsUnchanged() throws {
    #expect(ExportTables.all.count == 60)
    #expect(Array(ExportTables.assets.columns.suffix(2)) == ["purchased_on", "purchase_price"])
    #expect(Array(ExportTables.debts.columns.suffix(2)) == ["opened_on", "original_amount"])
    let stack = try TestSupport.makeStack()
    try stack.writer.write { db in
      try db.execute(sql: Self.seed)
      try db.execute(sql: Self.filled)
    }
    let tables = try ExportRepository(writer: stack.writer).tables()
    func rows(_ table: ExportTable) throws -> [[String: String]] {
      let file = try #require(tables.first { $0.fileName == table.fileName })
      let text = String(decoding: file.data, as: UTF8.self)
      #expect(text.hasPrefix(table.columns.joined(separator: ",")))
      return try CSVReader.dictionaries(from: file.data)
    }
    let assets = try rows(ExportTables.assets)
    #expect(assets.first?["purchased_on"] == "2019-06-14")
    #expect(assets.first?["purchase_price"] == "6500000")
    let debts = try rows(ExportTables.debts)
    let loan = try #require(debts.first { $0["id"]?.lowercased() == Self.loan })
    #expect(loan["opened_on"] == "2018-03-01")
    #expect(loan["original_amount"] == "4200000")
    let friend = try #require(debts.first { $0["id"]?.lowercased() == Self.friend })
    #expect(friend["opened_on"] == "")
    #expect(friend["original_amount"] == "")
  }

  @Test func theValuesTravelToTheOtherDeviceWithTheirRow() throws {
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
    #expect(queued == ["assets", "debts"])
    _ = try mac.exchange.exchange(with: folder)
    _ = try phone.exchange.exchange(with: folder)
    try phone.stack.writer.read { (db: Database) throws in
      let flat = try #require(try Asset.fetchOne(db, key: Self.flat))
      #expect(flat.purchasedOn == DateOnly(year: 2019, month: 6, day: 14))
      #expect(flat.purchasePriceE4 == AmountE4(whole: 6_500_000))
      let loan = try #require(try Debt.fetchOne(db, key: Self.loan))
      #expect(loan.openedOn == DateOnly(year: 2018, month: 3, day: 1))
      #expect(loan.originalAmountE4 == AmountE4(whole: 4_200_000))
    }
    #expect(try mac.books() == phone.books())
    for (_, column, _) in Self.columns {
      #expect(!SyncConflict.isService(column), "\(column) is the owner's choice")
    }
  }

  @Test func theAnonymizedCopyKeepsTheDaysAndTheSums() throws {
    let stack = try TestSupport.makeStack()
    try stack.writer.write { db in
      try db.execute(sql: Self.seed)
      try db.execute(sql: Self.filled)
    }
    try SQLAnonymizer().anonymize(copy: ExportCopyDatabase(writer: stack.writer))
    try stack.writer.read { (db: Database) throws in
      let flat = try #require(try Asset.fetchOne(db, key: Self.flat))
      #expect(flat.name != "Flat", "the name is anonymized")
      #expect(flat.note == nil, "the note goes")
      #expect(flat.purchasedOn == DateOnly(year: 2019, month: 6, day: 14))
      #expect(flat.purchasePriceE4 == AmountE4(whole: 6_500_000))
      let loan = try #require(try Debt.fetchOne(db, key: Self.loan))
      #expect(loan.name != "Mortgage")
      #expect(loan.openedOn == DateOnly(year: 2018, month: 3, day: 1))
      #expect(loan.originalAmountE4 == AmountE4(whole: 4_200_000))
    }
  }
}
