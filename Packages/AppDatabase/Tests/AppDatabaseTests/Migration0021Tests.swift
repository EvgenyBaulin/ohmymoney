import AppCore
import CoreCSV
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

// Synthetic data only.

/// The update to the journal of changes and the bank's monthly choice
/// (`0021_history_and_cashback_choice`) only adds: a database of the previous schema keeps every
/// value, the new columns start empty (no ceiling, no choice), the new tables start empty, and
/// the new rows travel through the records, the CSV and the exchange.
///
/// The previous schema is whatever comes before this file, so the test reads the same whether
/// or not another migration lands between it and 0019.
@Suite("Schema 21 comes in without touching a value")
struct Migration0021Tests {
  static let name = "0021_history_and_cashback_choice"

  private static var older: FilteredSchemaSource {
    let before = TestSupport.migrationNames.filter { $0 < name }
    return FilteredSchemaSource(upTo: before.last ?? "")
  }

  private static func temporaryURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("migration-0021-\(UUID().uuidString).sqlite")
  }

  private static func remove(_ url: URL) {
    for suffix in ["", "-wal", "-shm"] {
      try? FileManager.default.removeItem(atPath: url.path + suffix)
    }
  }

  @Test func aNewDatabaseHasTheTablesAndColumns() throws {
    let stack = try TestSupport.makeStack()
    #expect(try stack.appliedMigrations().contains(Self.name))
    try stack.writer.read { (db: Database) throws in
      for table in ["sync_history", "bank_cashback_categories", "cashback_offers"] {
        #expect(try db.tableExists(table), "\(table)")
      }
      #expect(try db.columns(in: "cashback_rules").map(\.name).contains("monthly_cap_e4"))
      let accountColumns = try db.columns(in: "payment_methods").map(\.name)
      #expect(accountColumns.contains("cashback_monthly_cap_e4"))
      #expect(accountColumns.contains("cashback_choice_day"))
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
        try db.execute(
          sql: """
            INSERT INTO cashback_rules (id, payment_method_id, percent_e4)
            VALUES ('22222222-2222-4222-8222-222222222222',
                    '11111111-1111-4111-8111-111111111111', 10000)
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
    #expect(stack.applied.applied == TestSupport.migrationNames.filter { $0 >= Self.name }.count)
    #expect(stack.applied.dataSteps.isEmpty)
    try stack.writer.read { (db: Database) throws in
      let after = try TestSupport.contents(db, columns: before.mapValues(\.columns))
      for (table, old) in before {
        #expect(after[table] == old, "\(table): every old value is the same byte for byte")
      }
      #expect(
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sync_history") == 0,
        "the journal starts empty")
    }
    let account = try #require(
      try stack.writer.read { db in
        try PaymentMethod.fetchOne(db, key: "11111111-1111-4111-8111-111111111111")
      })
    #expect(account.cashbackMonthlyCapE4 == nil)
    #expect(account.cashbackChoiceDay == nil)
    let rule = try #require(try stack.writer.read { db in try CashbackRule.fetchAll(db).first })
    #expect(rule.monthlyCapE4 == nil)
  }

  @Test func theNewFieldsRoundTripThroughTheRecords() async throws {
    let stack = try TestSupport.makeStack()
    let bank = Bank(name: "Банк")
    let account = PaymentMethod(
      name: "Карта", bankId: bank.id, cashbackMonthlyCapE4: AmountE4(whole: 3_000),
      cashbackChoiceDay: 5)
    let category = CoreKit.Category(kind: .expense, name: "Продукты")
    let rule = CashbackRule(
      accountId: account.id, categoryId: category.id, percent: CashbackPercent(e4: 50_000)!,
      monthlyCapE4: AmountE4(whole: 500))
    let mapping = BankCategoryMapping(
      bankId: bank.id, label: "Супермаркеты", categoryId: category.id)
    let offer = CashbackOffer(
      accountId: account.id, month: MonthKey(year: 2026, month: 11), label: "Супермаркеты",
      percent: CashbackPercent(e4: 50_000)!, chosen: true)
    try await stack.writer.write { db in
      try bank.insert(db)
      try account.insert(db)
      try category.insert(db)
      try rule.insert(db)
      try mapping.insert(db)
      try offer.insert(db)
    }
    try await stack.writer.read { (db: Database) throws in
      #expect(try PaymentMethod.fetchOne(db, key: account.id.uuidString) == account)
      #expect(try CashbackRule.fetchOne(db, key: rule.id.uuidString) == rule)
      #expect(try BankCategoryMapping.fetchOne(db, key: mapping.id.uuidString) == mapping)
      #expect(try CashbackOffer.fetchOne(db, key: offer.id.uuidString) == offer)
    }
    let dataset = try await DatasetRepository(writer: stack.writer).load(version: 1)
    #expect(dataset.cashbackChoice.mappings == [mapping])
    #expect(dataset.cashbackChoice.offers == [offer])
  }

  @Test func aCeilingOrADayThatDoesNotReadIsNone() throws {
    let stack = try TestSupport.makeStack()
    let account = PaymentMethod(name: "Карта")
    try stack.writer.write { db in
      try account.insert(db)
      try db.execute(
        sql: """
          UPDATE payment_methods SET cashback_monthly_cap_e4 = -5, cashback_choice_day = 40
          WHERE id = ?
          """, arguments: [account.id.uuidString])
    }
    let read = try #require(
      try stack.writer.read { db in try PaymentMethod.fetchOne(db, key: account.id.uuidString) })
    #expect(read.cashbackMonthlyCapE4 == nil)
    #expect(read.cashbackChoiceDay == nil)
  }

  @Test func theCSVCarriesTheNewColumnsLastAndTheNewTablesAtTheEnd() throws {
    #expect(ExportTables.cashbackRules.columns.last == "monthly_cap")
    let accountColumns = ExportTables.paymentMethods.columns
    let capAt = try #require(accountColumns.firstIndex(of: "cashback_monthly_cap"))
    #expect(accountColumns[capAt + 1] == "cashback_choice_day")
    #expect(accountColumns.firstIndex(of: "hidden").map { $0 < capAt } == true)
    let names = ExportTables.all.map(\.fileName)
    #expect(names.contains("bank_cashback_categories.csv"))
    #expect(names.dropLast(2).last == "cashback_offers.csv")
    let account = PaymentMethod(
      name: "Карта", cashbackMonthlyCapE4: AmountE4(whole: 3_000), cashbackChoiceDay: 5)
    #expect(Array(ExportTables.row(account)[capAt...(capAt + 1)]) == ["3000", "5"])
    #expect(Array(ExportTables.row(PaymentMethod(name: "Без"))[capAt...(capAt + 1)]) == ["", ""])
    for table in [ExportTables.bankCashbackCategories, ExportTables.cashbackOffers] {
      #expect(!table.columns.contains { $0.hasSuffix("_e4") })
    }
    let offer = CashbackOffer(
      accountId: account.id, month: MonthKey(year: 2026, month: 11), label: "Кафе",
      percent: CashbackPercent(e4: 15_000)!)
    #expect(ExportTables.row(offer).count == ExportTables.cashbackOffers.columns.count)
    #expect(Array(ExportTables.row(offer).suffix(3)) == ["Кафе", "1.5", "false"])
  }

  @Test func theExportWritesTheNewRows() throws {
    let stack = try TestSupport.makeStack()
    let bank = Bank(name: "Банк")
    let category = CoreKit.Category(kind: .expense, name: "Кафе")
    let account = PaymentMethod(name: "Карта", bankId: bank.id)
    try stack.writer.write { db in
      try bank.insert(db)
      try category.insert(db)
      try account.insert(db)
      try BankCategoryMapping(bankId: bank.id, label: "Рестораны", categoryId: category.id)
        .insert(db)
      try CashbackOffer(
        accountId: account.id, month: MonthKey(year: 2026, month: 11), label: "Рестораны",
        percent: CashbackPercent(e4: 50_000)!
      ).insert(db)
    }
    let counts = try ExportRepository(writer: stack.writer).rowCounts()
    #expect(counts["bank_cashback_categories"] == 1)
    #expect(counts["cashback_offers"] == 1)
  }

  @Test func theNewTablesTravelAndTheJournalDoesNot() throws {
    #expect(SyncTables.followed["bank_cashback_categories"] == "id")
    #expect(SyncTables.followed["cashback_offers"] == "id")
    #expect(SyncTables.followed["sync_history"] == nil)
    #expect(SyncTables.bookkeeping.contains("sync_history"))
    #expect(ReadOnlyBarrier.writableTables.contains("sync_history"))
  }

  @Test func theChoiceRepositoryReplacesWhatTheSheetEdits() throws {
    let stack = try TestSupport.makeStack()
    let bank = Bank(name: "Банк")
    let other = Bank(name: "Другой")
    let food = CoreKit.Category(kind: .expense, name: "Продукты")
    let cafes = CoreKit.Category(kind: .expense, name: "Кафе")
    let account = PaymentMethod(name: "Карта", bankId: bank.id)
    try stack.writer.write { db in
      for row in [bank, other] { try row.insert(db) }
      for row in [food, cafes] { try row.insert(db) }
      try account.insert(db)
    }
    let repository = CashbackChoiceRepository(writer: stack.writer)
    let a = BankCategoryMapping(bankId: bank.id, label: "Супермаркеты", categoryId: food.id)
    let b = BankCategoryMapping(bankId: bank.id, label: "Кафе", categoryId: cafes.id)
    let c = BankCategoryMapping(bankId: other.id, label: "Еда", categoryId: food.id)
    try repository.saveMappings([a, b], ofBank: bank.id)
    try repository.saveMappings([c], ofBank: other.id)
    try repository.saveMappings([b], ofBank: bank.id)
    #expect(Set(try repository.book().mappings) == [b, c])
    #expect(throws: CashbackChoiceError.invalid) {
      try repository.saveMappings([c], ofBank: bank.id)
    }
    let november = MonthKey(year: 2026, month: 11)
    let offers = [
      CashbackOffer(
        accountId: account.id, month: november, label: "Кафе", percent: CashbackPercent(e4: 50_000)!
      ),
      CashbackOffer(
        accountId: account.id, month: november, label: "АЗС", percent: CashbackPercent(e4: 30_000)!),
    ]
    try repository.saveOffers(offers, of: account.id, month: november)
    try repository.saveOffers([offers[0]], of: account.id, month: november)
    #expect(try repository.book().offers == [offers[0]])
    #expect(throws: CashbackChoiceError.invalid) {
      try repository.saveOffers(offers, of: account.id, month: november.next)
    }
  }
}
