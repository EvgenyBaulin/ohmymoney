import AppCore
import CoreCSV
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

// Synthetic data only.

/// The update to the dates of a split's payments and the minimum payments of a credit card
/// (`0025_split_dates_and_credit_statements`) only adds: a database of the previous schema keeps
/// every value and every step reads as having no date of its own. The new column and the new table
/// travel through the records, the CSV, the archive's database and the exchange.
///
/// The previous schema is whatever comes before this file, so the test reads the same whether
/// or not another migration lands after it.
@Suite("Schema 25 comes in without touching a value")
struct Migration0025Tests {
  static let name = "0025_split_dates_and_credit_statements"
  static let debt = "44444444-4444-4444-8444-444444444444"
  static let account = "55555555-5555-4555-8555-555555555555"

  private static var older: FilteredSchemaSource {
    let before = TestSupport.migrationNames.filter { $0 < name }
    return FilteredSchemaSource(upTo: before.last ?? "")
  }

  private static func temporaryURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("migration-0025-\(UUID().uuidString).sqlite")
  }

  private static func remove(_ url: URL) {
    for suffix in ["", "-wal", "-shm"] {
      try? FileManager.default.removeItem(atPath: url.path + suffix)
    }
  }

  private static let seed = """
    INSERT INTO payment_methods (id, name) VALUES ('\(account)', 'Credit');
    INSERT INTO debts (id, direction, type, name) VALUES ('\(debt)', 'i_owe', 'installment', 'Plan');
    INSERT INTO debt_instalments (id, debt_id, from_index, amount_e4)
    VALUES ('66666666-6666-4666-8666-666666666666', '\(debt)', 0, 20000000);
    """

  @Test func aNewDatabaseHasTheColumnTheTableAndTheKey() throws {
    let stack = try TestSupport.makeStack()
    #expect(try stack.appliedMigrations().contains(Self.name))
    #expect(try stack.appliedMigrations().count >= 25)
    try stack.writer.read { (db: Database) throws in
      let column = try #require(
        try db.columns(in: "debt_instalments").first { $0.name == "due_on" })
      #expect(column.type.uppercased() == "TEXT")
      #expect(!column.isNotNull)
      let sql =
        try String.fetchOne(
          db, sql: "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'debt_instalments'")
        ?? ""
      #expect(!sql.contains("due_on TEXT CHECK"), "an added column carries no CHECK")
      let names = try db.columns(in: "credit_statements").map(\.name)
      #expect(
        names == ["id", "payment_method_id", "statement_on", "minimum_e4", "pay_by"])
      let index = try String.fetchOne(
        db,
        sql: "SELECT sql FROM sqlite_master WHERE type = 'index' AND name = 'idx_credit_statements_key'"
      )
      #expect(index?.contains("UNIQUE") == true)
      let triggers = try String.fetchAll(
        db,
        sql: "SELECT name FROM sqlite_master WHERE type = 'trigger' AND tbl_name = 'credit_statements' ORDER BY name"
      )
      #expect(
        triggers == [
          "sync_credit_statements_delete", "sync_credit_statements_insert",
          "sync_credit_statements_update",
        ])
    }
  }

  @Test func aDatabaseOfThePreviousSchemaKeepsEveryValueAndHasNoDates() throws {
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
      let step = try #require(try DebtInstalmentStep.fetchAll(db).first)
      #expect(step.dueOn == nil && step.amountE4 == AmountE4(whole: 2000))
      #expect(try CreditStatementRepository.all(db).isEmpty)
    }
  }

  @Test func theDateOfAStepRoundTripsAndAnEditedStepKeepsItsOwn() throws {
    let stack = try TestSupport.makeStack()
    try stack.writer.write { db in try db.execute(sql: Self.seed) }
    let id = try #require(UUID(uuidString: Self.debt))
    let dated = DebtInstalmentStep(
      debtId: id, fromIndex: 1, amountE4: AmountE4(whole: 2500),
      dueOn: DateOnly(year: 2026, month: 12, day: 7))
    try stack.writer.write { db in try dated.save(db) }
    let read = try stack.writer.read { (db: Database) throws in
      try DebtInstalmentStep.fetchAll(db).sorted { $0.fromIndex < $1.fromIndex }
    }
    #expect(read.map(\.dueOn) == [nil, DateOnly(year: 2026, month: 12, day: 7)])
    #expect(read[1] == dated)
  }

  @Test func aStatementRoundTripsThroughThePlanningAndUndoGivesItBack() throws {
    let stack = try TestSupport.makeStack()
    try stack.writer.write { db in try db.execute(sql: Self.seed) }
    let accountId = try #require(UUID(uuidString: Self.account))
    let closes = DateOnly(year: 2026, month: 11, day: 5)
    let first = CreditStatementOverride(
      accountId: accountId, closesOn: closes, minimumE4: AmountE4(whole: 3100),
      due: DateOnly(year: 2026, month: 11, day: 25))
    let repository = CreditStatementRepository(stack: stack)
    let planning = PlanningRepository(writer: stack.writer)
    var change = PlanningChange()
    change.upsert.creditStatements = [first]
    _ = try planning.apply(change)
    #expect(try repository.all() == [first])

    // The same statement typed again goes over the row, so the pair stays one row.
    let plan = try CreditMinimumRules.saving(
      CreditStatementOverride(
        accountId: accountId, closesOn: closes, minimumE4: AmountE4(whole: 3300),
        due: DateOnly(year: 2026, month: 11, day: 26)),
      accountId: accountId, closesOn: closes, among: try repository.all())
    var again = PlanningChange()
    again.upsert.creditStatements = [try #require(plan.upsert)]
    let undo = try planning.apply(again)
    let rows = try repository.all()
    #expect(rows.count == 1 && rows[0].id == first.id)
    #expect(rows[0].minimumE4 == AmountE4(whole: 3300))
    _ = try planning.revert(undo)
    #expect(try repository.all() == [first])

    // Taking it away is a delete of that row, and undo gives it back.
    let gone = try CreditMinimumRules.saving(
      nil, accountId: accountId, closesOn: closes, among: [first])
    var removal = PlanningChange()
    removal.delete.creditStatements = [try #require(gone.deleteId)]
    let removed = try planning.apply(removal)
    #expect(try repository.all().isEmpty)
    _ = try planning.revert(removed)
    #expect(try repository.all() == [first])
  }

  @Test func twoRowsOfOneStatementAreRefusedAndADeletedAccountTakesItsStatementsAlong() throws {
    let stack = try TestSupport.makeStack()
    try stack.writer.write { db in try db.execute(sql: Self.seed) }
    func insert(_ id: String) throws {
      try stack.writer.write { db in
        try db.execute(
          sql: """
            INSERT INTO credit_statements (id, payment_method_id, statement_on, minimum_e4, pay_by)
            VALUES (?, ?, '2026-11-05', 1000000, '2026-11-25')
            """, arguments: [id, Self.account])
      }
    }
    try insert("77777777-7777-4777-8777-777777777777")
    #expect(throws: GRDB.DatabaseError.self) { try insert("88888888-8888-4888-8888-888888888888") }
    try stack.writer.write { db in
      try db.execute(sql: "DELETE FROM payment_methods WHERE id = ?", arguments: [Self.account])
    }
    #expect(try CreditStatementRepository(stack: stack).all().isEmpty)
  }

  @Test func theNewTableAndColumnGoLastInTheCSVAndTheFilesAreFiftyFour() throws {
    #expect(ExportTables.all.count == 54)
    #expect(ExportTables.all.last == ExportTables.creditStatements)
    #expect(Array(ExportTables.debtInstalments.columns.suffix(1)) == ["due_on"])
    let id = UUID()
    let step = DebtInstalmentStep(
      debtId: id, fromIndex: 2, amountE4: AmountE4(whole: 10),
      dueOn: DateOnly(year: 2026, month: 12, day: 7))
    #expect(Array(ExportTables.row(step).suffix(2)) == ["10", "2026-12-07"])
    #expect(ExportTables.row(DebtInstalmentStep(debtId: id, fromIndex: 2, amountE4: .zero)).last == "")
    let statement = CreditStatementOverride(
      accountId: id, closesOn: DateOnly(year: 2026, month: 11, day: 5),
      minimumE4: AmountE4(whole: 3100), due: DateOnly(year: 2026, month: 11, day: 25))
    let row = ExportTables.row(statement)
    #expect(row.count == ExportTables.creditStatements.columns.count)
    #expect(Array(row.suffix(3)) == ["2026-11-05", "3100", "2026-11-25"])
  }

  @Test func theExportOfTheDatabaseWritesBoth() throws {
    let stack = try TestSupport.makeStack()
    try stack.writer.write { db in
      try db.execute(sql: Self.seed)
      try db.execute(
        sql: """
          INSERT INTO credit_statements (id, payment_method_id, statement_on, minimum_e4, pay_by)
          VALUES ('77777777-7777-4777-8777-777777777777', '\(Self.account)', '2026-11-05', 31000000, '2026-11-25');
          UPDATE debt_instalments SET due_on = '2026-11-15';
          """)
    }
    let tables = try ExportRepository(writer: stack.writer).tables()
    let statements = try #require(
      tables.first { $0.fileName == ExportTables.creditStatements.fileName })
    let text = String(decoding: statements.data, as: UTF8.self)
    #expect(text.hasPrefix(ExportTables.creditStatements.columns.joined(separator: ",")))
    #expect(text.contains("2026-11-05,3100,2026-11-25"))
    let instalments = try #require(
      tables.first { $0.fileName == ExportTables.debtInstalments.fileName })
    #expect(String(decoding: instalments.data, as: UTF8.self).contains("2000,2026-11-15"))
  }

  @Test func theNewTableIsFollowedByTheExchangeAndTravelsToTheOtherDevice() throws {
    #expect(SyncTables.followed["credit_statements"] == "id")
    let mac = try TestDevice("mac")
    let phone = try TestDevice("phone")
    let folder = InMemoryFolder()
    try mac.sql(Self.seed)
    try mac.sql(
      """
      INSERT INTO credit_statements (id, payment_method_id, statement_on, minimum_e4, pay_by)
      VALUES ('77777777-7777-4777-8777-777777777777', '\(Self.account)', '2026-11-05', 31000000, '2026-11-25');
      UPDATE debt_instalments SET due_on = '2026-11-15';
      """)
    let queued = try mac.stack.writer.read { (db: Database) throws in
      try String.fetchAll(
        db, sql: "SELECT DISTINCT table_name FROM sync_outbox ORDER BY 1")
    }
    #expect(queued.contains("credit_statements") && queued.contains("debt_instalments"))
    _ = try mac.exchange.exchange(with: folder)
    _ = try phone.exchange.exchange(with: folder)
    try phone.stack.writer.read { (db: Database) throws in
      let statement = try #require(try CreditStatementRepository.all(db).first)
      #expect(statement.minimumE4 == AmountE4(whole: 3100))
      #expect(
        try String.fetchOne(db, sql: "SELECT due_on FROM debt_instalments") == "2026-11-15")
    }
  }

  @Test func theAnonymizedCopyKeepsTheStatementsAndTheDates() throws {
    let stack = try TestSupport.makeStack()
    try stack.writer.write { db in
      try db.execute(sql: Self.seed)
      try db.execute(
        sql: """
          INSERT INTO credit_statements (id, payment_method_id, statement_on, minimum_e4, pay_by)
          VALUES ('77777777-7777-4777-8777-777777777777', '\(Self.account)', '2026-11-05', 31000000, '2026-11-25');
          UPDATE debt_instalments SET due_on = '2026-11-15';
          """)
    }
    try SQLAnonymizer().anonymize(copy: ExportCopyDatabase(writer: stack.writer))
    try stack.writer.read { (db: Database) throws in
      #expect(try CreditStatementRepository.all(db).count == 1)
      #expect(
        try String.fetchOne(db, sql: "SELECT due_on FROM debt_instalments") == "2026-11-15")
    }
  }
}
