import AppCore
import AppDatabase
import SQLite3
import XCTest

@testable import OhMyMoney

/// The schema of the version before the cards: the migrations up to `0004_accounts`.
private struct AccountsSchema: SchemaSource {
  func migrations() throws -> [SchemaMigration] {
    try BundleSchemaSource(bundle: .main).migrations().filter { $0.name <= "0004_accounts" }
  }
}

/// A database file the version before the cards wrote: two card accounts — one live, main, one
/// archived — and cash; a purchase; the starting balances of the setup and a sheet that counted
/// the card again and found it as expected; a goal with a monthly plan and one without; the
/// setup done.
private enum AccountsFile {
  static let visa = "0A000000-0000-0000-0000-000000000001"
  static let cash = "0A000000-0000-0000-0000-000000000002"
  static let old = "0A000000-0000-0000-0000-000000000003"

  static func write(at url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try DatabaseStack(url: url, schema: AccountsSchema()).close()
    try execute(
      at: url,
      """
      INSERT INTO categories (id, kind, name, quality) VALUES
        ('0C000000-0000-0000-0000-000000000001', 'expense', 'Groceries', 'neutral');
      INSERT INTO payment_methods (id, name, kind, currency, aliases, is_default, archived) VALUES
        ('\(visa)', 'Visa Gold', 'card', 'RUB', '', 1, 0),
        ('\(cash)', 'Pocket', 'cash', 'RUB', '', 0, 0),
        ('\(old)', 'Old Card', 'card', 'RUB', '', 0, 1);
      INSERT INTO transactions (id, kind, occurred_at, currency, amount_e4, amount_rub_e4,
        created_at, updated_at, payment_method_id) VALUES
        ('0D000000-0000-0000-0000-000000000001', 'expense', '2026-09-10 10:00:00.000', 'RUB',
          2500000, 2500000, '2026-09-10 10:00:00.000', '2026-09-10 10:00:00.000', '\(visa)');
      INSERT INTO transaction_parts (id, transaction_id, category_id, amount_e4, amount_rub_e4)
        VALUES ('0E000000-0000-0000-0000-000000000001', '0D000000-0000-0000-0000-000000000001',
          '0C000000-0000-0000-0000-000000000001', 2500000, 2500000);
      INSERT INTO reconciliations (id, date, actual_total_rub_e4, reconciled_at, kind) VALUES
        ('10000000-0000-0000-0000-000000000001', '2026-09-01', 0, '2026-09-01 08:00:00.000',
          'opening'),
        ('10000000-0000-0000-0000-000000000002', '2026-09-20', 0, '2026-09-20 08:00:00.000',
          'accounts');
      INSERT INTO reconciliation_balances (id, reconciliation_id, payment_method_id, currency,
        actual_e4, expected_e4, difference_e4) VALUES
        ('15000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001',
          '\(visa)', 'RUB', 100000000, NULL, NULL),
        ('15000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001',
          '\(cash)', 'RUB', 0, NULL, NULL),
        ('15000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000002',
          '\(visa)', 'RUB', 97500000, 97500000, 0);
      INSERT INTO goals (id, name, target_e4, monthly_plan_e4) VALUES
        ('13000000-0000-0000-0000-000000000001', 'Bike', 1000000000, 100000000),
        ('13000000-0000-0000-0000-000000000002', 'Rainy day', 500000000, NULL);
      INSERT INTO currencies (code, enabled, sort) VALUES ('RUB', 1, 0);
      INSERT INTO settings (key, value) VALUES ('app.seeded', '1'), ('accounts.setup', 'done');
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
      throw CocoaError(.fileReadCorruptFile)
    }
    defer { sqlite3_finalize(statement) }
    var rows: [[String?]] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      rows.append(
        (0..<sqlite3_column_count(statement)).map { index in
          sqlite3_column_text(statement, index).map { String(cString: $0) }
        })
    }
    return rows
  }

  /// The files of an archive of that version: the 21 tables, each with the columns it had.
  static func csvFiles(of url: URL) throws -> [String: Data] {
    var files: [String: Data] = [:]
    for table in ExportTables.all.prefix(21) {
      let name = String(table.fileName.dropLast(".csv".count))
      let present = Set(try rows(at: url, "PRAGMA table_info(\(name))").compactMap { $0[1] })
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

/// A database of the version before the cards, found at the start or brought in an archive:
/// copied as it is, then updated — one card for the live card account, the sheet's count marked
/// as recording its difference, the plan of the goal started in the month of the update —, and
/// the journal says so in counts.
@MainActor
final class UpgradeFromOnePointOneTests: XCTestCase {
  private var directory: URL!
  private var dataDirectoryBefore: String?
  private var environments: [AppEnvironment] = []

  override func setUp() async throws {
    dataDirectoryBefore = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-one-one-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    setenv("OHMYMONEY_DATA_DIR", directory.appendingPathComponent("data").path, 1)
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

  private func start() async -> AppEnvironment {
    let environment = AppEnvironment()
    environments.append(environment)
    environment.backupFolder = BookmarkStore(key: "tests.backup.folder.\(UUID().uuidString)")
    await environment.start()
    return environment
  }

  private func copiesBeforeAnUpdate() throws -> [URL] {
    try FileManager.default
      .contentsOfDirectory(at: AppPaths.backupsDirectory, includingPropertiesForKeys: nil)
      .filter {
        $0.pathExtension == "sqlite" && BackupService.isBeforeMigration($0.lastPathComponent)
      }
  }

  /// What the update gave the file, whoever put it in place.
  private func expectUpdated(_ environment: AppEnvironment, counts: [String: Int]) throws {
    XCTAssertEqual(environment.state, .ready)
    let stack = try XCTUnwrap(environment.stack)
    XCTAssertEqual(try stack.appliedMigrations().count, 17)
    XCTAssertEqual(stack.applied.applied, 13)
    XCTAssertEqual(stack.applied.dataSteps["cardsCreated"], 1)
    XCTAssertEqual(stack.applied.dataSteps["cardsSkipped"], 0)
    XCTAssertEqual(stack.applied.dataSteps["countsRecorded"], 1)
    XCTAssertEqual(stack.applied.dataSteps["countsKept"], 0)
    XCTAssertEqual(stack.applied.dataSteps["goalPlansStarted"], 1)

    let copies = try copiesBeforeAnUpdate()
    XCTAssertEqual(copies.count, 1, "no copy of the database before its update")
    let copy = try XCTUnwrap(copies.first)
    XCTAssertEqual(
      try DatabaseStack.pendingMigrations(fileAt: copy, schema: BundleSchemaSource()),
      [
        "0005_cards", "0006_banks", "0007_debts_and_deposits", "0008_capital",
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
      ],
      "the copy is not the database as the version before left it")
    XCTAssertEqual(try DatabaseStack.rowCounts(fileAt: copy), counts)

    let cards = try AccountsFile.rows(
      at: AppPaths.databaseURL, "SELECT payment_method_id, name FROM cards ORDER BY rowid")
    XCTAssertEqual(cards, [[AccountsFile.visa, "Visa Gold"]])
    let modes = try AccountsFile.rows(
      at: AppPaths.databaseURL,
      "SELECT id, records_difference FROM reconciliation_balances ORDER BY rowid")
    XCTAssertEqual(modes.map { $0[1] }, [nil, nil, "1"])
    let migrated = try DatabaseStack.rowCounts(fileAt: AppPaths.databaseURL)
    for (table, count) in counts {
      XCTAssertEqual(migrated[table], count, table)
    }
    XCTAssertEqual(migrated["cashback_rules"], 0)
  }

  func testAOnePointOneDatabaseIsCopiedThenUpdated() async throws {
    try AccountsFile.write(at: AppPaths.databaseURL)
    let counts = try DatabaseStack.rowCounts(fileAt: AppPaths.databaseURL)
    let logs = directory.appendingPathComponent("journal", isDirectory: true)
    Logbook.shared.open(directory: logs, threshold: .debug)
    defer { Task { Logbook.shared.close() } }

    let environment = await start()

    try expectUpdated(environment, counts: counts)
    var lines: [String] = []
    for _ in 0..<100 {
      lines = Logbook.shared.lines()
      if lines.contains(where: { $0.contains(" db.migrationStep ") }) { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    let step = try XCTUnwrap(lines.first { $0.contains(" db.migrationStep ") }, "\(lines)")
    for count in ["cardsCreated=1", "cardsSkipped=0", "countsRecorded=1", "countsKept=0"] {
      XCTAssertTrue(step.contains(count), step)
    }
    for name in ["Visa Gold", "Pocket", "Old Card", "Groceries", "Bike", "Rainy day"] {
      XCTAssertFalse(lines.contains { $0.contains(name) }, "\(name) is in the journal")
    }

    // Opened again, the database needs no update and gets no second copy.
    await environment.close()
    let again = await start()
    XCTAssertEqual(again.state, .ready)
    XCTAssertEqual(again.stack?.applied.applied, 0)
    XCTAssertEqual(try copiesBeforeAnUpdate().count, 1)
  }

  func testAnArchiveOfSchemaFourIsImportedAndUpdated() async throws {
    let written = directory.appendingPathComponent("other-mac/finance.sqlite")
    try AccountsFile.write(at: written)
    let database = directory.appendingPathComponent("other-mac/snapshot.sqlite")
    try DatabaseStack.backup(fileAt: written, to: database)
    let counts = try DatabaseStack.rowCounts(fileAt: database)
    let files = try AccountsFile.csvFiles(of: database)
    var rowCounts: [String: Int] = [:]
    for (path, data) in files {
      let table = String(path.dropFirst(ArchivePaths.csvDirectory.count).dropLast(4))
      rowCounts[table] = ArchiveOpener.countCSVRows(data)
    }
    var builder = ArchiveBuilder(
      metadata: ArchiveBuilder.Metadata(
        appVersion: "1.1.2", schemaVersion: 4,
        createdAt: DateOnly(year: 2026, month: 9, day: 26), platform: "macOS",
        rowCounts: rowCounts))
    try builder.add(path: ArchivePaths.database, data: Data(contentsOf: database))
    try builder.add(files: files)
    // Nothing in it: what it carries would be put into the defaults of the test host.
    try builder.add(path: ArchivePaths.settings, text: "{}")
    let archive = directory.appendingPathComponent("one-one.ohmymoneyarchive")
    try builder.build().write(to: archive)

    // Opened and staged by this build, over the database it has.
    let current = await start()
    XCTAssertEqual(current.state, .ready)
    let archives = try XCTUnwrap(current.archives)
    let opened = try ArchiveImportFlow.open(archive, password: nil, archives: archives)
    XCTAssertEqual(opened.manifest.schemaVersion, 4)
    XCTAssertEqual(opened.csvTables.count, 21)
    try await ArchiveImportFlow.stageReplacement(
      opened: opened, archives: archives, backups: try XCTUnwrap(current.backups),
      target: AppPaths.pendingReplacementURL)
    await current.close()

    // The next start puts it in place, copies it, and only then updates it.
    let environment = await start()
    try expectUpdated(environment, counts: counts)
  }
}
