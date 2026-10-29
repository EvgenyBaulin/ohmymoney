import AppCore
import AppDatabase
import CryptoKit
import SQLite3
import XCTest

@testable import OhMyMoney

/// The schema the first version of the app shipped: the migrations up to `0003_model`.
private struct FirstVersionSchema: SchemaSource {
  func migrations() throws -> [SchemaMigration] {
    try BundleSchemaSource(bundle: .main).migrations().filter { $0.name <= "0003_model" }
  }
}

/// The owner's database as the first version left it on his Mac: a card flagged main, cash
/// with no currency, a dollar account whose code was stored in lower case, an archived card
/// still flagged main; operations on each, two without an account (one of them shared with a
/// friend and paid back), one in the bin; income; two reconciliations of one total — the later
/// one short by 1,200 ₽; a loan with its journal; a goal; a template; a rate; currencies; two
/// amounts typed as formulas, one of which no longer adds up by today's rule.
private enum FirstVersionFile {
  static let card = "0A000000-0000-0000-0000-000000000001"
  static let cash = "0A000000-0000-0000-0000-000000000002"
  static let dollars = "0A000000-0000-0000-0000-000000000003"
  static let oldCard = "0A000000-0000-0000-0000-000000000004"
  /// An amount typed as a formula when a lone comma was always a decimal one: «1,500+2,50» was
  /// 4 then, and is 1,502.50 by today's rule.
  static let formula = "0D000000-0000-0000-0000-000000000007"
  static let lastCount = "10000000-0000-0000-0000-000000000002"
  static let firstCount = "10000000-0000-0000-0000-000000000001"
  /// The operations that had no account: the shared purchase, the money back and the binned one.
  static let withoutAccount = [
    "0D000000-0000-0000-0000-000000000002", "0D000000-0000-0000-0000-000000000003",
    "0D000000-0000-0000-0000-000000000006",
  ]

  static func write(at url: URL, noMainAccount: Bool = false) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try DatabaseStack(url: url, schema: FirstVersionSchema()).close()
    try execute(
      at: url,
      """
      INSERT INTO categories (id, kind, name, quality) VALUES
        ('0C000000-0000-0000-0000-000000000001', 'expense', 'Groceries', 'neutral'),
        ('0C000000-0000-0000-0000-000000000002', 'income', 'Salary', NULL);
      INSERT INTO people (id, name, relation) VALUES
        ('0B000000-0000-0000-0000-000000000001', 'Alex', 'friend');
      INSERT INTO payment_methods (id, name, kind, currency, aliases, is_default, archived) VALUES
        ('\(card)', 'Card', 'card', 'RUB', '', \(noMainAccount ? 0 : 1), 0),
        ('\(cash)', 'Cash', 'cash', NULL, '', 0, 0),
        ('\(dollars)', 'Dollars', 'account', 'usd', '', 0, 0),
        ('\(oldCard)', 'Old card', 'card', 'RUB', '', \(noMainAccount ? 0 : 1), 1);
      INSERT INTO transactions (id, kind, occurred_at, currency, amount_e4, rate, rate_date,
        rate_source, amount_rub_e4, created_at, updated_at, deleted_at, payment_method_id,
        period_month) VALUES
        ('0D000000-0000-0000-0000-000000000001', 'expense', '2026-08-01 10:00:00.000', 'RUB',
          2500000, NULL, NULL, NULL, 2500000, '2026-08-01 10:00:00.000',
          '2026-08-01 10:00:00.000', NULL, '\(card)', NULL),
        ('0D000000-0000-0000-0000-000000000002', 'expense', '2026-08-02 10:00:00.000', 'RUB',
          10000000, NULL, NULL, NULL, 10000000, '2026-08-02 10:00:00.000',
          '2026-08-02 11:00:00.000', NULL, NULL, NULL),
        ('0D000000-0000-0000-0000-000000000003', 'reimbursement', '2026-08-05 10:00:00.000',
          'RUB', 4000000, NULL, NULL, NULL, 4000000, '2026-08-05 10:00:00.000',
          '2026-08-05 10:00:00.000', NULL, NULL, NULL),
        ('0D000000-0000-0000-0000-000000000004', 'income', '2026-08-10 10:00:00.000', 'RUB',
          500000000, NULL, NULL, NULL, 500000000, '2026-08-10 10:00:00.000',
          '2026-08-10 10:00:00.000', NULL, '\(cash)', '2026-08'),
        ('0D000000-0000-0000-0000-000000000005', 'expense', '2026-08-12 10:00:00.000', 'USD',
          200000, '81.43', '2026-08-12', 'cbr', 16286000, '2026-08-12 10:00:00.000',
          '2026-08-12 10:00:00.000', NULL, '\(dollars)', NULL),
        ('0D000000-0000-0000-0000-000000000006', 'expense', '2026-08-13 10:00:00.000', 'RUB',
          3000000, NULL, NULL, NULL, 3000000, '2026-08-13 10:00:00.000',
          '2026-08-13 10:00:00.000', '2026-08-14 10:00:00.000', NULL, NULL);
      INSERT INTO transactions (id, kind, occurred_at, currency, amount_e4, amount_expr,
        amount_rub_e4, created_at, updated_at, payment_method_id) VALUES
        ('\(formula)', 'expense', '2026-08-20 10:00:00.000', 'RUB', 40000, '1,500+2,50', 40000,
          '2026-08-20 10:00:00.000', '2026-08-20 10:00:00.000', '\(card)');
      UPDATE transactions SET amount_expr = '(100+150)'
        WHERE id = '0D000000-0000-0000-0000-000000000001';
      INSERT INTO transaction_parts (id, transaction_id, category_id, amount_e4, amount_rub_e4,
        reimbursable, debtor_person_id, reimbursement_status, for_person_id) VALUES
        ('0E000000-0000-0000-0000-000000000001', '0D000000-0000-0000-0000-000000000001',
          '0C000000-0000-0000-0000-000000000001', 2500000, 2500000, 0, NULL, NULL, NULL),
        ('0E000000-0000-0000-0000-000000000002', '0D000000-0000-0000-0000-000000000002',
          '0C000000-0000-0000-0000-000000000001', 6000000, 6000000, 0, NULL, NULL, NULL),
        ('0E000000-0000-0000-0000-000000000003', '0D000000-0000-0000-0000-000000000002',
          '0C000000-0000-0000-0000-000000000001', 4000000, 4000000, 1,
          '0B000000-0000-0000-0000-000000000001', 'returned', NULL),
        ('0E000000-0000-0000-0000-000000000004', '0D000000-0000-0000-0000-000000000003',
          NULL, 4000000, 4000000, 0, NULL, NULL, '0B000000-0000-0000-0000-000000000001'),
        ('0E000000-0000-0000-0000-000000000005', '0D000000-0000-0000-0000-000000000004',
          '0C000000-0000-0000-0000-000000000002', 500000000, 500000000, 0, NULL, NULL, NULL),
        ('0E000000-0000-0000-0000-000000000006', '0D000000-0000-0000-0000-000000000005',
          '0C000000-0000-0000-0000-000000000001', 200000, 16286000, 0, NULL, NULL, NULL),
        ('0E000000-0000-0000-0000-000000000007', '0D000000-0000-0000-0000-000000000006',
          '0C000000-0000-0000-0000-000000000001', 3000000, 3000000, 0, NULL, NULL, NULL),
        ('0E000000-0000-0000-0000-000000000008', '\(formula)',
          '0C000000-0000-0000-0000-000000000001', 40000, 40000, 0, NULL, NULL, NULL);
      INSERT INTO reimbursement_links (id, reimbursement_tx_id, part_id, amount_e4) VALUES
        ('0F000000-0000-0000-0000-000000000001', '0D000000-0000-0000-0000-000000000003',
          '0E000000-0000-0000-0000-000000000003', 4000000);
      INSERT INTO reconciliations (id, date, actual_total_rub_e4, expected_total_rub_e4,
        difference_e4, reconciled_at, breakdown) VALUES
        ('\(firstCount)', '2026-07-31', 1000000000, NULL, NULL, '2026-07-31 07:00:00.000', NULL),
        ('\(lastCount)', '2026-08-31', 988000000, 1000000000, -12000000,
          '2026-08-31 07:00:00.000',
          '[{"amount_e4":1000000,"currency":"USD","rub_e4":81430000,"rub_per_unit":"81.43"}]');
      INSERT INTO debts (id, direction, type, name) VALUES
        ('11000000-0000-0000-0000-000000000001', 'i_owe', 'loan', 'Loan');
      INSERT INTO debt_entries (id, debt_id, date, amount_e4, kind) VALUES
        ('12000000-0000-0000-0000-000000000001', '11000000-0000-0000-0000-000000000001',
          '2026-07-01', 1000000000, 'borrowed'),
        ('12000000-0000-0000-0000-000000000002', '11000000-0000-0000-0000-000000000001',
          '2026-08-01', -50000000, 'payment');
      INSERT INTO goals (id, name, target_e4) VALUES
        ('13000000-0000-0000-0000-000000000001', 'Bike', 1000000000);
      INSERT INTO templates (id, text, category_id, amount_e4, currency, pinned, use_count)
        VALUES ('14000000-0000-0000-0000-000000000001', 'coffee 250',
          '0C000000-0000-0000-0000-000000000001', 2500000, 'RUB', 1, 3);
      INSERT INTO rates (date, currency, rub_per_unit, nominal, source, fetched_at)
        VALUES ('2026-08-12', 'USD', '81.43', 1, 'cbr', '2026-08-12 12:00:00.000');
      INSERT INTO currencies (code, enabled, sort) VALUES ('RUB', 1, 0), ('USD', 1, 1);
      INSERT INTO settings (key, value) VALUES ('app.seeded', '1');
      """)
  }

  static func execute(at url: URL, _ sql: String) throws {
    var handle: OpaquePointer?
    guard sqlite3_open(url.path, &handle) == SQLITE_OK else {
      sqlite3_close(handle)
      throw CocoaError(.fileReadCorruptFile)
    }
    defer { sqlite3_close(handle) }
    guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
      throw NSError(
        domain: "sqlite", code: Int(sqlite3_errcode(handle)),
        userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(handle))])
    }
  }

  /// Every row of a query, as text.
  static func rows(at url: URL, _ sql: String) throws -> [[String?]] {
    var handle: OpaquePointer?
    guard sqlite3_open(url.path, &handle) == SQLITE_OK else {
      sqlite3_close(handle)
      throw CocoaError(.fileReadCorruptFile)
    }
    defer { sqlite3_close(handle) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
      throw NSError(
        domain: "sqlite", code: Int(sqlite3_errcode(handle)),
        userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(handle))])
    }
    defer { sqlite3_finalize(statement) }
    var result: [[String?]] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      result.append(
        (0..<sqlite3_column_count(statement)).map { index in
          sqlite3_column_text(statement, index).map { String(cString: $0) }
        })
    }
    return result
  }

  /// The tables of a file, SQLite's own left out.
  static func tables(at url: URL) throws -> [String] {
    try rows(
      at: url,
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' "
        + "ORDER BY name"
    ).compactMap { $0.first ?? nil }
  }

  static func columns(at url: URL, of table: String) throws -> [String] {
    try rows(at: url, "PRAGMA table_info(\"\(table)\")").compactMap { $0[1] }
  }

  /// Everything a file holds: its schema, and every row of every table — the list of the
  /// migrations included — in the order of the rows.
  static func dump(at url: URL) throws -> [String: [[String?]]] {
    var result = [
      "sqlite_master": try rows(
        at: url,
        "SELECT type, name, tbl_name, sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' "
          + "ORDER BY type, name")
    ]
    for table in try tables(at: url) {
      result[table] = try rows(at: url, "SELECT * FROM \"\(table)\" ORDER BY rowid")
    }
    return result
  }

  /// The rows of `table` in the columns `columns`, keyed by the first column (the id).
  static func values(
    at url: URL, of table: String, columns: [String]
  ) throws -> [[String?]] {
    let list = columns.map { "\"\($0)\"" }.joined(separator: ", ")
    return try rows(at: url, "SELECT \(list) FROM \"\(table)\" ORDER BY rowid")
  }

  /// The eighteen files of the first version's export, with the columns it had.
  static func csvFiles(of url: URL) throws -> [String: Data] {
    var files: [String: Data] = [:]
    for table in ExportTables.all.prefix(18) {
      let name = String(table.fileName.dropLast(".csv".count))
      let present = Set(try columns(at: url, of: name))
      let columns = table.columns.compactMap { column -> (csv: String, sql: String)? in
        if present.contains(column) { return (column, column) }
        if present.contains(column + "_e4") { return (column, column + "_e4") }
        return nil
      }
      var writer = CSVWriter(columns: columns.map(\.csv))
      let list = columns.map { "\"\($0.sql)\"" }.joined(separator: ", ")
      for row in try rows(at: url, "SELECT \(list) FROM \(name) ORDER BY rowid") {
        writer.append(row.map { $0 ?? "" })
      }
      files[ArchivePaths.csv(table: name)] = writer.data()
    }
    return files
  }
}

