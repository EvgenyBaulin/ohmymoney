import AppCore
import CoreCSV
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

// Synthetic data only.

/// The update to tax deductions (`0029_tax_deductions`) only adds three columns: a database of the
/// previous schema keeps every value, and the new columns start empty. They travel through the
/// records, the CSV, the archive's database and the exchange; the anonymized copy keeps them, and
/// a value this build does not know reads as none and is named by the check of the database.
///
/// The previous schema is whatever comes before this file, so the test reads the same whether or
/// not another migration lands after it.
@Suite("Schema 29 comes in without touching a value")
struct Migration0029Tests {
  static let name = "0029_tax_deductions"
  static let account = "71717171-7171-4717-8717-717171717171"
  static let iis = "72727272-7272-4727-8727-727272727272"
  static let category = "73737373-7373-4737-8737-737373737373"
  static let operation = "74747474-7474-4747-8747-747474747474"
  static let part = "75757575-7575-4757-8757-757575757575"
  static let other = "76767676-7676-4767-8767-767676767676"
  static let debt = "77777777-7777-4777-8777-777777777777"

  private static var older: FilteredSchemaSource {
    let before = TestSupport.migrationNames.filter { $0 < name }
    return FilteredSchemaSource(upTo: before.last ?? "")
  }

  private static func temporaryURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("migration-0029-\(UUID().uuidString).sqlite")
  }

  private static func remove(_ url: URL) {
    for suffix in ["", "-wal", "-shm"] {
      try? FileManager.default.removeItem(atPath: url.path + suffix)
    }
  }

  /// Two accounts, a category, an operation of two parts and a loan, as schema 28 wrote them.
  private static let seed = """
    INSERT INTO payment_methods (id, name) VALUES ('\(account)', 'Card');
    INSERT INTO payment_methods (id, name, kind) VALUES ('\(iis)', 'Broker', 'account');
    INSERT INTO categories (id, kind, name) VALUES ('\(category)', 'expense', 'Pharmacy');
    INSERT INTO transactions
      (id, kind, occurred_at, amount_e4, amount_rub_e4, note, created_at, updated_at)
    VALUES ('\(operation)', 'expense', '2026-10-20 10:00:00.000', 3000000, 3000000, 'pharmacy',
            '2026-10-20 10:00:00.000', '2026-10-20 10:00:00.000');
    INSERT INTO transaction_parts (id, transaction_id, category_id, amount_e4, amount_rub_e4)
      VALUES ('\(part)', '\(operation)', '\(category)', 2000000, 2000000);
    INSERT INTO transaction_parts (id, transaction_id, category_id, amount_e4, amount_rub_e4)
      VALUES ('\(other)', '\(operation)', '\(category)', 1000000, 1000000);
    INSERT INTO debts (id, direction, type, name, monthly_payment_e4, payment_day)
      VALUES ('\(debt)', 'i_owe', 'loan', 'Flat', 500000000, 10);
    """

  private static let filled = """
    UPDATE transaction_parts SET tax_deduction = 'medical' WHERE id = '\(part)';
    UPDATE debts SET tax_deduction = 'mortgage_interest' WHERE id = '\(debt)';
    UPDATE payment_methods SET tax_deduction = 'iis' WHERE id = '\(iis)';
    """

  private static let tables = ["transaction_parts", "debts", "payment_methods"]

  @Test func aNewDatabaseHasTheColumnsWithoutChecks() throws {
    let stack = try TestSupport.makeStack()
    #expect(try stack.appliedMigrations().contains(Self.name))
    #expect(try stack.appliedMigrations().count >= 29)
    try stack.writer.read { (db: Database) throws in
      for table in Self.tables {
        let found = try #require(try db.columns(in: table).first { $0.name == "tax_deduction" })
        #expect(found.type.uppercased() == "TEXT", "\(table)")
        #expect(!found.isNotNull, "\(table).tax_deduction can stay empty")
        let sql =
          try String.fetchOne(
            db, sql: "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?",
            arguments: [table]) ?? ""
        #expect(!sql.contains("tax_deduction TEXT CHECK"), "an added column carries no CHECK")
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
      for table in Self.tables {
        let filled = try Int.fetchOne(
          db, sql: "SELECT COUNT(*) FROM \(table) WHERE tax_deduction IS NOT NULL")
        #expect(filled == 0, "\(table)")
      }
      #expect(try TransactionPart.fetchAll(db).allSatisfy { $0.taxDeduction == nil })
      #expect(try Debt.fetchAll(db).allSatisfy { $0.taxDeduction == nil })
      #expect(try PaymentMethod.fetchAll(db).allSatisfy { $0.taxDeduction == nil })
    }
    #expect(try DatabaseCheck.run(stack.writer).isHealthy)
  }

  @Test func theKindsRoundTripThroughTheRecordsAndNoneIsNull() throws {
    let stack = try TestSupport.makeStack()
    try stack.writer.write { db in
      try db.execute(sql: Self.seed)
      try db.execute(sql: Self.filled)
    }
    try stack.writer.read { (db: Database) throws in
      #expect(try TransactionPart.fetchOne(db, key: Self.part)?.taxDeduction == .medical)
      #expect(try TransactionPart.fetchOne(db, key: Self.other)?.taxDeduction == nil)
      #expect(try Debt.fetchOne(db, key: Self.debt)?.taxDeduction == .mortgageInterest)
      #expect(try PaymentMethod.fetchOne(db, key: Self.iis)?.taxDeduction == .iis)
      #expect(try PaymentMethod.fetchOne(db, key: Self.account)?.taxDeduction == nil)
    }
    // Saving the records back writes the same text, and a row without a kind stays NULL.
    try stack.writer.write { db in
      for row in try TransactionPart.fetchAll(db) { try row.update(db) }
      for row in try Debt.fetchAll(db) { try row.update(db) }
      for row in try PaymentMethod.fetchAll(db) { try row.update(db) }
    }
    let parts = try stack.writer.read { db in
      try String?.fetchAll(db, sql: "SELECT tax_deduction FROM transaction_parts ORDER BY id")
    }
    #expect(parts == ["medical", nil])
    // Every kind of a part goes in and comes back.
    for kind in TaxDeductionKind.partKinds {
      try stack.writer.write { db in
        var row = try #require(try TransactionPart.fetchOne(db, key: Self.other))
        row.taxDeduction = kind
        try row.update(db)
      }
      let stored = try stack.writer.read { db in
        try String.fetchOne(
          db, sql: "SELECT tax_deduction FROM transaction_parts WHERE id = ?",
          arguments: [Self.other])
      }
      #expect(stored == kind.rawValue)
    }
    #expect(try DatabaseCheck.run(stack.writer).isHealthy)
  }

  @Test func aKindThisBuildDoesNotKnowIsNoneAndTheCheckNamesIt() throws {
    let stack = try TestSupport.makeStack()
    try stack.writer.write { db in
      try db.execute(sql: Self.seed)
      try db.execute(
        sql: """
          UPDATE transaction_parts SET tax_deduction = 'charity' WHERE id = '\(Self.part)';
          UPDATE transaction_parts SET tax_deduction = 7 WHERE id = '\(Self.other)';
          UPDATE debts SET tax_deduction = 'medical' WHERE id = '\(Self.debt)';
          UPDATE payment_methods SET tax_deduction = 'mortgage_interest'
            WHERE id = '\(Self.iis)';
          """)
    }
    try stack.writer.read { (db: Database) throws in
      #expect(try TransactionPart.fetchAll(db).allSatisfy { $0.taxDeduction == nil })
      #expect(try Debt.fetchOne(db, key: Self.debt)?.taxDeduction == nil)
      #expect(try PaymentMethod.fetchOne(db, key: Self.iis)?.taxDeduction == nil)
    }
    let report = try DatabaseCheck.run(stack.writer)
    let found = report.findings.filter { $0.rule == .taxDeductionUnknown }
    #expect(Set(found.compactMap(\.table)) == Set(Self.tables))
    #expect(found.allSatisfy { !$0.isRepairable })
    let parts = try #require(found.first { $0.table == "transaction_parts" })
    #expect(parts.count == 2)
    #expect(Set(parts.ids.map { $0.lowercased() }) == [Self.part, Self.other])
  }

  @Test func theKindsGoLastInTheCSVAndTheNumberOfFilesIsUnchanged() throws {
    #expect(ExportTables.all.count == 59)
    #expect(ExportTables.transactionParts.columns.last == "tax_deduction")
    #expect(ExportTables.debts.columns.dropLast(2).last == "tax_deduction")
    #expect(ExportTables.paymentMethods.columns.last == "tax_deduction")
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
    let parts = try rows(ExportTables.transactionParts)
    #expect(parts.first { $0["id"]?.lowercased() == Self.part }?["tax_deduction"] == "medical")
    #expect(parts.first { $0["id"]?.lowercased() == Self.other }?["tax_deduction"] == "")
    let debts = try rows(ExportTables.debts)
    #expect(debts.first?["tax_deduction"] == "mortgage_interest")
    let accounts = try rows(ExportTables.paymentMethods)
    #expect(accounts.first { $0["id"]?.lowercased() == Self.iis }?["tax_deduction"] == "iis")
    #expect(accounts.first { $0["id"]?.lowercased() == Self.account }?["tax_deduction"] == "")
  }

  @Test func theKindsTravelToTheOtherDeviceWithTheirRow() throws {
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
    #expect(queued == ["debts", "payment_methods", "transaction_parts"])
    _ = try mac.exchange.exchange(with: folder)
    _ = try phone.exchange.exchange(with: folder)
    try phone.stack.writer.read { (db: Database) throws in
      #expect(try TransactionPart.fetchOne(db, key: Self.part)?.taxDeduction == .medical)
      #expect(try Debt.fetchOne(db, key: Self.debt)?.taxDeduction == .mortgageInterest)
      #expect(try PaymentMethod.fetchOne(db, key: Self.iis)?.taxDeduction == .iis)
    }
    #expect(try mac.books() == phone.books())
    #expect(!SyncConflict.isService("tax_deduction"))
  }

  @Test func theIncomeOfAYearLivesInTheSettingsAndGoesAwayWhenCleared() throws {
    let stack = try TestSupport.makeStack()
    let settings = SettingsRepository(writer: stack.writer)
    let key = TaxDeductionIncome.key(2026)
    #expect(try settings.string(key) == nil)
    try settings.set(key, to: TaxDeductionIncome.text(AmountE4(whole: 1_200_000)))
    #expect(TaxDeductionIncome.income(from: try settings.string(key)) == AmountE4(whole: 1_200_000))
    try settings.remove(key)
    #expect(try settings.string(key) == nil)
    // The key of another year stays where it was.
    try settings.set(TaxDeductionIncome.key(2025), to: "900000")
    try settings.remove(key)
    #expect(try settings.string(TaxDeductionIncome.key(2025)) == "900000")
  }

  @Test func theAnonymizedCopyKeepsTheKinds() throws {
    let stack = try TestSupport.makeStack()
    try stack.writer.write { db in
      try db.execute(sql: Self.seed)
      try db.execute(sql: Self.filled)
    }
    try SQLAnonymizer().anonymize(copy: ExportCopyDatabase(writer: stack.writer))
    try stack.writer.read { (db: Database) throws in
      #expect(try TransactionPart.fetchOne(db, key: Self.part)?.taxDeduction == .medical)
      #expect(try Debt.fetchOne(db, key: Self.debt)?.taxDeduction == .mortgageInterest)
      #expect(try PaymentMethod.fetchOne(db, key: Self.iis)?.taxDeduction == .iis)
    }
  }
}
