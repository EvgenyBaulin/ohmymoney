import AppCore
import CoreKit
import Foundation
import GRDB

@testable import AppDatabase

/// The tests read the very same `Schema/*.sql` files that ship inside the app bundle,
/// so a migration that works here is the migration the app applies.
enum TestSupport {
  static var schemaDirectory: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // AppDatabaseTests
      .deletingLastPathComponent()  // Tests
      .deletingLastPathComponent()  // AppDatabase
      .deletingLastPathComponent()  // Packages
      .deletingLastPathComponent()  // repository root
      .appendingPathComponent("Schema")
  }

  static var schemaSource: DirectorySchemaSource {
    DirectorySchemaSource(directory: schemaDirectory)
  }

  static func makeStack() throws -> DatabaseStack {
    try DatabaseStack(inMemory: schemaSource)
  }

  static func makeEntry(
    amount: Int64 = 2_500_000,
    kind: TransactionKind = .expense,
    occurredAt: Date = Date(timeIntervalSince1970: 1_789_000_000),
    note: String? = "coffee"
  ) throws -> TransactionEntry {
    var draft = TransactionDraft(
      kind: kind, occurredAt: occurredAt, amount: AmountE4(raw: amount), note: note)
    draft.normalizeSinglePart()
    return try draft.materialize()
  }
}

/// The schema up to one migration, that one included: what an older build shipped.
/// `FilteredSchemaSource(upTo: "0003_model")` is the schema of 1.0.0.
struct FilteredSchemaSource: SchemaSource {
  let last: String

  init(upTo last: String) {
    self.last = last
  }

  func migrations() throws -> [SchemaMigration] {
    try TestSupport.schemaSource.migrations().filter { $0.name <= last }
  }
}

/// Writes records the way an older build wrote them: only the columns their table has in the
/// database at hand, in one plain `INSERT`, with no rule of today's repositories in between.
/// The record's own encoding gives the values (`databaseDictionary`), so a value is written
/// exactly as the current build would write it into that column.
enum LegacyWriter {
  static func insert(_ record: some EncodableRecord & TableRecord, db: Database) throws {
    let table = type(of: record).databaseTableName
    let known = Set(try db.columns(in: table).map(\.name))
    let values = try record.databaseDictionary.filter { known.contains($0.key) }
      .sorted { $0.key < $1.key }
    let names = values.map { "\"\($0.key)\"" }.joined(separator: ", ")
    let marks = databaseQuestionMarks(count: values.count)
    try db.execute(
      sql: "INSERT INTO \"\(table)\" (\(names)) VALUES (\(marks))",
      arguments: StatementArguments(values.map(\.value)))
  }
}

/// A table of a database as it is: its columns, and each row by rowid with the values of those
/// columns — the rowid first.
struct TableContents: Equatable {
  var columns: [String]
  var rows: [[DatabaseValue]]
}

extension TestSupport {
  /// Every table of a database but SQLite's and GRDB's own, as it is; `columns` names the
  /// columns to read of a table, all of them otherwise.
  static func contents(
    _ db: Database, columns: [String: [String]]? = nil
  ) throws -> [String: TableContents] {
    let tables = try String.fetchAll(
      db,
      sql: """
        SELECT name FROM sqlite_master
        WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'grdb_%'
        """)
    var result: [String: TableContents] = [:]
    for table in tables {
      let names = try columns?[table] ?? db.columns(in: table).map(\.name)
      let list = (["rowid"] + names).map { "\"\($0)\"" }.joined(separator: ", ")
      let rows = try Row.fetchAll(db, sql: "SELECT \(list) FROM \"\(table)\" ORDER BY rowid")
        .map { row in Array(row.databaseValues) }
      result[table] = TableContents(columns: names, rows: rows)
    }
    return result
  }
}

/// A whole graph of reference rows, so an operation can point at every foreign key it has.
struct ReferenceFixture {
  var category: CoreKit.Category
  var person: Person
  var place: Place
  var paymentMethod: PaymentMethod
  var event: Event
  var goal: Goal
  var debt: Debt
  var creditDebt: Debt
  var importBatchId: UUID
}