/// A bank that answers nothing: the tests ask nothing outside.
private struct OfflineFeed: RatesFetching {
  func dailyRates(on day: DateOnly) async throws -> RateSnapshot { throw CancellationError() }
}

/// What happens on the owner's Mac when the first version updates itself to this one: the start
/// finds his database, keeps a checked copy of it, updates it, and the main window asks for the
/// setup of the accounts — once. Every step through the real start of the app, over a file.
@MainActor
final class UpgradeFromFirstVersionTests: XCTestCase {
  private var directory: URL!
  private var dataDirectoryBefore: String?
  private var environments: [AppEnvironment] = []

  override func setUp() async throws {
    dataDirectoryBefore = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-upgrade-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    setenv("OHMYMONEY_DATA_DIR", directory.appendingPathComponent("data").path, 1)
    AccountSetupRequest.shared.isRequested = false
  }

  override func tearDown() async throws {
    for environment in environments { await environment.close() }
    environments = []
    if let dataDirectoryBefore {
      setenv("OHMYMONEY_DATA_DIR", dataDirectoryBefore, 1)
    } else {
      unsetenv("OHMYMONEY_DATA_DIR")
    }
    try? FileManager.default.removeItem(at: directory)
  }

  // MARK: Helpers

  /// The counts of the update's first data step — the accounts —, apart from those of the
  /// cards, which the same update also gives.
  static func accountsStep(_ steps: [String: Int]) -> [String: Int] {
    let keys: Set = ["mainKept", "mainChosen", "mainCreated", "defaultsCleared", "assigned"]
    return steps.filter { keys.contains($0.key) }
  }

  private func start() async -> AppEnvironment {
    let environment = AppEnvironment()
    environments.append(environment)
    environment.backupFolder = BookmarkStore(key: "tests.backup.folder.\(UUID().uuidString)")
    await environment.start()
    return environment
  }

  private func store(for environment: AppEnvironment) throws -> TransactionsStore {
    let store = TransactionsStore()
    store.attach(
      try XCTUnwrap(environment.transactions), references: environment.references,
      planning: environment.planning)
    return store
  }

  /// The owner's file in its place, as the first version left it.
  @discardableResult
  private func firstVersionInPlace(noMainAccount: Bool = false) throws -> URL {
    try AppPaths.ensureDirectories()
    try FirstVersionFile.write(at: AppPaths.databaseURL, noMainAccount: noMainAccount)
    return AppPaths.databaseURL
  }

  private func copiesBeforeAnUpdate() -> [URL] {
    let names =
      (try? FileManager.default.contentsOfDirectory(atPath: AppPaths.backupsDirectory.path)) ?? []
    return names.filter { $0.hasSuffix(".sqlite") && BackupService.isBeforeMigration($0) }.sorted()
      .map { AppPaths.backupsDirectory.appendingPathComponent($0) }
  }

