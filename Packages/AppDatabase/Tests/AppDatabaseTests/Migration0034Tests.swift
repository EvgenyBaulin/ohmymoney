import AppCore
import CoreCSV
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

// Synthetic data only.

/// The answers for single dues of recurring incomes (`0034_expected_income_dues`) only add a
/// table: a database of the previous schema keeps every value and has no answer. An answer is
/// written and undone with the planning change that writes it, goes away with its income, travels
/// through the CSV and the exchange — one row per due on both devices —, stays in the anonymized
/// copy and is cut by its due in a copy of a period.
///
/// The previous schema is whatever comes before this file, so the test reads the same whether or
/// not another migration lands after it.
@Suite("Schema 34 comes in without touching a value")
struct Migration0034Tests {
  static let name = "0034_expected_income_dues"
  static let income = "A3434343-3434-4343-8434-343434343434"
  static let incomeId = UUID(uuidString: income)!
  static let september = DateOnly(year: 2026, month: 9, day: 5)
  static let october = DateOnly(year: 2026, month: 10, day: 5)

  private static var older: FilteredSchemaSource {
    let before = TestSupport.migrationNames.filter { $0 < name }
    return FilteredSchemaSource(upTo: before.last ?? "")
  }

  private static func temporaryURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("migration-0034-\(UUID().uuidString).sqlite")
  }

  private static func remove(_ url: URL) {
    for suffix in ["", "-wal", "-shm"] {
      try? FileManager.default.removeItem(atPath: url.path + suffix)
    }
  }

  /// A salary every 5th, as schema 33 wrote it.
  private static let seed = """
    INSERT INTO expected_income (id, name, kind, total_e4, currency, due_date, freq, day,
      parts_expected, closed)
      VALUES ('\(income)', 'Salary', 'recurring', 1000000000, 'RUB', '2026-08-05', 'monthly', 5,
        1, 0);
    """

  private static var salary: ExpectedIncome {
    ExpectedIncome(
      id: incomeId, name: "Salary", kind: .recurring, totalE4: AmountE4(whole: 100_000),
      dueDate: DateOnly(year: 2026, month: 8, day: 5), freq: .monthly, day: 5)
  }

  private static var skipped: ExpectedIncomeDue {
    ExpectedIncomeDue(expectedIncomeId: incomeId, due: september)
  }

  private static var moved: ExpectedIncomeDue {
    ExpectedIncomeDue(
      expectedIncomeId: incomeId, due: october, movedTo: DateOnly(year: 2026, month: 10, day: 12))
  }

  private static func write(
    _ dues: [ExpectedIncomeDue], to stack: DatabaseStack
  ) throws
    -> PlanningUndo
  {
    try PlanningRepository(writer: stack.writer).apply(
      PlanningChange(upsert: PlanningRows(expectedDues: dues)))
  }

  @Test func aNewDatabaseHasTheTableWithItsKeyAndTriggers() throws {
    let stack = try TestSupport.makeStack()
    #expect(try stack.appliedMigrations().last == Self.name)
    try stack.writer.read { (db: Database) throws in
      let columns = try db.columns(in: "expected_income_dues")
      #expect(columns.map(\.name) == ["id", "expected_income_id", "due_on", "moved_to"])
      #expect(columns.allSatisfy { $0.type.uppercased() == "TEXT" })
      #expect(columns.first { $0.name == "moved_to" }?.isNotNull == false)
      let indexes = try db.indexes(on: "expected_income_dues")
      #expect(
        indexes.contains { $0.isUnique && $0.columns == ["expected_income_id", "due_on"] })
      let triggers = try String.fetchAll(
        db,
        sql: """
          SELECT name FROM sqlite_master WHERE type = 'trigger' AND tbl_name = ? ORDER BY name
          """, arguments: ["expected_income_dues"])
      #expect(
        triggers == [
          "sync_expected_income_dues_delete", "sync_expected_income_dues_insert",
          "sync_expected_income_dues_update",
        ])
    }
    #expect(SyncTables.followed["expected_income_dues"] == "id")
    #expect(DatabaseStack.ledgerTables.contains("expected_income_dues"))
  }

  @Test func aDatabaseOfThePreviousSchemaKeepsEveryValueAndHasNoAnswer() throws {
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
      #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM expected_income_dues") == 0)
    }
    let book = try PlanningRepository(writer: stack.writer).book()
    #expect(book.expectedDues.isEmpty)
    #expect(book.expected.map(\.id) == [Self.incomeId])
    #expect(try DatabaseCheck.run(stack.writer).isHealthy)
  }

  /// An answer is one planning change and one step of undo; a second answer for the same due
  /// writes the same row; the book reads them back.
  @Test func anAnswerIsWrittenReadAndUndone() throws {
    let stack = try TestSupport.makeStack()
    try stack.writer.write { db in try db.execute(sql: Self.seed) }
    let repository = PlanningRepository(writer: stack.writer)
    let first = try Self.write([Self.skipped], to: stack)
    #expect(try repository.book().expectedDues == [Self.skipped])
    var again = Self.skipped
    again.movedTo = DateOnly(year: 2026, month: 9, day: 20)
    let second = try Self.write([again], to: stack)
    #expect(try repository.book().expectedDues == [again])
    try repository.revert(second)
    #expect(try repository.book().expectedDues == [Self.skipped])
    try repository.revert(first)
    #expect(try repository.book().expectedDues.isEmpty)
    #expect(try DatabaseCheck.run(stack.writer).isHealthy)
  }

  /// The answers go with their income, and undoing the deletion brings them back.
  @Test func theAnswersGoWithTheirIncomeAndComeBackWithIt() throws {
    let stack = try TestSupport.makeStack()
    try stack.writer.write { db in try db.execute(sql: Self.seed) }
    let repository = PlanningRepository(writer: stack.writer)
    _ = try Self.write([Self.skipped, Self.moved], to: stack)
    let deletion = try repository.apply(
      PlanningChange(delete: PlanningRowIDs(expected: [Self.incomeId])))
    #expect(try repository.book().expectedDues.isEmpty)
    try repository.revert(deletion)
    #expect(Set(try repository.book().expectedDues) == [Self.skipped, Self.moved])
  }

  /// A day that is not a day leaves that answer out — the due waits as if unanswered — and the
  /// rest of the book reads.
  @Test func anUnreadableAnswerIsLeftOut() throws {
    let stack = try TestSupport.makeStack()
    try stack.writer.write { db in try db.execute(sql: Self.seed) }
    _ = try Self.write([Self.skipped], to: stack)
    try stack.writer.write { db in
      try db.execute(
        sql: """
          INSERT INTO expected_income_dues (id, expected_income_id, due_on, moved_to)
          VALUES ('\(UUID().uuidString)', '\(Self.income)', '2026-10-05', 'soon'),
                 ('\(UUID().uuidString)', '\(Self.income)', 'October', NULL)
          """)
    }
    #expect(try PlanningRepository(writer: stack.writer).book().expectedDues == [Self.skipped])
  }

  @Test func theAnswersAreTheLastFileOfTheCSV() throws {
    #expect(ExportTables.all.count == 60)
    #expect(ExportTables.all.last == ExportTables.expectedIncomeDues)
    let stack = try TestSupport.makeStack()
    try stack.writer.write { db in try db.execute(sql: Self.seed) }
    _ = try Self.write([Self.skipped, Self.moved], to: stack)
    let tables = try ExportRepository(writer: stack.writer).tables()
    let file = try #require(tables.first { $0.fileName == "expected_income_dues.csv" })
    let text = String(decoding: file.data, as: UTF8.self)
    #expect(text.hasPrefix("id,expected_income_id,due_on,moved_to"))
    let rows = try CSVReader.dictionaries(from: file.data)
    #expect(rows.map { $0["due_on"] } == ["2026-09-05", "2026-10-05"])
    #expect(rows.map { $0["moved_to"] } == ["", "2026-10-12"])
  }

  /// An answer travels to the other device, and a later answer there comes back over it.
  @Test func anAnswerTravelsBothWays() throws {
    let mac = try TestDevice("mac")
    let phone = try TestDevice("phone")
    let folder = InMemoryFolder()
    try mac.sql(Self.seed)
    _ = try mac.exchange.exchange(with: folder)
    _ = try phone.exchange.exchange(with: folder)
    _ = try Self.write([Self.skipped], to: mac.stack)
    let queued = try mac.stack.writer.read { (db: Database) throws in
      try String.fetchAll(db, sql: "SELECT DISTINCT table_name FROM sync_outbox ORDER BY 1")
    }
    #expect(queued == ["expected_income_dues"])
    _ = try mac.exchange.exchange(with: folder)
    _ = try phone.exchange.exchange(with: folder)
    #expect(
      try PlanningRepository(writer: phone.stack.writer).book().expectedDues == [Self.skipped])
    var later = Self.skipped
    later.movedTo = DateOnly(year: 2026, month: 9, day: 25)
    _ = try Self.write([later], to: phone.stack)
    _ = try phone.exchange.exchange(with: folder)
    _ = try mac.exchange.exchange(with: folder)
    #expect(try PlanningRepository(writer: mac.stack.writer).book().expectedDues == [later])
    #expect(try mac.books() == phone.books())
  }

  /// The same due answered on both devices before either saw the other is one row of the
  /// exchange (its id is made from the income and the due): it meets as one record — an edit
  /// against an edit, as for any row — and never as a second row the pair's uniqueness refuses
  /// and the exchange would put off for ever.
  @Test func theSameDueAnsweredOnBothDevicesIsOneRow() throws {
    let mac = try TestDevice("mac")
    let phone = try TestDevice("phone")
    let folder = InMemoryFolder()
    try mac.sql(Self.seed)
    _ = try mac.exchange.exchange(with: folder)
    _ = try phone.exchange.exchange(with: folder)
    _ = try Self.write([Self.skipped], to: mac.stack)
    var other = Self.skipped
    other.movedTo = DateOnly(year: 2026, month: 9, day: 25)
    _ = try Self.write([other], to: phone.stack)
    #expect(other.id == Self.skipped.id)
    for _ in 0..<2 {
      _ = try mac.exchange.exchange(with: folder)
      _ = try phone.exchange.exchange(with: folder)
    }
    #expect(try mac.count("expected_income_dues") == 1)
    #expect(try phone.count("expected_income_dues") == 1)
    #expect(try mac.count("sync_deferred") == 0)
    #expect(try phone.count("sync_deferred") == 0)
    // The two answers met as an edit against an edit: «Конфликты» shows it, nothing diverges
    // unseen.
    let open = try mac.exchange.conflicts().count + phone.exchange.conflicts().count
    #expect(open >= 1)
  }

  @Test func theAnonymizedCopyKeepsTheAnswers() throws {
    let stack = try TestSupport.makeStack()
    try stack.writer.write { db in try db.execute(sql: Self.seed) }
    _ = try Self.write([Self.skipped, Self.moved], to: stack)
    try SQLAnonymizer().anonymize(copy: ExportCopyDatabase(writer: stack.writer))
    let book = try PlanningRepository(writer: stack.writer).book()
    #expect(book.expected.first?.name != "Salary", "the name goes")
    #expect(Set(book.expectedDues) == [Self.skipped, Self.moved])
  }

  /// «Экспорт копии» of a period keeps the answers for dues inside it only.
  @Test func aCopyOfAPeriodCutsTheAnswersByTheirDue() throws {
    let october = DayRange(
      DateOnly(year: 2026, month: 10, day: 1), DateOnly(year: 2026, month: 10, day: 31))
    let stack = try TestSupport.makeStack()
    try stack.writer.write { db in try db.execute(sql: Self.seed) }
    _ = try Self.write([Self.skipped, Self.moved], to: stack)
    try stack.writer.write { db in
      try ExportCopyMaker.cut(ExportCopyRequest(scope: .period(october), password: "pw"), db: db)
    }
    #expect(try PlanningRepository(writer: stack.writer).book().expectedDues == [Self.moved])
  }

  /// An income planned on a hidden account leaves the copy, its answers with it.
  @Test func aCopyWithoutHiddenAccountsDropsTheAnswersOfTheirIncomes() throws {
    let stack = try TestSupport.makeStack()
    let hidden = "A3434343-0000-4343-8434-000000000001"
    try stack.writer.write { db in
      try db.execute(
        sql: """
          INSERT INTO payment_methods (id, name, kind, is_default, archived, hidden)
            VALUES ('\(hidden)', 'Hidden', 'card', 0, 0, 1);
          """)
      try db.execute(sql: Self.seed)
      try db.execute(
        sql: "UPDATE expected_income SET payment_method_id = ? WHERE id = ?",
        arguments: [hidden, Self.income])
    }
    _ = try Self.write([Self.skipped], to: stack)
    try stack.writer.write { db in
      try ExportCopyMaker.cut(
        ExportCopyRequest(scope: .whole, includeHidden: false, password: "pw"), db: db)
    }
    try stack.writer.read { (db: Database) throws in
      #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM expected_income_dues") == 0)
    }
  }

  /// An answer whose income is gone (written with foreign keys off) is an orphan the check
  /// repairs: it answers for nothing.
  @Test func anOrphanAnswerIsRepairable() throws {
    #expect(DatabaseCheck.repairableTables.contains("expected_income_dues"))
  }
}