extension TestSupport {
  /// A stack backed by a real file, for the tests about WAL, backups and reopening.
  static func makeFileStack(
    named name: String = "finance.sqlite"
  ) throws -> (stack: DatabaseStack, directory: URL) {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-db-tests")
      .appendingPathComponent(UUID().uuidString)
    let url = directory.appendingPathComponent(name)
    return (try DatabaseStack(url: url, schema: schemaSource), directory)
  }

  /// Writes one row of every dictionary an operation can point at.
  @discardableResult
  static func seedReferences(_ stack: DatabaseStack) throws -> ReferenceFixture {
    let references = ReferenceRepository(writer: stack.writer)
    let category = CoreKit.Category(kind: .expense, name: "Groceries", quality: .neutral)
    let person = Person(name: "Alex", relation: .friend, aliases: ["Al"])
    let place = Place(name: "Green Market", aliases: ["market"])
    let method = PaymentMethod(name: "Tinkoff", kind: .card, currency: .rub)
    let event = Event(
      name: "Trip", kind: .trip,
      startDate: DateOnly(year: 2026, month: 1, day: 1),
      endDate: DateOnly(year: 2026, month: 1, day: 10))
    let goal = Goal(name: "Bike", targetE4: AmountE4(whole: 100_000))
    let debt = Debt(direction: .iOwe, type: .loan, name: "Mortgage")
    let creditDebt = Debt(direction: .iOwe, type: .installment, name: "Laptop")
    try references.save(category)
    try references.save(person)
    try references.save(place)
    try references.save(method)
    try references.save(event)
    try references.save(goal)
    try references.save(debt)
    try references.save(creditDebt)

    let batchId = UUID()
    try stack.writer.write { db in
      try db.execute(
        sql: """
          INSERT INTO import_batches (id, source_file_name, imported_at, rows_total,
            rows_imported, rows_skipped)
          VALUES (?, ?, ?, 1, 1, 0)
          """,
        arguments: [batchId.uuidString, "history.csv", Date(timeIntervalSince1970: 1_700_000_000)])
    }

    return ReferenceFixture(
      category: category, person: person, place: place, paymentMethod: method,
      event: event, goal: goal, debt: debt, creditDebt: creditDebt, importBatchId: batchId)
  }
}

extension TestSupport {
  /// The day every generated history ends on, and the app's calendar zone, as in the core's
  /// synthetic tests.
  static let sampleEnd = DateOnly(year: 2026, month: 9, day: 18)
  static let sampleCalendar = CalendarContext.moscow

  static func sample(
    months: Int = 6, density: Int = 1, seed: UInt64 = 20_260_918, endingOn: DateOnly = sampleEnd
  )
    -> SampleDataSet
  {
    SampleDataGenerator(seed: seed).generate(
      months: months, endingOn: endingOn, calendar: sampleCalendar, language: "en",
      density: density)
  }

  /// A generated history as one batch, for an empty database, the way accounts keep it
  /// (`SampleDataSet.assigningAccounts`): every write names its account, and one in a currency
  /// its account does not hold says what the account was charged.
  static func batch(_ set: SampleDataSet) -> HistoryBatch {
    let set = set.assigningAccounts().assigningBanks()
    return HistoryBatch(
      categories: set.categories, people: set.people, places: set.places,
      paymentMethods: set.paymentMethods, events: set.events, templates: set.templates,
      goals: set.goals, debts: set.debts, entries: set.entries, debtEntries: set.debtEntries,
      links: set.links, banks: set.banks)
  }

  /// The same history as the snapshot the core builds straight from the generator.
  static func dataset(_ set: SampleDataSet) -> Dataset {
    Dataset(
      entries: set.entries, links: set.links, categories: set.categories, people: set.people,
      places: set.places, events: set.events, paymentMethods: set.paymentMethods,
      debts: set.debts, goals: set.goals,
      settings: AnalyticsSettings(cashbackCategoryId: set.cashbackCategoryId))
  }
}