  /// A file taken aside to be looked at without touching the one the app holds.
  private func aside(_ url: URL, as name: String) throws -> URL {
    let target = directory.appendingPathComponent("aside/\(name).sqlite")
    try FileManager.default.createDirectory(
      at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    try DatabaseStack.backup(fileAt: url, to: target)
    return target
  }

  private func expense(
    _ amount: AmountE4, at instant: Date, on account: UUID? = nil
  ) throws -> TransactionEntry {
    var draft = TransactionDraft(
      occurredAt: instant, amount: amount, note: "coffee", paymentMethodId: account)
    draft.normalizeSinglePart()
    return try draft.materialize()
  }

  private func uuid(_ text: String) throws -> UUID { try XCTUnwrap(UUID(uuidString: text)) }

  // MARK: The update

  /// The first start of the new version: the copy is the file exactly as the first version left
  /// it — schema, list of migrations, every row — and that version can still open it; the file
  /// itself is updated, keeps every value it had but the two fills the update is allowed to make,
  /// and the older version would refuse it now.
  func testTheOwnersDatabaseIsCopiedWholeThenUpdatedWithoutLosingAValue() async throws {
    let url = try firstVersionInPlace()
    let before = try FirstVersionFile.dump(at: url)
    let tablesBefore = try FirstVersionFile.tables(at: url)
    XCTAssertEqual(before["grdb_migrations"]?.count, 3)

    let environment = await start()

    XCTAssertEqual(environment.state, .ready)
    let stack = try XCTUnwrap(environment.stack)
    XCTAssertEqual(stack.applied.applied, 14)
    XCTAssertEqual(try stack.appliedMigrations().count, 17)
    XCTAssertEqual(
      Self.accountsStep(stack.applied.dataSteps),
      ["mainKept": 1, "mainChosen": 0, "mainCreated": 0, "defaultsCleared": 1, "assigned": 3])
    // The second step: a card for every live card account, and no sheet of counts to judge —
    // the first version counted one total at most.
    XCTAssertEqual(stack.applied.dataSteps["countsRecorded"], 0)
    XCTAssertEqual(stack.applied.dataSteps["countsKept"], 0)
    XCTAssertNotNil(stack.applied.dataSteps["cardsCreated"])

    // The copy: one, checked, the first version's file to the last row.
    let copies = copiesBeforeAnUpdate()
    XCTAssertEqual(copies.count, 1)
    let copy = try XCTUnwrap(copies.first)
    XCTAssertTrue(DatabaseStack.integrityCheckPassed(at: copy))
    XCTAssertEqual(try FirstVersionFile.dump(at: copy), before, "the copy is not the older file")
    // The copy is listed with the others, so it can be restored from the Backups tab.
    let listed = try await XCTUnwrap(environment.backups).backups()
    XCTAssertTrue(listed.contains(copy))

    // The way back: the first version opens the copy with nothing to apply, and refuses the
    // updated file rather than write into it.
    let older = try aside(copy, as: "older-opens-copy")
    let reopened = try DatabaseStack(url: older, schema: FirstVersionSchema())
    XCTAssertEqual(reopened.applied.applied, 0)
    try reopened.close()
    let updated = try aside(url, as: "older-opens-updated")
    XCTAssertThrowsError(try DatabaseStack(url: updated, schema: FirstVersionSchema())) { error in
      XCTAssertEqual(StartFailure(error), .newerSchema)
    }

    // Every value of every table of the first version is still there, in every column it had,
    // except the two fills: the flag of the main account, and an account for the operations
    // that had none.
    for table in tablesBefore where table != "grdb_migrations" {
      let columns = try FirstVersionFile.columns(at: copy, of: table)
      var was = try FirstVersionFile.values(at: copy, of: table, columns: columns)
      var now = try FirstVersionFile.values(at: url, of: table, columns: columns)
      switch table {
      case "payment_methods":
        let flag = try XCTUnwrap(columns.firstIndex(of: "is_default"))
        XCTAssertEqual(
          now.map { $0[flag] }, ["1", "0", "0", "0"], "not exactly the card is main")
        was = was.map {
          var row = $0; row[flag] = nil; return row
        }
        now = now.map {
          var row = $0; row[flag] = nil; return row
        }
      case "transactions":
        // The formulas are read again at every open by today's rule: the one that no longer
        // comes to its amount goes, the amount stays.
        let formula = try XCTUnwrap(columns.firstIndex(of: "amount_expr"))
        for (index, row) in was.enumerated() where row[formula] != nil {
          let dropped = row[0] == FirstVersionFile.formula
          XCTAssertEqual(now[index][formula], dropped ? nil : row[formula], "\(row[0] ?? "")")
          was[index][formula] = nil
          now[index][formula] = nil
        }
        let account = try XCTUnwrap(columns.firstIndex(of: "payment_method_id"))
        for (index, row) in now.enumerated() where was[index][account] == nil {
          XCTAssertEqual(row[account], FirstVersionFile.card, "\(row[0] ?? "")")
          XCTAssertTrue(FirstVersionFile.withoutAccount.contains(row[0] ?? ""))
          now[index][account] = nil
        }
      default:
        break
      }
      XCTAssertEqual(now, was, "\(table) changed")
    }
    XCTAssertEqual(
      try FirstVersionFile.rows(at: url, "PRAGMA foreign_key_check"), [],
      "the update left a reference to nothing")

    // The month of the first version counts as it did: my spending is the card's 250, my 600 of
    // the shared 1,000 (the friend's 400 came back and is not mine), the 20 $ at 81.43 and the 4
    // of the formula — the binned 300 is not there; the income is the salary, and the money back
    // is no income.
    let dataset = try await DatasetRepository(writer: stack.writer).load(version: 0)
    let ledger = Ledger(dataset: dataset, calendar: environment.calendar)
    let august = MonthKey(year: 2026, month: 8)
    XCTAssertEqual(
      ledger.expenses(
        in: DayRange(
          DateOnly(year: 2026, month: 8, day: 1), DateOnly(year: 2026, month: 8, day: 31))),
      try AmountE4(decimal: Decimal(string: "2482.6")!))
    XCTAssertEqual(ledger.income(attributedTo: [august]), AmountE4(whole: 50_000))

    // The main account is the card, the setup of the accounts is still ahead of the owner, and
    // the main window asks for it — outside the unit tests' host and outside a data set.
    let accounts = try XCTUnwrap(environment.accounts).accounts(includeArchived: true)
    XCTAssertEqual(accounts.filter(\.isMain).map(\.id), [try uuid(FirstVersionFile.card)])
    XCTAssertNil(environment.accountSetup)
    XCTAssertTrue(AccountSetupOffer.asks(environment, isTestHost: false))
    XCTAssertFalse(AccountSetupOffer.asks(environment), "the unit tests' host is asked")
    XCTAssertFalse(
      AccountSetupOffer.asks(setup: nil, isOpen: true, isTestHost: false, dataSet: .demo),
      "a set of synthetic data is asked")
    XCTAssertTrue(AccountSetupOffer.isUp(environment, isTestHost: false))
  }

  /// What the journal keeps of the update: the copy and the step of the data, in counts — never
  /// a name of the owner's — and no repair of the main account, which the update chose itself.
  func testTheJournalOfTheUpdateHoldsCountsAndNoName() async throws {
    try firstVersionInPlace()
    let logs = directory.appendingPathComponent("journal", isDirectory: true)
    Logbook.shared.open(directory: logs, threshold: .debug)
    defer { Task { Logbook.shared.close() } }

    let environment = await start()

    XCTAssertEqual(environment.state, .ready)
    var lines: [String] = []
    for _ in 0..<100 {
      lines = Logbook.shared.lines()
      if lines.contains(where: { $0.contains(" db.opened ") }) { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertTrue(lines.contains { $0.contains(" db.migrationCopy.written ") }, "\(lines)")
    let step = try XCTUnwrap(lines.first { $0.contains(" db.migrationStep ") })
    XCTAssertTrue(step.contains("assigned=3"), step)
    XCTAssertTrue(step.contains("defaultsCleared=1"), step)
    XCTAssertTrue(step.contains("mainKept=1"), step)
    XCTAssertFalse(
      lines.contains { $0.contains(" accounts.mainRepaired ") },
      "the start repaired the main account the update had just chosen")
    for name in [
      "Card", "Cash", "Dollars", "Alex", "Groceries", "Salary", "Bike", "Loan", "coffee",
    ] {
      XCTAssertFalse(lines.contains { $0.contains(name) }, "\(name) is in the journal")
    }
  }

  /// The second start of the new version finds nothing to update: no step runs, no second copy
  /// is written, and the setup, never answered, is still asked.
  func testTheSecondLaunchNeitherUpdatesNorCopiesAgain() async throws {
    try firstVersionInPlace()
    let first = await start()
    XCTAssertEqual(first.state, .ready)
    let copies = copiesBeforeAnUpdate()
    XCTAssertEqual(copies.count, 1)
    await first.close()

    let second = await start()

    XCTAssertEqual(second.state, .ready)
    let stack = try XCTUnwrap(second.stack)
    XCTAssertEqual(stack.applied.applied, 0)
    XCTAssertEqual(stack.applied.dataSteps, [:], "the data step of the update ran again")
    XCTAssertEqual(copiesBeforeAnUpdate(), copies)
    XCTAssertNil(second.accountSetup)
    XCTAssertTrue(AccountSetupOffer.asks(second, isTestHost: false))
    let accounts = try XCTUnwrap(second.accounts).accounts(includeArchived: true)
    XCTAssertEqual(accounts.filter(\.isMain).map(\.id), [try uuid(FirstVersionFile.card)])
  }

  // MARK: The setup after the update

  /// «Готово» over the updated database: the three live accounts of the first version are listed
  /// — the main one first, the archived one left alone — and nothing the first version counted
  /// is taken for a count of an account (its reconciliations were of one total). The balances
  /// typed become the first count of every account and currency, the old reconciliations stay
  /// in the history as they were, and the next start does not ask again.
  func testDoneAfterTheUpdateCountsEveryAccountAndKeepsTheOldHistory() async throws {
    try firstVersionInPlace()
    let environment = await start()
    XCTAssertEqual(environment.state, .ready)
    let store = try store(for: environment)
    let card = try uuid(FirstVersionFile.card)
    let cash = try uuid(FirstVersionFile.cash)
    let dollars = try uuid(FirstVersionFile.dollars)

    var model = try XCTUnwrap(AccountSetupModel.load(from: environment))
    XCTAssertEqual(model.mainId, card)
    XCTAssertEqual(model.accounts.first?.id, card, "the main account is not first")
    XCTAssertEqual(Set(model.accounts.map(\.id)), [card, cash, dollars])
    XCTAssertTrue(model.accounts.allSatisfy { !$0.isNew })
    XCTAssertEqual(model.account(named: "Cash")?.currencies, [.rub], "no currency reads as rubles")
    XCTAssertEqual(model.account(named: "Dollars")?.currencies, [.usd])

    let at = Date()
    let read = await AccountSetupExpectations.load(from: environment, at: at)
    let expected = try XCTUnwrap(read)
    XCTAssertEqual(
      expected, [:], "a reconciliation of one total anchored the balance of an account")
    model.setExpected(expected)
    model.setBalance(AmountE4(whole: 12_000), for: BalanceKey(accountId: card, currency: .rub))
    model.setBalance(AmountE4(whole: 3_500), for: BalanceKey(accountId: cash, currency: .rub))
    model.setBalance(AmountE4(whole: 150), for: BalanceKey(accountId: dollars, currency: .usd))
    let plan = try XCTUnwrap(model.plan(at: at))
    XCTAssertEqual(plan.expected, [:], "every balance is a starting point")

    XCTAssertEqual(
      AccountSetupWrites.finish(plan, environment: environment, store: store), .written)

    XCTAssertEqual(environment.accountSetup, .done)
    XCTAssertFalse(AccountSetupOffer.asks(environment, isTestHost: false))
    let book = try XCTUnwrap(environment.planning).book()
    let old = book.reconciliations.filter { $0.kind == .total }
    XCTAssertEqual(
      Set(old.map(\.id)),
      [try uuid(FirstVersionFile.firstCount), try uuid(FirstVersionFile.lastCount)])
    let last = try XCTUnwrap(old.first { $0.id == (try? uuid(FirstVersionFile.lastCount)) })
    XCTAssertEqual(last.actualTotalRubE4, AmountE4(whole: 98_800))
    XCTAssertEqual(last.expectedTotalRubE4, AmountE4(whole: 100_000))
    XCTAssertEqual(last.differenceE4, AmountE4(whole: -1_200))
    XCTAssertEqual(last.breakdown.count, 1)
    // The history and the card of Overview still say what the old reconciliation found.
    let said = try XCTUnwrap(
      ReconciliationCard.found(
        by: last, balances: book.reconciledBalances, accounts: [], environment))
    XCTAssertTrue(said.contains("−1,200"), said)
    XCTAssertNotEqual(
      environment.language("reconcile.kind.total", table: "Planning"), "reconcile.kind.total")

    // The counts of the setup: one reconciliation, a starting point for every key.
    let opening = try XCTUnwrap(book.reconciliations.first { $0.kind == .opening })
    let counted = book.reconciledBalances.filter { $0.reconciliationId == opening.id }
    XCTAssertEqual(
      Dictionary(uniqueKeysWithValues: counted.map { ($0.key, $0.actualE4) }),
      [
        BalanceKey(accountId: card, currency: .rub): AmountE4(whole: 12_000),
        BalanceKey(accountId: cash, currency: .rub): AmountE4(whole: 3_500),
        BalanceKey(accountId: dollars, currency: .usd): AmountE4(whole: 150),
      ])
    XCTAssertTrue(counted.allSatisfy(\.isStartingPoint))
    XCTAssertEqual(
      ReconciliationCard.found(
        by: opening, balances: book.reconciledBalances, accounts: [], environment),
      environment.language("reconcile.startingPoint", table: "Planning"))

    // Right after the setup the books expect exactly what was counted.
    let readAfter = await AccountSetupExpectations.load(
      from: environment, at: Date().addingTimeInterval(1))
    let after = try XCTUnwrap(readAfter)
    XCTAssertEqual(after[BalanceKey(accountId: card, currency: .rub)], AmountE4(whole: 12_000))
    XCTAssertEqual(after[BalanceKey(accountId: cash, currency: .rub)], AmountE4(whole: 3_500))
    XCTAssertEqual(after[BalanceKey(accountId: dollars, currency: .usd)], AmountE4(whole: 150))

    // Every operation kept its account; the ones without one went to the main account.
    let entries = try XCTUnwrap(environment.transactions).entries(
      from: .distantPast, to: .distantFuture)
    for entry in entries {
      let id = entry.transaction.id.uuidString
      if FirstVersionFile.withoutAccount.contains(id) {
        XCTAssertEqual(entry.transaction.paymentMethodId, card, id)
      } else {
        XCTAssertNotNil(entry.transaction.paymentMethodId, id)
      }
    }

    await environment.close()
    let again = await start()
    XCTAssertEqual(again.state, .ready)
    XCTAssertEqual(again.accountSetup, .done)
    XCTAssertFalse(AccountSetupOffer.asks(again, isTestHost: false))
    XCTAssertFalse(AccountsSetupCard.shows(setup: again.accountSetup))
  }

  /// «Позже» over the updated database makes nothing new — the first version's card is main
  /// already — and changes none of its accounts. The next start does not ask; the card of
  /// Overview leads back.
  func testLaterAfterTheUpdateKeepsEveryAccountAndIsNotAskedAgain() async throws {
    try firstVersionInPlace()
    let environment = await start()
    XCTAssertEqual(environment.state, .ready)
    let store = try store(for: environment)
    let before = try XCTUnwrap(environment.accounts).accounts(includeArchived: true)

    XCTAssertTrue(AccountSetupWrites.postpone(environment: environment, store: store))

    XCTAssertEqual(environment.accountSetup, .later)
    XCTAssertEqual(try XCTUnwrap(environment.accounts).accounts(includeArchived: true), before)
    XCTAssertTrue(AccountsSetupCard.shows(setup: environment.accountSetup))
    await environment.close()

    let again = await start()
    XCTAssertEqual(again.accountSetup, .later)
    XCTAssertFalse(AccountSetupOffer.asks(again, isTestHost: false))
    XCTAssertTrue(AccountsSetupCard.shows(setup: again.accountSetup))
    XCTAssertEqual(try XCTUnwrap(again.accounts).accounts(includeArchived: true), before)
  }

  /// A first-version database with no account flagged main and operations without one: the
  /// update makes the main account under the name the interface gives it, puts exactly those
  /// operations on it, and the setup lists it first.
  func testTheMainAccountTheUpdateMakesIsNamedInTheLanguageOfTheInterface() async throws {
    try firstVersionInPlace(noMainAccount: true)

    let environment = await start()

    XCTAssertEqual(environment.state, .ready)
    let name = environment.language("accounts.mainDefaultName")
    XCTAssertNotEqual(name, "accounts.mainDefaultName")
    let accounts = try XCTUnwrap(environment.accounts).accounts(includeArchived: true)
    let main = try XCTUnwrap(accounts.first(where: \.isMain))
    XCTAssertEqual(accounts.filter(\.isMain).count, 1)
    XCTAssertEqual(main.name, name)
    XCTAssertEqual(main.mainCurrency, .rub)
    let entries = try XCTUnwrap(environment.transactions).entries(
      from: .distantPast, to: .distantFuture)
    let onMain = entries.filter { $0.transaction.paymentMethodId == main.id }
      .map(\.transaction.id.uuidString)
    let binned = "0D000000-0000-0000-0000-000000000006"
    let live = Set(FirstVersionFile.withoutAccount).subtracting([binned])
    XCTAssertEqual(Set(onMain), live, "the main account holds more or less than it should")
    XCTAssertEqual(
      try FirstVersionFile.rows(
        at: AppPaths.databaseURL,
        "SELECT payment_method_id FROM transactions WHERE id = '\(binned)'"
      ), [[main.id.uuidString]], "the binned operation has no account")
    let model = try XCTUnwrap(AccountSetupModel.load(from: environment))
    XCTAssertEqual(model.accounts.first?.id, main.id)
    XCTAssertEqual(model.mainId, main.id)
  }

  /// The first run of the pipeline over the updated database ends with no block failed or left
  /// counting: data, what is owed, forecast, model, anomalies, advice, reminders. The rates block
  /// is left out — the bank answers nothing here, so it may fail — but it is not left counting;
  /// the steps not built yet only say so. This file has no planning rows: those of the first
  /// version go through the pipeline in the test of its real archive.
  func testThePipelineRunsOverTheUpdatedDatabaseWithoutAFailedBlock() async throws {
    try firstVersionInPlace()
    let environment = await start()
    XCTAssertEqual(environment.state, .ready)
    let stack = try XCTUnwrap(environment.stack)
    let compute = ComputeStore(calendar: environment.calendar, rebuildsInline: true)
    compute.attach(
      ComputeSources.live(
        stack: stack,
        rateService: RateService(
          repository: RateRepository(writer: stack.writer), client: OfflineFeed()),
        calendar: environment.calendar),
      changes: nil)

    compute.run()
    let deadline = Date().addingTimeInterval(60)
    repeat {
      try await Task.sleep(for: .milliseconds(20))
    } while compute.isRunning && Date() < deadline
    XCTAssertFalse(compute.isRunning, "the run never ended")

    let states = compute.states
    let phases: [(String, BlockPhase)] = [
      ("data", states.data.phase), ("owed", states.owed.phase),
      ("forecast", states.forecast.phase), ("model", states.model.phase),
      ("anomalies", states.anomalies.phase), ("advice", states.advice.phase),
      ("reminders", states.reminders.phase),
    ]
    for (name, phase) in phases {
      XCTAssertNotEqual(phase, .failed, name)
      XCTAssertNotEqual(phase, .calculating, name)
    }
    XCTAssertNotEqual(states.rates.phase, .calculating, "rates")
    XCTAssertTrue(states.stubs.values.allSatisfy { $0.phase == .plannedFor }, "stubs")
    let snapshot = try XCTUnwrap(compute.snapshot)
    XCTAssertEqual(snapshot.planning.lastReconciliation?.kind, .total)
    XCTAssertEqual(snapshot.planning.freeMoney.state, .noReconciliation)
    await compute.stop()
  }

  /// The first version let a new card take the name of one in the archive. After the update the
  /// setup does not write two accounts of one name: it says so of the live one, and a new name
  /// given right in the sheet lets «Готово» through — the archived one keeps its name.
  func testALiveAccountNamedLikeAnArchivedOneIsRenamedRightInTheSetup() async throws {
    let url = try firstVersionInPlace()
    try FirstVersionFile.execute(
      at: url, "UPDATE payment_methods SET name = 'Card' WHERE id = '\(FirstVersionFile.oldCard)'")
    let environment = await start()
    XCTAssertEqual(environment.state, .ready)
    let store = try store(for: environment)
    let card = try uuid(FirstVersionFile.card)
    var model = try XCTUnwrap(AccountSetupModel.load(from: environment))
    let at = Date()
    let read = await AccountSetupExpectations.load(from: environment, at: at)
    model.setExpected(try XCTUnwrap(read))
    XCTAssertEqual(model.issues, [.nameArchived(card)])
    XCTAssertNil(model.plan(at: at))
    // The words ask only for another name: bringing the archived one back is no way out for an
    // account the database has — Settings refuses it beside a live one of its name.
    let key = model.messageKey(for: .nameArchived(card))
    XCTAssertEqual(key, "onboarding.issue.nameArchivedStored")
    XCTAssertNotEqual(environment.language(key, table: "Onboarding"), key)
    XCTAssertEqual(
      AccountActions(environment: environment, store: store).restore(
        try uuid(FirstVersionFile.oldCard)), .refused(.nameTaken))

    let index = try XCTUnwrap(model.accounts.firstIndex { $0.id == card })
    model.accounts[index].name = "Card 2026"
    XCTAssertEqual(model.issues, [])
    let plan = try XCTUnwrap(model.plan(at: at))
    XCTAssertEqual(
      AccountSetupWrites.finish(plan, environment: environment, store: store), .written)

    let accounts = try XCTUnwrap(environment.accounts).accounts(includeArchived: true)
    XCTAssertEqual(accounts.first { $0.id == card }?.name, "Card 2026")
    XCTAssertEqual(
      accounts.first { $0.id == (try? uuid(FirstVersionFile.oldCard)) }?.name, "Card")
    XCTAssertEqual(accounts.filter(\.isMain).map(\.id), [card])
  }

  /// The first reconciliation after the update, made from the sheet: the old reconciliations of
  /// one total are what Overview shows until then, and they anchor no balance — every row of the
  /// sheet is a first count, the free sum waits for it, and the count writes no difference. The
  /// money now is then exactly what was counted.
  func testTheFirstCountAfterTheUpdateIsAStartingPointBesideTheOldHistory() async throws {
    try firstVersionInPlace()
    let environment = await start()
    XCTAssertEqual(environment.state, .ready)
    let store = try store(for: environment)
    let compute = ComputeStore(calendar: .system, rebuildsInline: true)
    let deps = AppDependencies(environment: environment, store: store, compute: compute)
    let card = try uuid(FirstVersionFile.card)
    let cash = try uuid(FirstVersionFile.cash)
    let dollars = try uuid(FirstVersionFile.dollars)
    let rates: [CurrencyCode: Decimal] = [.usd: Decimal(string: "81.43")!]
    func show(_ load: Int) async throws -> DataSnapshot {
      let stack = try XCTUnwrap(environment.stack)
      let dataset = try await DatasetRepository(writer: stack.writer).load(version: 0)
      let snapshot = DataSnapshot.build(
        dataset: dataset, calendar: environment.calendar, today: environment.today,
        context: SnapshotContext(rubPerUnit: rates), version: DataVersion(load: load))
      compute.applyLight(snapshot)
      return snapshot
    }

    let before = try await show(1)
    XCTAssertEqual(before.planning.lastReconciliation?.id, try uuid(FirstVersionFile.lastCount))
    XCTAssertEqual(before.planning.lastReconciliation?.kind, .total)
    XCTAssertEqual(
      before.planning.freeMoney.state, .noReconciliation,
      "a reconciliation of one total was taken for a count of the accounts")
    let t0 = Date()
    let rows = ReconcileSheet.rows(of: before, at: t0, first: nil, locale: Locale(identifier: "en"))
    XCTAssertEqual(
      Set(rows.map(\.key)),
      [
        BalanceKey(accountId: card, currency: .rub), BalanceKey(accountId: cash, currency: .rub),
        BalanceKey(accountId: dollars, currency: .usd),
      ])
    XCTAssertTrue(rows.allSatisfy { $0.expected == nil }, "a row expects a balance never counted")
    XCTAssertTrue(rows.allSatisfy(\.isHeld))

    let failure = PlanningActions(deps).reconcile(
      counted: [
        BalanceKey(accountId: card, currency: .rub): AmountE4(whole: 12_000),
        BalanceKey(accountId: cash, currency: .rub): AmountE4(whole: 3_500),
        BalanceKey(accountId: dollars, currency: .usd): AmountE4(whole: 150),
      ], rows: rows, recordDifference: true, at: t0)

    XCTAssertNil(failure)
    let book = try XCTUnwrap(environment.planning).book()
    XCTAssertEqual(book.reconciliations.filter { $0.kind == .total }.count, 2)
    let counted = book.reconciledBalances
    XCTAssertEqual(counted.count, 3)
    XCTAssertTrue(counted.allSatisfy { $0.isStartingPoint && $0.transactionId == nil })
    XCTAssertEqual(
      try XCTUnwrap(environment.transactions).entries(from: .distantPast, to: .distantFuture)
        .count, 6, "a first count wrote an operation")
    let after = try await show(2)
    // The history of the sheet: every reconciliation of the book, the newest first, each under
    // the words of its kind — the two of the first version under «одной суммой».
    let history = Array(after.dataset.planning.reconciliations.reversed())
    XCTAssertEqual(history.count, 3)
    XCTAssertEqual(
      history.dropFirst().map(\.id),
      [try uuid(FirstVersionFile.lastCount), try uuid(FirstVersionFile.firstCount)])
    XCTAssertEqual(history.dropFirst().map(\.kind), [.total, .total])
    XCTAssertNotEqual(history.first?.kind, .total)
    let chosen = environment.language.choice
    defer { environment.language.choice = chosen }
    let kinds: [(AppLanguage.Choice, String)] = [
      (.english, "one total"), (.russian, "одной суммой"),
    ]
    for (choice, words) in kinds {
      environment.language.choice = choice
      XCTAssertEqual(
        environment.language("reconcile.kind.total", table: "Planning").lowercased(), words,
        "\(choice)")
    }
    XCTAssertNotEqual(after.planning.lastReconciliation?.kind, .total)
    XCTAssertEqual(after.planning.freeMoney.state, .ready)
    XCTAssertEqual(
      after.planning.freeMoney.main, try AmountE4(decimal: Decimal(string: "27714.5")!),
      "the money now is not the count: 12,000 + 3,500 + 150 × 81.43")
  }

  // MARK: When the update stops

  /// The update stops after its SQL ran — here a trigger of the older file refuses the step that
  /// gives the operations without an account the main one. The file is exactly as the first
  /// version left it, the start says it failed, and the copies are within reach: among them the
  /// copy of the owner's own file, and a copy the first version wrote earlier, which the owner
  /// restores — the start that follows updates that one.
  func testAnUpdateThatStopsHalfwayLeavesTheOlderFileAndOffersTheCopies() async throws {
    let url = try firstVersionInPlace()
    // A copy the first version wrote the day before, as every change did.
    let earlier = AppPaths.backupsDirectory.appendingPathComponent(
      "finance-2026-09-25T090000+0300.sqlite")
    try DatabaseStack.backup(fileAt: url, to: earlier)
    try FirstVersionFile.execute(
      at: url,
      """
      CREATE TRIGGER refuse_the_fill BEFORE UPDATE OF payment_method_id ON transactions
      BEGIN SELECT RAISE(ABORT, 'refused'); END;
      """)
    let before = try FirstVersionFile.dump(at: url)

    let environment = await start()

    guard case .failed = environment.state else {
      return XCTFail("the update did not stop: \(environment.state)")
    }
    XCTAssertNil(environment.stack)
    XCTAssertEqual(
      try FirstVersionFile.dump(at: url), before, "the older file was changed by a stopped update")
    XCTAssertEqual(
      try DatabaseStack.pendingMigrations(fileAt: url, schema: BundleSchemaSource()),
      [
        "0004_accounts", "0005_cards", "0006_banks", "0007_debts_and_deposits", "0008_capital",
        "0009_credit_and_allocation",
        "0010_scenarios",
        "0011_travel",
        "0012_sync",
        "0013_spending_rules",
        "0014_import_year_questions_subscriptions",
        "0015_bank_conditions",
        "0016_rate_source",
        "0017_attachments",
        "0018_purchases",
      ])
    let copies = copiesBeforeAnUpdate()
    XCTAssertEqual(copies.count, 1)
    let copy = try XCTUnwrap(copies.first)
    XCTAssertEqual(try FirstVersionFile.dump(at: copy), before)
    let listed = try await XCTUnwrap(environment.backups, "the copies are out of reach").backups()
    XCTAssertTrue(listed.contains(copy), "the copy before the update is not offered")
    XCTAssertTrue(listed.contains(earlier), "the earlier copy is not offered")

    // The owner restores the earlier copy from the window; the start is made again.
    try await DatabaseRecovery.stage(earlier, replacing: environment)
    XCTAssertTrue(environment.forgetFailedStart())
    await environment.start()

    XCTAssertEqual(environment.state, .ready)
    XCTAssertEqual(try environment.stack?.appliedMigrations().count, 17)
    let kept = try FileManager.default.contentsOfDirectory(
      at: DatabaseRecovery.damagedDirectory, includingPropertiesForKeys: nil
    ).filter { $0.pathExtension == "sqlite" }
    XCTAssertEqual(kept.count, 1, "the file the update stopped on was not kept aside")
    XCTAssertEqual(try FirstVersionFile.dump(at: try XCTUnwrap(kept.first)), before)
    XCTAssertEqual(
      copiesBeforeAnUpdate().count, 2, "the restored file was updated without a copy of its own")
    XCTAssertNil(environment.accountSetup)
  }

  /// Two files get their copy before an update within one second — an update stopped on one,
  /// and the owner put another in its place at once. The second copy never takes the name, and
  /// so the place, of the first: nothing prunes that one, and it may be the only copy of what
  /// the first file held.
  func testTwoCopiesBeforeAnUpdateWithinOneSecondAreBothKept() throws {
    try AppPaths.ensureDirectories()
    let one = directory.appendingPathComponent("one/finance.sqlite")
    let other = directory.appendingPathComponent("other/finance.sqlite")
    try FirstVersionFile.write(at: one)
    try FirstVersionFile.write(at: other)
    try FirstVersionFile.execute(
      at: other, "UPDATE transactions SET note = 'edited' WHERE rowid = 1")
    let now = Date()

    let first = try BackupService.copyBeforeMigration(
      of: one, into: AppPaths.backupsDirectory, now: now)
    let second = try BackupService.copyBeforeMigration(
      of: other, into: AppPaths.backupsDirectory, now: now)

    XCTAssertNotEqual(first, second, "the second copy took the place of the first")
    XCTAssertEqual(copiesBeforeAnUpdate().count, 2)
    XCTAssertTrue(try DatabaseStack.sameData(fileAt: first, as: one), "the first copy changed")
    XCTAssertTrue(try DatabaseStack.sameData(fileAt: second, as: other))
    XCTAssertEqual(
      BackupService.newestFirst([first, second]), [second, first],
      "the later copy is not listed as the newer one")
  }

  /// A currency the first version switched off after an account was given it: the update keeps
  /// the account in it, and «Готово» counts it and switches the currency on again — an account's
  /// currency is never off.
  func testAnAccountInACurrencySwitchedOffIsCountedAndItsCurrencySwitchedOn() async throws {
    let url = try firstVersionInPlace()
    try FirstVersionFile.execute(at: url, "UPDATE currencies SET enabled = 0 WHERE code = 'USD'")
    let environment = await start()
    XCTAssertEqual(environment.state, .ready)
    let store = try store(for: environment)
    let dollars = try uuid(FirstVersionFile.dollars)
    let at = Date()
    var model = try XCTUnwrap(AccountSetupModel.load(from: environment))
    XCTAssertEqual(model.account(named: "Dollars")?.currencies, [.usd])
    let read = await AccountSetupExpectations.load(from: environment, at: at)
    model.setExpected(try XCTUnwrap(read))
    model.setBalance(AmountE4(whole: 150), for: BalanceKey(accountId: dollars, currency: .usd))
    XCTAssertEqual(model.issues, [])
    let plan = try XCTUnwrap(model.plan(at: at))

    XCTAssertEqual(
      AccountSetupWrites.finish(plan, environment: environment, store: store), .written)

    XCTAssertTrue(try XCTUnwrap(environment.settings).enabledCurrencies().contains(.usd))
    let book = try XCTUnwrap(environment.planning).book()
    XCTAssertEqual(
      book.reconciledBalances.first { $0.key == BalanceKey(accountId: dollars, currency: .usd) }?
        .actualE4, AmountE4(whole: 150))
  }

  // MARK: The way back and the copies

  /// Months later the owner restores the copy the update kept, from the Backups tab: the next
  /// start puts the first version's file in place, updates it again from the copy that is still
  /// there — no second one — and asks for the setup again, as of any database that has not been
  /// through it. What the new version wrote is in the copy of the state before the restore.
  func testTheCopyBeforeTheUpdateRestoresTheFirstVersionsDataAndIsUpdatedAgain() async throws {
    try firstVersionInPlace()
    let environment = await start()
    XCTAssertEqual(environment.state, .ready)
    let store = try store(for: environment)
    XCTAssertTrue(AccountSetupWrites.postpone(environment: environment, store: store))
    let written = try expense(
      AmountE4(whole: 700), at: Date(), on: try uuid(FirstVersionFile.cash))
    XCTAssertTrue(store.save(written))
    let copy = try XCTUnwrap(copiesBeforeAnUpdate().first)
    let firstVersion = try FirstVersionFile.dump(at: copy)

    try await BackupRestoreFlow.stage(
      copy: copy, backups: try XCTUnwrap(environment.backups),
      target: AppPaths.pendingReplacementURL)
    await environment.close()

    let restored = await start()

    XCTAssertEqual(restored.state, .ready)
    let stack = try XCTUnwrap(restored.stack)
    XCTAssertEqual(stack.applied.applied, 14, "the restored file was not updated")
    XCTAssertEqual(copiesBeforeAnUpdate(), [copy], "a second copy of the same file was written")
    XCTAssertEqual(try FirstVersionFile.dump(at: copy), firstVersion, "the copy itself changed")
    XCTAssertNil(restored.accountSetup, "the setup of the restored database is not asked again")
    XCTAssertTrue(AccountSetupOffer.asks(restored, isTestHost: false))
    let entries = try XCTUnwrap(restored.transactions).entries(
      from: .distantPast, to: .distantFuture)
    XCTAssertFalse(entries.contains { $0.transaction.id == written.transaction.id })
    XCTAssertEqual(entries.count, 6)

    // The state before the restore: the new version's database, with the operation and the
    // answer to the setup.
    let names = try FileManager.default.contentsOfDirectory(
      atPath: AppPaths.backupsDirectory.path)
    let safety = try XCTUnwrap(
      names.first { BackupCopy.parse($0)?.reason == .beforeRestore && $0.hasSuffix(".sqlite") })
    let state = AppPaths.backupsDirectory.appendingPathComponent(safety)
    XCTAssertEqual(
      try DatabaseStack.check(fileAt: state, schema: BundleSchemaSource()), .sound)
    XCTAssertEqual(
      try FirstVersionFile.rows(
        at: state, "SELECT COUNT(*) FROM transactions WHERE id = '\(written.transaction.id)'"),
      [["1"]])
    XCTAssertEqual(
      try FirstVersionFile.rows(
        at: state, "SELECT value FROM settings WHERE key = 'accounts.setup'"
      ).count, 1)
  }

  /// After the update the owner restores a copy the first version wrote the day before — any
  /// copy of the list, not the one kept for the update. It is of another state, so it gets a copy
  /// of its own before it is updated, and the setup is asked of it again.
  func testAnEarlierCopyOfTheFirstVersionRestoredAfterTheUpdateGetsItsOwnCopy() async throws {
    let url = try firstVersionInPlace()
    let earlier = AppPaths.backupsDirectory.appendingPathComponent(
      "finance-2026-09-25T090000+0300.sqlite")
    try DatabaseStack.backup(fileAt: url, to: earlier)
    // The day after that copy the first version still recorded an operation.
    try FirstVersionFile.execute(
      at: url, "UPDATE transactions SET note = 'lunch' WHERE id = '\(FirstVersionFile.formula)'")
    let environment = await start()
    XCTAssertEqual(environment.state, .ready)
    XCTAssertTrue(
      AccountSetupWrites.postpone(environment: environment, store: try store(for: environment)))
    let first = try XCTUnwrap(copiesBeforeAnUpdate().first)

    try await BackupRestoreFlow.stage(
      copy: earlier, backups: try XCTUnwrap(environment.backups),
      target: AppPaths.pendingReplacementURL)
    await environment.close()
    let restored = await start()

    XCTAssertEqual(restored.state, .ready)
    XCTAssertEqual(restored.stack?.applied.applied, 14)
    let copies = copiesBeforeAnUpdate()
    XCTAssertEqual(copies.count, 2, "the restored copy was updated without a copy of its own")
    XCTAssertTrue(copies.contains(first))
    let newest = try XCTUnwrap(BackupService.newestFirst(copies).first)
    XCTAssertTrue(try DatabaseStack.sameData(fileAt: newest, as: earlier))
    XCTAssertNil(restored.accountSetup)
    let entry = try XCTUnwrap(
      try XCTUnwrap(restored.transactions).entries(from: .distantPast, to: .distantFuture)
        .first { $0.transaction.id.uuidString == FirstVersionFile.formula })
    XCTAssertNil(entry.transaction.note, "the operation is not as the earlier copy had it")
  }

  /// «Позже» right after the update, and the setup finished later from the card of Overview:
  /// the accounts of the first version are listed again, the balance typed is the first count
  /// of its account, the fields left empty count nothing, and the question is over.
  func testTheSetupPutOffAfterTheUpdateIsFinishedLaterCountingOnlyTheTypedBalance() async throws {
    try firstVersionInPlace()
    let environment = await start()
    XCTAssertEqual(environment.state, .ready)
    let store = try store(for: environment)
    XCTAssertTrue(AccountSetupWrites.postpone(environment: environment, store: store))
    await environment.close()

    let later = await start()
    XCTAssertEqual(later.accountSetup, .later)
    let laterStore = try self.store(for: later)
    var model = try XCTUnwrap(AccountSetupModel.load(from: later))
    let card = try uuid(FirstVersionFile.card)
    XCTAssertEqual(model.mainId, card)
    XCTAssertEqual(model.accounts.count, 3)
    let at = Date()
    let read = await AccountSetupExpectations.load(from: later, at: at)
    model.setExpected(try XCTUnwrap(read))
    XCTAssertEqual(model.expected, [:])
    model.setBalance(AmountE4(whole: 9_000), for: BalanceKey(accountId: card, currency: .rub))
    let plan = try XCTUnwrap(model.plan(at: at))

    XCTAssertEqual(AccountSetupWrites.finish(plan, environment: later, store: laterStore), .written)

    XCTAssertEqual(later.accountSetup, .done)
    XCTAssertFalse(AccountsSetupCard.shows(setup: later.accountSetup))
    let book = try XCTUnwrap(later.planning).book()
    XCTAssertEqual(book.reconciliations.filter { $0.kind == .total }.count, 2)
    let counted = book.reconciledBalances
    // An empty «Остаток сейчас» is «не знаю»: no opening, the account stays not yet counted.
    XCTAssertEqual(counted.count, 1, "only the balance typed is counted")
    XCTAssertTrue(counted.allSatisfy(\.isStartingPoint))
    XCTAssertEqual(
      counted.first { $0.key == BalanceKey(accountId: card, currency: .rub) }?.actualE4,
      AmountE4(whole: 9_000))
  }

  /// A long life after the update: every change writes a copy and the oldest go, but the copy
  /// kept before the update is never one of them and takes the place of no other.
  func testTheCopiesAfterTheUpdateNeverPruneTheCopyBeforeIt() async throws {
    try firstVersionInPlace()
    let environment = await start()
    XCTAssertEqual(environment.state, .ready)
    let copy = try XCTUnwrap(copiesBeforeAnUpdate().first)
    let backups = try XCTUnwrap(environment.backups)
    // Sixty changes a minute apart, a hundred days on, all within one day — the day of the
    // thinning, so all of them stay —, and the copy before the update far older than a month.
    let later = try XCTUnwrap(
      Calendar.current.date(
        bySettingHour: 12, minute: 0, second: 0, of: Date().addingTimeInterval(100 * 86_400)))
    for minute in 0..<60 {
      try await backups.writeBackup(now: later.addingTimeInterval(Double(minute) * 60))
    }

    let listed = try await backups.backups()
    XCTAssertTrue(listed.contains(copy), "the copy before the update was pruned")
    XCTAssertEqual(listed.filter { $0 != copy }.count, 60, "it took the place of another copy")
    XCTAssertTrue(DatabaseStack.integrityCheckPassed(at: copy))
  }

  /// The first version was stopped with rows still in its write-ahead log — a crash, a power
  /// cut. Those rows are the owner's too: the copy holds them, and so does the updated file.
  func testRowsLeftInTheLogOfTheFirstVersionAreInTheCopyAndInTheUpdate() async throws {
    let url = try firstVersionInPlace()
    let logged = "0D000000-0000-0000-0000-0000000000AA"
    try leaveInTheLog(
      of: url,
      """
      INSERT INTO transactions (id, kind, occurred_at, currency, amount_e4, amount_rub_e4,
        created_at, updated_at, payment_method_id) VALUES
        ('\(logged)', 'expense', '2026-09-25 10:00:00.000', 'RUB', 1230000, 1230000,
          '2026-09-25 10:00:00.000', '2026-09-25 10:00:00.000', '\(FirstVersionFile.card)');
      INSERT INTO transaction_parts (id, transaction_id, category_id, amount_e4, amount_rub_e4,
        reimbursable) VALUES
        ('0E000000-0000-0000-0000-0000000000AA', '\(logged)',
          '0C000000-0000-0000-0000-000000000001', 1230000, 1230000, 0);
      """)
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: url.path + "-wal"), "nothing was left in the log")

    let environment = await start()

    XCTAssertEqual(environment.state, .ready)
    let copy = try XCTUnwrap(copiesBeforeAnUpdate().first)
    XCTAssertEqual(
      try FirstVersionFile.rows(
        at: copy, "SELECT amount_e4 FROM transactions WHERE id = '\(logged)'"),
      [["1230000"]], "the copy lost what the log held")
    let entries = try XCTUnwrap(environment.transactions).entries(
      from: .distantPast, to: .distantFuture)
    XCTAssertTrue(entries.contains { $0.transaction.id.uuidString == logged })
  }

  /// Writes `sql` so that it stays in the write-ahead log of `url` and never reaches the file,
  /// as a process that stopped before its checkpoint leaves it.
  private func leaveInTheLog(of url: URL, _ sql: String, withSharedMemory: Bool = false) throws {
    let parts = withSharedMemory ? ["", "-wal", "-shm"] : ["", "-wal"]
    let held = directory.appendingPathComponent("held", isDirectory: true)
    try FileManager.default.createDirectory(at: held, withIntermediateDirectories: true)
    var handle: OpaquePointer?
    XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
    XCTAssertEqual(
      sqlite3_exec(
        handle, "PRAGMA journal_mode = WAL; PRAGMA wal_autocheckpoint = 0;", nil, nil, nil),
      SQLITE_OK)
    XCTAssertEqual(sqlite3_exec(handle, sql, nil, nil, nil), SQLITE_OK)
    // The file and its log as they are at this moment, before the close checkpoints the log.
    for part in parts {
      try FileManager.default.copyItem(
        atPath: url.path + part, toPath: held.appendingPathComponent("finance" + part).path)
    }
    sqlite3_close(handle)
    for part in ["", "-wal", "-shm"] {
      try? FileManager.default.removeItem(atPath: url.path + part)
    }
    for part in parts {
      try FileManager.default.copyItem(
        atPath: held.appendingPathComponent("finance" + part).path, toPath: url.path + part)
    }
  }

  // MARK: An archive of the first version

  /// The archive the first version wrote on the owner's other Mac: schema 3, its eighteen
  /// files, its database — sealed with a password when one is given, as that version sealed it.
  private func firstVersionArchive(password: String? = nil) throws -> URL {
    let written = directory.appendingPathComponent("other-mac/finance.sqlite")
    try FirstVersionFile.write(at: written)
    let database = directory.appendingPathComponent("other-mac/snapshot.sqlite")
    try DatabaseStack.backup(fileAt: written, to: database)
    let files = try FirstVersionFile.csvFiles(of: database)
    var counts: [String: Int] = [:]
    for (path, data) in files {
      let table = String(path.dropFirst(ArchivePaths.csvDirectory.count).dropLast(4))
      counts[table] = ArchiveOpener.countCSVRows(data)
    }
    var builder = ArchiveBuilder(
      metadata: ArchiveBuilder.Metadata(
        appVersion: "1.0.0", schemaVersion: 3,
        createdAt: DateOnly(year: 2026, month: 9, day: 24), platform: "macOS", rowCounts: counts))
    try builder.add(path: ArchivePaths.database, data: Data(contentsOf: database))
    try builder.add(files: files)
    // Nothing in it: what it carries would be put into the defaults of the test host.
    try builder.add(path: ArchivePaths.settings, text: "{}")
    let archive = directory.appendingPathComponent("other-mac.ohmymoneyarchive")
    if let password {
      let salt = (0..<16).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ 11) }
      let nonce = (0..<12).map { UInt8(truncatingIfNeeded: $0 &* 53 &+ 7) }
      try builder.build(
        password: password, cipher: CryptoKitArchiveCipher(), salt: salt, nonce: nonce,
        iterations: 1_000
      ).write(to: archive)
    } else {
      try builder.build().write(to: archive)
    }
    return archive
  }

  /// A new Mac: the owner installs this version and double-clicks the sealed archive his old Mac
  /// wrote with the first version. The archive waits while the fresh database opens — the setup
  /// is not asked of a database about to go — then the password is asked, the import is staged,
  /// and the start that puts it in place copies it, updates it and asks for the setup.
  func testASealedArchiveDoubleClickedOnANewMacIsUpdatedAndAskedForTheSetup() async throws {
    let archive = try firstVersionArchive(password: "пароль 1.0.0")
    var passwords = 0
    var reports: [String] = []
    var relaunches = 0
    var confirmations = 0
    let questions = ArchiveImportFlow.Questions(
      confirm: {
        confirmations += 1
        return true
      },
      password: {
        passwords += 1
        return .given("пароль 1.0.0")
      },
      report: { reports.append($0) },
      relaunch: { relaunches += 1 })
    let fresh = AppEnvironment()
    environments.append(fresh)
    fresh.backupFolder = BookmarkStore(key: "tests.backup.folder.\(UUID().uuidString)")

    ArchiveImportFlow.begin(with: archive, environment: fresh, questions: questions)
    XCTAssertEqual(fresh.pendingArchiveImport, archive)
    XCTAssertEqual(confirmations, 0, "asked before the database opened")
    ArchiveImportFlow.resumeDeferred(in: fresh, questions: questions)
    XCTAssertEqual(fresh.pendingArchiveImport, archive, "taken up while the start is not over")
    await fresh.start()
    XCTAssertEqual(fresh.state, .ready)
    XCTAssertNil(fresh.accountSetup)
    XCTAssertFalse(
      AccountSetupOffer.asks(fresh, isTestHost: false),
      "the setup is asked of a database an archive waits to replace")

    // The main window takes the archive up once the start is over; the owner confirms.
    ArchiveImportFlow.resumeDeferred(in: fresh, questions: questions)
    XCTAssertNil(fresh.pendingArchiveImport)
    XCTAssertEqual(confirmations, 1)
    let deadline = Date().addingTimeInterval(60)
    while relaunches == 0, reports.isEmpty, Date() < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertEqual(reports, [])
    XCTAssertEqual(passwords, 1)
    XCTAssertEqual(relaunches, 1)
    await fresh.close()

    let imported = await start()

    XCTAssertEqual(imported.state, .ready)
    XCTAssertEqual(imported.stack?.applied.applied, 14)
    XCTAssertEqual(copiesBeforeAnUpdate().count, 1)
    XCTAssertNil(imported.accountSetup)
    XCTAssertTrue(AccountSetupOffer.asks(imported, isTestHost: false))
    let entries = try XCTUnwrap(imported.transactions).entries(
      from: .distantPast, to: .distantFuture)
    XCTAssertEqual(entries.count, 6)
    XCTAssertTrue(entries.allSatisfy { $0.transaction.paymentMethodId != nil })
  }

  /// The owner set up his accounts on this Mac, then imports an archive his other Mac wrote with
  /// the first version. The imported database is copied, updated, and — never set up — asked
  /// for the setup, whatever the database it replaced had answered.
  func testAnArchiveOfTheFirstVersionIsAskedForTheSetupAfterItsImport() async throws {
    let current = await start()
    XCTAssertEqual(current.state, .ready)
    let store = try store(for: current)
    XCTAssertTrue(AccountSetupWrites.postpone(environment: current, store: store))
    XCTAssertEqual(current.accountSetup, .later)

    let archive = try firstVersionArchive()

    let archives = try XCTUnwrap(current.archives)
    let opened = try ArchiveImportFlow.open(archive, password: nil, archives: archives)
    try await ArchiveImportFlow.stageReplacement(
      opened: opened, archives: archives, backups: try XCTUnwrap(current.backups),
      target: AppPaths.pendingReplacementURL)
    await current.close()

    let imported = await start()

    XCTAssertEqual(imported.state, .ready)
    XCTAssertEqual(imported.stack?.applied.applied, 14)
    XCTAssertEqual(copiesBeforeAnUpdate().count, 1)
    XCTAssertNil(imported.accountSetup, "the answer of the replaced database stayed")
    XCTAssertTrue(AccountSetupOffer.asks(imported, isTestHost: false))
    let accounts = try XCTUnwrap(imported.accounts).accounts(includeArchived: true)
    XCTAssertEqual(accounts.filter(\.isMain).map(\.id), [try uuid(FirstVersionFile.card)])
    XCTAssertEqual(
      Set(accounts.map(\.name)), ["Card", "Cash", "Dollars", "Old card"],
      "the accounts are not the imported ones")
  }
}

// MARK: - The archive 1.0.0 wrote, names, copies and failures

extension UpgradeFromFirstVersionTests {
  /// Runs every step of the pipeline over the database of `environment`, the bank answering
  /// nothing, and returns the store once the run is over.
  private func pipeline(over environment: AppEnvironment) async throws -> ComputeStore {
    let stack = try XCTUnwrap(environment.stack)
    let compute = ComputeStore(calendar: environment.calendar, rebuildsInline: true)
    compute.attach(
      ComputeSources.live(
        stack: stack,
        rateService: RateService(
          repository: RateRepository(writer: stack.writer), client: OfflineFeed()),
        calendar: environment.calendar),
      changes: nil)
    compute.run()
    let deadline = Date().addingTimeInterval(60)
    repeat {
      try await Task.sleep(for: .milliseconds(20))
    } while compute.isRunning && Date() < deadline
    XCTAssertFalse(compute.isRunning, "the run never ended")
    return compute
  }

  /// The archive the code of the v1.0.0 tag wrote — not one this build makes — goes through the
  /// import of the app as a double click on a Mac already set up takes it: confirmation, the
  /// checks, the copy of the current state, the staging, the relaunch. The settings that
  /// travelled with it are put in place; the start that follows copies the database of the
  /// archive, updates it, keeps every row of its eighteen files, and asks for the setup. Its
  /// planning book — a subscription with the history of its price, an expected income with its
  /// link, limits, reconciliations of one total, a choice of the model, an anomaly waved away —
  /// goes through the whole pipeline with no block failed.
  func testTheArchiveTheFirstVersionWroteGoesThroughTheImportOfTheAppAndIsUpdated() async throws {
    let bytes = try FirstVersionArchiveFixture.archive()
    XCTAssertEqual(bytes.count, FirstVersionArchiveFixture.byteCount)
    XCTAssertEqual(
      SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
      FirstVersionArchiveFixture.sha256, "the archive is not the one 1.0.0 wrote")
    let archive = directory.appendingPathComponent("from-1.0.0.ohmymoneyarchive")
    try bytes.write(to: archive)
    let carried = try ArchiveOpener.open(bytes, supportedSchemaVersion: 4)
    XCTAssertEqual(carried.manifest.appVersion, "1.0.0")
    XCTAssertEqual(carried.manifest.schemaVersion, 3)

    let current = await start()
    XCTAssertEqual(current.state, .ready)
    XCTAssertTrue(
      AccountSetupWrites.postpone(environment: current, store: try store(for: current)))

    // The settings of the archive are written into the defaults of the test host, which every
    // other test reads too: they are read at once and put back as they were.
    let domain = try XCTUnwrap(Bundle.main.bundleIdentifier)
    let keys = [
      "app.language", AppLanguage.appleLanguagesKey, AppTheme.schemeKey, AppTheme.accentKey,
    ]
    let before = UserDefaults.standard.persistentDomain(forName: domain) ?? [:]
    func putBack() {
      for key in keys {
        if let value = before[key] {
          UserDefaults.standard.set(value, forKey: key)
        } else {
          UserDefaults.standard.removeObject(forKey: key)
        }
      }
    }
    defer { putBack() }
    var reports: [String] = []
    var relaunches = 0
    var confirmations = 0
    let questions = ArchiveImportFlow.Questions(
      confirm: {
        confirmations += 1
        return true
      },
      password: { .cancelled },
      report: { reports.append($0) },
      relaunch: { relaunches += 1 })
    ArchiveImportFlow.begin(with: archive, environment: current, questions: questions)
    let deadline = Date().addingTimeInterval(60)
    while relaunches == 0, reports.isEmpty, Date() < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    let written = UserDefaults.standard.persistentDomain(forName: domain) ?? [:]
    putBack()
    XCTAssertEqual(reports, [])
    XCTAssertEqual(confirmations, 1)
    XCTAssertEqual(relaunches, 1)
    XCTAssertEqual(written["app.language"] as? String, "ru")
    XCTAssertEqual(written[AppTheme.schemeKey] as? String, "dark")
    XCTAssertEqual(written[AppTheme.accentKey] as? String, "green")
    await current.close()

    let imported = await start()

    XCTAssertEqual(imported.state, .ready)
    XCTAssertEqual(imported.stack?.applied.applied, 14)
    let copies = copiesBeforeAnUpdate()
    XCTAssertEqual(copies.count, 1)
    let copy = try XCTUnwrap(copies.first)
    XCTAssertTrue(
      try DatabaseStack.sameData(
        fileAt: copy, as: try aside(directory.appendingPathComponent("none.sqlite"), or: carried)),
      "the copy before the update is not the database the archive carried")
    XCTAssertNil(imported.accountSetup, "the answer of the replaced database stayed")
    XCTAssertTrue(AccountSetupOffer.asks(imported, isTestHost: false))

    // Every row of the eighteen files is there; the accounts have one more when the update had
    // to make the main one, the first version having flagged none, and a yearly event already
    // over has its next year — every launch rolls such a series on, the first version's too.
    let database = AppPaths.databaseURL
    let main = try XCTUnwrap(
      try FirstVersionFile.rows(
        at: database, "SELECT id FROM payment_methods WHERE is_default = 1 AND archived = 0"
      ).first?.first ?? nil)
    let accountsCarried = try CSVReader.dictionaries(
      from: try XCTUnwrap(carried.csv(table: "payment_methods")))
    let eventsCarried = try CSVReader.dictionaries(
      from: try XCTUnwrap(carried.csv(table: "events")))
    XCTAssertFalse(eventsCarried.isEmpty)
    for (table, count) in carried.manifest.rowCounts {
      let now = try FirstVersionFile.rows(at: database, "SELECT COUNT(*) FROM \(table)")
      var expected = count
      if table == "payment_methods", !accountsCarried.contains(where: { $0["id"] == main }) {
        expected += 1
      }
      if table == "events" {
        let today = imported.today.iso
        expected +=
          eventsCarried.filter {
            $0["recurring_yearly"] == "true" && ($0["end_date"] ?? "") < today
          }.count
      }
      XCTAssertEqual(now, [["\(expected)"]], table)
    }
    XCTAssertEqual(
      try FirstVersionFile.rows(
        at: database, "SELECT COUNT(*) FROM transactions WHERE payment_method_id IS NULL"),
      [["0"]])
    XCTAssertEqual(try FirstVersionFile.rows(at: database, "PRAGMA foreign_key_check"), [])

    let book = try XCTUnwrap(imported.planning).book()
    XCTAssertTrue(book.scheduled.contains { $0.name == "Музыка, «семейная»" })
    XCTAssertEqual(book.prices.count, carried.manifest.rowCounts["subscription_prices"])
    XCTAssertTrue(book.expected.contains { $0.name == "Премия" })
    XCTAssertEqual(
      try FirstVersionFile.rows(at: copy, "SELECT COUNT(*) FROM expected_income_links"),
      [["\(book.expectedLinks.count)"]])
    XCTAssertTrue(
      book.expectedLinks.contains {
        $0.expectedIncomeId.uuidString == "5C9E1A40-0000-4000-8000-000000000002"
      })
    XCTAssertEqual(
      Set(book.reconciliations.filter { $0.kind == .total }.map(\.id.uuidString)),
      ["5C9E1A40-0000-4000-8000-000000000007", "5C9E1A40-0000-4000-8000-000000000008"])

    let compute = try await pipeline(over: imported)
    let states = compute.states
    let phases: [(String, BlockPhase)] = [
      ("data", states.data.phase), ("owed", states.owed.phase),
      ("forecast", states.forecast.phase), ("model", states.model.phase),
      ("anomalies", states.anomalies.phase), ("advice", states.advice.phase),
      ("reminders", states.reminders.phase),
    ]
    for (name, phase) in phases {
      XCTAssertNotEqual(phase, .failed, name)
      XCTAssertNotEqual(phase, .calculating, name)
    }
    XCTAssertNotEqual(states.rates.phase, .calculating, "rates")
    let snapshot = try XCTUnwrap(compute.snapshot)
    XCTAssertEqual(snapshot.planning.lastReconciliation?.kind, .total)
    XCTAssertEqual(snapshot.planning.freeMoney.state, .noReconciliation)
    await compute.stop()
  }

  /// The database an archive carries, written out beside the test to be compared with.
  private func aside(_ url: URL, or opened: ArchiveOpener.OpenedArchive) throws -> URL {
    try XCTUnwrap(opened.database).write(to: url)
    return url
  }

  /// An account added in the setup under the name of one the first version archived: the
  /// words say it can give way to the archived one, and they are right — brought back in
  /// Settings, the archived account joins the sheet, and once the new one is taken away again
  /// «Готово» writes it back among the live accounts, under its name.
  func testANewAccountNamedLikeAnArchivedOneGivesWayToItBroughtBackInSettings() async throws {
    try firstVersionInPlace()
    let environment = await start()
    XCTAssertEqual(environment.state, .ready)
    let store = try store(for: environment)
    let oldCard = try uuid(FirstVersionFile.oldCard)
    var model = try XCTUnwrap(AccountSetupModel.load(from: environment))
    let at = Date()
    let read = await AccountSetupExpectations.load(from: environment, at: at)
    model.setExpected(try XCTUnwrap(read))
    let added = try XCTUnwrap(model.addAccount(name: "old card", kind: .card))
    XCTAssertEqual(model.issues, [.nameArchived(added)])
    XCTAssertEqual(model.messageKey(for: .nameArchived(added)), "onboarding.issue.nameArchived")

    XCTAssertEqual(AccountActions(environment: environment, store: store).restore(oldCard), .done)
    let rebased = model.rebase(on: environment)
    XCTAssertEqual(rebased, true)
    XCTAssertTrue(model.accounts.contains { $0.id == oldCard })
    XCTAssertEqual(Set(model.issues), [.nameTaken(added), .nameTaken(oldCard)])
    model.removeAccount(added)
    XCTAssertEqual(model.issues, [])
    let plan = try XCTUnwrap(model.plan(at: at))
    XCTAssertEqual(
      AccountSetupWrites.finish(plan, environment: environment, store: store), .written)
    let accounts = try XCTUnwrap(environment.accounts).accounts(includeArchived: true)
    XCTAssertEqual(accounts.count, 4)
    let back = try XCTUnwrap(accounts.first { $0.id == oldCard })
    XCTAssertFalse(back.archived)
    XCTAssertEqual(back.name, "Old card")
  }

  /// Two copies before an update, of two states; the owner restores the older one. Its file is
  /// that copy's again: the update that follows keeps no third copy of the same data — nothing
  /// ever prunes one.
  func testTheOlderOfTwoCopiesBeforeAnUpdateRestoredIsNotCopiedAThirdTime() async throws {
    let url = try firstVersionInPlace()
    let earlier = AppPaths.backupsDirectory.appendingPathComponent(
      "finance-2026-09-25T090000+0300.sqlite")
    try DatabaseStack.backup(fileAt: url, to: earlier)
    try FirstVersionFile.execute(
      at: url, "UPDATE transactions SET note = 'lunch' WHERE id = '\(FirstVersionFile.formula)'")
    let environment = await start()
    XCTAssertEqual(environment.state, .ready)
    let first = try XCTUnwrap(copiesBeforeAnUpdate().first)
    try await BackupRestoreFlow.stage(
      copy: earlier, backups: try XCTUnwrap(environment.backups),
      target: AppPaths.pendingReplacementURL)
    await environment.close()
    let second = await start()
    XCTAssertEqual(second.state, .ready)
    XCTAssertEqual(copiesBeforeAnUpdate().count, 2)

    try await BackupRestoreFlow.stage(
      copy: first, backups: try XCTUnwrap(second.backups), target: AppPaths.pendingReplacementURL)
    await second.close()
    let third = await start()

    XCTAssertEqual(third.state, .ready)
    XCTAssertEqual(third.stack?.applied.applied, 14)
    XCTAssertEqual(copiesBeforeAnUpdate().count, 2, "a third copy of the same data was kept")
    XCTAssertTrue(copiesBeforeAnUpdate().contains(first))
    let entry = try XCTUnwrap(
      try XCTUnwrap(third.transactions).entries(from: .distantPast, to: .distantFuture)
        .first { $0.transaction.id.uuidString == FirstVersionFile.formula })
    XCTAssertEqual(entry.transaction.note, "lunch")
  }

  /// Two restores within one second each keep the state before them: the second copy never
  /// takes the name, and so the place, of the first — it may be the only copy of that state.
  func testTwoCopiesBeforeARestoreWithinOneSecondAreBothKept() async throws {
    try firstVersionInPlace()
    let environment = await start()
    XCTAssertEqual(environment.state, .ready)
    let backups = try XCTUnwrap(environment.backups)
    let store = try store(for: environment)
    let now = Date()
    let one = try await backups.writeBackup(now: now, label: "before-restore")
    XCTAssertTrue(
      store.save(try expense(AmountE4(whole: 700), at: now, on: try uuid(FirstVersionFile.cash))))
    let two = try await backups.writeBackup(now: now, label: "before-restore")

    XCTAssertNotEqual(one, two)
    XCTAssertTrue(FileManager.default.fileExists(atPath: one.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: two.path))
    let counted = try [one, two].map { copy in
      try FirstVersionFile.rows(at: copy, "SELECT COUNT(*) FROM transactions").first?.first
        .flatMap { $0 }.flatMap { Int($0) }
    }
    XCTAssertEqual(counted, [7, 8], "the copies are not of the two states")
    XCTAssertEqual(BackupService.newestFirst([one, two]), [two, one])
  }

  /// An update that stops, a copy restored from the window, and the start stops again at once:
  /// the file it stopped on is set aside beside the first one, not refused for the name of the
  /// same second — the restore goes on. The window says what kind of failure it was.
  func testAStartThatStopsAgainAtOnceSetsItsFileAsideBesideTheFirst() async throws {
    let url = try firstVersionInPlace()
    try FirstVersionFile.execute(
      at: url,
      """
      CREATE TRIGGER refuse_the_fill BEFORE UPDATE OF payment_method_id ON transactions
      BEGIN SELECT RAISE(ABORT, 'refused'); END;
      """)
    let environment = await start()
    XCTAssertEqual(environment.state, .failed(.other))
    let copy = try XCTUnwrap(copiesBeforeAnUpdate().first)
    let now = Date()

    try await DatabaseRecovery.stage(copy, replacing: environment, now: now)
    XCTAssertTrue(environment.forgetFailedStart())
    await environment.start()
    XCTAssertEqual(environment.state, .failed(.other), "the same copy stops the same way")

    try await DatabaseRecovery.stage(copy, replacing: environment, now: now)
    let aside = try FileManager.default.contentsOfDirectory(
      at: DatabaseRecovery.damagedDirectory, includingPropertiesForKeys: nil
    ).filter { $0.pathExtension == "sqlite" }
    XCTAssertEqual(aside.count, 2, "the file of the second stop was not set aside")
    XCTAssertEqual(copiesBeforeAnUpdate(), [copy], "the same file got a second copy")
  }

  /// The first version stopped with rows in its log and its shared memory beside it, as a crash
  /// leaves both: the rows are in the copy and in the update.
  func testRowsLeftInTheLogWithItsSharedMemoryAreInTheCopyAndInTheUpdate() async throws {
    let url = try firstVersionInPlace()
    let logged = "0D000000-0000-0000-0000-0000000000AB"
    try leaveInTheLog(
      of: url,
      """
      INSERT INTO transactions (id, kind, occurred_at, currency, amount_e4, amount_rub_e4,
        created_at, updated_at, payment_method_id) VALUES
        ('\(logged)', 'expense', '2026-09-25 10:00:00.000', 'RUB', 1230000, 1230000,
          '2026-09-25 10:00:00.000', '2026-09-25 10:00:00.000', '\(FirstVersionFile.card)');
      INSERT INTO transaction_parts (id, transaction_id, category_id, amount_e4, amount_rub_e4,
        reimbursable) VALUES
        ('0E000000-0000-0000-0000-0000000000AB', '\(logged)',
          '0C000000-0000-0000-0000-000000000001', 1230000, 1230000, 0);
      """, withSharedMemory: true)
    XCTAssertTrue(FileManager.default.fileExists(atPath: url.path + "-shm"))

    let environment = await start()

    XCTAssertEqual(environment.state, .ready)
    let copy = try XCTUnwrap(copiesBeforeAnUpdate().first)
    XCTAssertEqual(
      try FirstVersionFile.rows(
        at: copy, "SELECT amount_e4 FROM transactions WHERE id = '\(logged)'"),
      [["1230000"]], "the copy lost what the log held")
    let entries = try XCTUnwrap(environment.transactions).entries(
      from: .distantPast, to: .distantFuture)
    XCTAssertTrue(entries.contains { $0.transaction.id.uuidString == logged })
  }

  /// A first-version file with a reference already broken — a template whose category is gone,
  /// written while the older version did not enforce the keys. The update and the whole start
  /// go through: the copy is kept, the main account chosen, the setup asked, and the update
  /// breaks nothing more than was broken.
  func testAFirstVersionFileWithABrokenReferenceIsUpdatedAndOpens() async throws {
    let url = try firstVersionInPlace()
    try FirstVersionFile.execute(
      at: url,
      """
      PRAGMA foreign_keys = OFF;
      INSERT INTO templates (id, text, category_id, amount_e4, currency, pinned, use_count)
        VALUES ('0F000000-0000-0000-0000-0000000000F1', 'taxi 400',
          '0C000000-0000-0000-0000-0000000000FF', 4000000, 'RUB', 0, 3);
      """)
    let broken = try FirstVersionFile.rows(at: url, "PRAGMA foreign_key_check")
    XCTAssertEqual(broken.count, 1)

    let environment = await start()

    XCTAssertEqual(environment.state, .ready)
    XCTAssertEqual(environment.stack?.applied.applied, 14)
    XCTAssertEqual(copiesBeforeAnUpdate().count, 1)
    XCTAssertTrue(AccountSetupOffer.asks(environment, isTestHost: false))
    let accounts = try XCTUnwrap(environment.accounts).accounts(includeArchived: true)
    XCTAssertEqual(accounts.filter(\.isMain).map(\.id), [try uuid(FirstVersionFile.card)])
    XCTAssertEqual(
      try FirstVersionFile.rows(at: AppPaths.databaseURL, "PRAGMA foreign_key_check"), broken)
    let compute = try await pipeline(over: environment)
    XCTAssertNotEqual(compute.states.data.phase, .failed)
    await compute.stop()
  }

  /// The first version checked a name only when an account was added: another name typed later
  /// could be the name of another account. After the update the setup says so of that account,
  /// naming the account whose other name is in the way, and the only way out inside the sheet —
  /// which has no field for other names — is to rename it; the other name stays on the account
  /// that carries it.
  func testTwoAccountsTheFirstVersionLetShareANameAreToldWhoseOtherNameAndOneIsRenamed()
    async throws
  {
    let url = try firstVersionInPlace()
    try FirstVersionFile.execute(
      at: url,
      "UPDATE payment_methods SET aliases = 'card' WHERE id = '\(FirstVersionFile.cash)'")
    let environment = await start()
    XCTAssertEqual(environment.state, .ready)
    let store = try store(for: environment)
    let card = try uuid(FirstVersionFile.card)
    let cash = try uuid(FirstVersionFile.cash)
    var model = try XCTUnwrap(AccountSetupModel.load(from: environment))
    let at = Date()
    let read = await AccountSetupExpectations.load(from: environment, at: at)
    model.setExpected(try XCTUnwrap(read))
    // A clash with another name of a live account names that account: «Cash» carries «card».
    let clash = AccountSetupModel.Issue.nameIsOtherNameOf(card, rival: "Cash")
    XCTAssertTrue(model.issues.contains(clash), "\(model.issues)")
    XCTAssertTrue(model.issues.allSatisfy { [clash, .nameTaken(cash)].contains($0) })
    XCTAssertNil(model.plan(at: at))

    let index = try XCTUnwrap(model.accounts.firstIndex { $0.id == card })
    model.accounts[index].name = "Main card"
    XCTAssertEqual(model.issues, [])
    let plan = try XCTUnwrap(model.plan(at: at))
    XCTAssertEqual(
      AccountSetupWrites.finish(plan, environment: environment, store: store), .written)
    let accounts = try XCTUnwrap(environment.accounts).accounts(includeArchived: true)
    XCTAssertEqual(accounts.first { $0.id == card }?.name, "Main card")
    XCTAssertEqual(accounts.first { $0.id == cash }?.name, "Cash")
  }

  /// The first version's own database — the one its code wrote into its archive — as the file in
  /// place: after the update and «Готово», the first count with a difference records it
  /// («Записать разницу») as an operation on that account, in its currency, in the category of
  /// reconciliations, which the book remembers — and no second category of that name is made.
  func testTheFirstCountWithADifferenceAfterTheUpdateIsRecordedAsAnOperation() async throws {
    let carried = try ArchiveOpener.open(
      try FirstVersionArchiveFixture.archive(), supportedSchemaVersion: 4)
    try AppPaths.ensureDirectories()
    try XCTUnwrap(carried.database).write(to: AppPaths.databaseURL)
    let environment = await start()
    XCTAssertEqual(environment.state, .ready)
    XCTAssertEqual(environment.stack?.applied.applied, 14)
    let store = try store(for: environment)

    var model = try XCTUnwrap(AccountSetupModel.load(from: environment))
    let set = Date().addingTimeInterval(-3_600)
    let read = await AccountSetupExpectations.load(from: environment, at: set)
    model.setExpected(try XCTUnwrap(read))
    let main = try XCTUnwrap(model.mainId)
    let account = try XCTUnwrap(model.accounts.first { $0.id == main })
    let key = account.key(try XCTUnwrap(account.currencies.first))
    model.setBalance(AmountE4(whole: 12_000), for: key)
    let plan = try XCTUnwrap(model.plan(at: set))
    XCTAssertEqual(
      AccountSetupWrites.finish(plan, environment: environment, store: store), .written)

    let stack = try XCTUnwrap(environment.stack)
    let compute = ComputeStore(calendar: .system, rebuildsInline: true)
    let deps = AppDependencies(environment: environment, store: store, compute: compute)
    let dataset = try await DatasetRepository(writer: stack.writer).load(version: 0)
    let snapshot = DataSnapshot.build(
      dataset: dataset, calendar: environment.calendar, today: environment.today,
      context: SnapshotContext(rubPerUnit: [:]), version: DataVersion(load: 1))
    compute.applyLight(snapshot)
    let now = Date()
    let rows = ReconcileSheet.rows(
      of: snapshot, at: now, first: nil, locale: Locale(identifier: "en"))
    XCTAssertEqual(rows.first { $0.key == key }?.expected, AmountE4(whole: 12_000))
    // Every other account is counted at what the books expect: only the main one differs.
    var counted: [BalanceKey: AmountE4] = [:]
    for row in rows {
      counted[row.key] = row.key == key ? AmountE4(whole: 11_500) : row.expected
    }
    let entriesBefore = try XCTUnwrap(environment.transactions).entries(
      from: .distantPast, to: .distantFuture
    ).count

    let failure = PlanningActions(deps).reconcile(
      counted: counted, rows: rows, recordDifference: true, at: now)

    XCTAssertNil(failure)
    let book = try XCTUnwrap(environment.planning).book()
    let recorded = book.reconciledBalances.filter { $0.transactionId != nil }
    XCTAssertEqual(recorded.map(\.key), [key], "a difference was recorded for another account")
    XCTAssertEqual(recorded.first?.differenceE4, AmountE4(whole: -500))
    let entries = try XCTUnwrap(environment.transactions).entries(
      from: .distantPast, to: .distantFuture)
    XCTAssertEqual(entries.count, entriesBefore + 1)
    let entry = try XCTUnwrap(entries.first { $0.transaction.id == recorded.first?.transactionId })
    XCTAssertEqual(entry.transaction.paymentMethodId, main)
    XCTAssertEqual(entry.transaction.currency, key.currency)
    XCTAssertEqual(entry.transaction.amountE4, AmountE4(whole: 500))
    let category = try XCTUnwrap(entry.parts.first?.categoryId)
    let database = AppPaths.databaseURL
    XCTAssertEqual(
      try FirstVersionFile.rows(
        at: database,
        "SELECT value FROM settings WHERE key = '\(PlanningSettings.reconcileExpenseCategoryKey)'"),
      [[category.uuidString]])
    let name = try XCTUnwrap(
      try FirstVersionFile.rows(
        at: database, "SELECT name FROM categories WHERE id = '\(category)'"
      ).first?.first ?? nil)
    XCTAssertEqual(
      try FirstVersionFile.rows(
        at: database,
        """
        SELECT COUNT(*) FROM categories
        WHERE archived = 0 AND kind = 'expense' AND name = '\(name)'
        """),
      [["1"]], "a second category «\(name)» was made beside the first version's")
  }

  /// The first start after the update over a long history — 20 000 operations, a tenth of them
  /// without an account — keeps the window waiting a bounded time: two integrity checks, two
  /// counts of rows, the copy, the update, the fill of the main account. An update tried again
  /// asks whether the copy still holds the file, comparing every row. The times go to the
  /// output of the test; the bounds are wide, to catch a step gone quadratic, not a slow disk.
  func testTheFirstStartOverALongHistoryOfTheFirstVersionIsBounded() async throws {
    self.executionTimeAllowance = 240
    let url = try firstVersionInPlace()
    try FirstVersionFile.execute(
      at: url,
      """
      WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 20000)
      INSERT INTO transactions (id, kind, occurred_at, currency, amount_e4, amount_rub_e4,
        created_at, updated_at, payment_method_id)
      SELECT printf('1A000000-0000-4000-8000-%012d', i), 'expense',
        strftime('%Y-%m-%d %H:%M:%f', '2024-09-01 09:00:00', '+' || (i % 730) || ' days'),
        'RUB', 1000000 + i, 1000000 + i,
        strftime('%Y-%m-%d %H:%M:%f', '2024-09-01 09:00:00', '+' || (i % 730) || ' days'),
        strftime('%Y-%m-%d %H:%M:%f', '2024-09-01 09:00:00', '+' || (i % 730) || ' days'),
        CASE WHEN i % 10 = 0 THEN NULL ELSE '\(FirstVersionFile.cash)' END
      FROM n;
      WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 20000)
      INSERT INTO transaction_parts (id, transaction_id, category_id, amount_e4, amount_rub_e4,
        reimbursable)
      SELECT printf('1B000000-0000-4000-8000-%012d', i),
        printf('1A000000-0000-4000-8000-%012d', i), '0C000000-0000-0000-0000-000000000001',
        1000000 + i, 1000000 + i, 0
      FROM n;
      """)
    XCTAssertEqual(
      try FirstVersionFile.rows(at: url, "SELECT COUNT(*) FROM transactions"), [["20007"]])

    let began = Date()
    let environment = await start()
    let firstStart = Date().timeIntervalSince(began)

    XCTAssertEqual(environment.state, .ready)
    XCTAssertEqual(environment.stack?.applied.applied, 14)
    XCTAssertEqual(
      try FirstVersionFile.rows(
        at: AppPaths.databaseURL,
        "SELECT COUNT(*) FROM transactions WHERE payment_method_id IS NULL"),
      [["0"]])
    let copy = try XCTUnwrap(copiesBeforeAnUpdate().first)

    // An update tried again over the same file: the copy is compared row by row and reused.
    let source = try aside(copy, as: "again")
    let asked = Date()
    let reused = try BackupService.copyBeforeMigration(
      of: source, into: AppPaths.backupsDirectory, now: Date())
    let again = Date().timeIntervalSince(asked)
    XCTAssertEqual(reused, copy)

    print(
      "first start over 20 000 operations: \(Int(firstStart * 1000)) ms;"
        + " the copy asked again: \(Int(again * 1000)) ms")
    XCTAssertLessThan(firstStart, 30, "the first start over a long history")
    XCTAssertLessThan(again, 15, "the copy asked again")
  }
}
