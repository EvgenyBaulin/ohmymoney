import AppCore
import AppDatabase
import SQLite3
import XCTest

@testable import OhMyMoney

/// The schema of the older version of the app: the migrations up to `0003_model`.
private struct OlderSchema: SchemaSource {
  func migrations() throws -> [SchemaMigration] {
    try BundleSchemaSource(bundle: .main).migrations().filter { $0.name <= "0003_model" }
  }
}

/// A database file the older version wrote: its schema, and rows as it left them — two live
/// accounts flagged main, an archived one, a card with no currency, operations without an
/// account (one in the bin), a purchase shared with a friend and his money back, income, a total
/// reconciliation with its breakdown, a debt and its journal, a goal, a template, currencies and
/// the mark of a first launch.
private enum OlderDatabase {
  static let card = "0A000000-0000-0000-0000-000000000001"
  static let cash = "0A000000-0000-0000-0000-000000000002"

  static func write(at url: URL) throws {
    try DatabaseStack(url: url, schema: OlderSchema()).close()
    try execute(
      at: url,
      """
      INSERT INTO categories (id, kind, name, quality) VALUES
        ('0C000000-0000-0000-0000-000000000001', 'expense', 'Groceries', 'neutral'),
        ('0C000000-0000-0000-0000-000000000002', 'income', 'Salary', NULL);
      INSERT INTO people (id, name, relation) VALUES
        ('0B000000-0000-0000-0000-000000000001', 'Alex', 'friend');
      INSERT INTO payment_methods (id, name, kind, currency, aliases, is_default, archived) VALUES
        ('\(card)', 'Card', 'card', 'RUB', '', 1, 0),
        ('\(cash)', 'Cash', 'cash', NULL, '', 1, 0),
        ('0A000000-0000-0000-0000-000000000003', 'Old', 'other', 'RUB', '', 1, 1);
      INSERT INTO transactions (id, kind, occurred_at, currency, amount_e4, amount_rub_e4,
        created_at, updated_at, deleted_at, payment_method_id, period_month) VALUES
        ('0D000000-0000-0000-0000-000000000001', 'expense', '2026-08-01 10:00:00.000', 'RUB',
          2500000, 2500000, '2026-08-01 10:00:00.000', '2026-08-01 10:00:00.000', NULL,
          '\(card)', NULL),
        ('0D000000-0000-0000-0000-000000000002', 'expense', '2026-08-02 10:00:00.000', 'RUB',
          10000000, 10000000, '2026-08-02 10:00:00.000', '2026-08-02 10:00:00.000', NULL,
          NULL, NULL),
        ('0D000000-0000-0000-0000-000000000003', 'reimbursement', '2026-08-05 10:00:00.000',
          'RUB', 4000000, 4000000, '2026-08-05 10:00:00.000', '2026-08-05 10:00:00.000', NULL,
          NULL, NULL),
        ('0D000000-0000-0000-0000-000000000004', 'income', '2026-08-10 10:00:00.000', 'RUB',
          500000000, 500000000, '2026-08-10 10:00:00.000', '2026-08-10 10:00:00.000', NULL,
          '\(cash)', '2026-08'),
        ('0D000000-0000-0000-0000-000000000005', 'expense', '2026-08-11 10:00:00.000', 'RUB',
          3000000, 3000000, '2026-08-11 10:00:00.000', '2026-08-11 10:00:00.000',
          '2026-08-12 10:00:00.000', NULL, NULL);
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
          '0C000000-0000-0000-0000-000000000001', 3000000, 3000000, 0, NULL, NULL, NULL);
      INSERT INTO reimbursement_links (id, reimbursement_tx_id, part_id, amount_e4) VALUES
        ('0F000000-0000-0000-0000-000000000001', '0D000000-0000-0000-0000-000000000003',
          '0E000000-0000-0000-0000-000000000003', 4000000);
      INSERT INTO reconciliations (id, date, actual_total_rub_e4, expected_total_rub_e4,
        difference_e4, reconciled_at, breakdown) VALUES
        ('10000000-0000-0000-0000-000000000001', '2026-08-31', 1000000000, 1000000000, 0,
          '2026-08-31 07:00:00.000',
          '[{"amount_e4":10000000,"currency":"USD","rub_e4":814300000,"rub_per_unit":"81.43"}]');
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

  /// Every row of a query, as text. Not a read-only connection: one cannot read a file in WAL
  /// mode whose `-shm` is not there.
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
    var result: [[String?]] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      result.append(
        (0..<sqlite3_column_count(statement)).map { index in
          sqlite3_column_text(statement, index).map { String(cString: $0) }
        })
    }
    return result
  }

  /// The eighteen files of the older version's export, with the columns it had: those of today
  /// less what the accounts brought, each value as the database holds it.
  static func csvFiles(of url: URL) throws -> [String: Data] {
    var files: [String: Data] = [:]
    for table in ExportTables.all.prefix(18) {
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

/// An archive of the older version is imported by this build: its database is staged like any
/// import, and the start that puts it in place copies it first and then updates it.
@MainActor
final class LegacyArchiveImportTests: XCTestCase {
  private var directory: URL!
  private var dataDirectoryBefore: String?
  private var environments: [AppEnvironment] = []

  override func setUp() async throws {
    dataDirectoryBefore = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-legacy-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    setenv("OHMYMONEY_DATA_DIR", directory.appendingPathComponent("data").path, 1)
  }

  override func tearDown() async throws {
    for environment in environments { await environment.close() }
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
        (BackupService.isBeforeMigration($0.lastPathComponent)
          && $0.lastPathComponent.hasSuffix(".sqlite"))
      }
  }

  /// The archive of the older version: schema 3, its eighteen files, its database.
  private func olderArchive() throws -> (archive: URL, database: URL) {
    let written = directory.appendingPathComponent("older-mac/finance.sqlite")
    try OlderDatabase.write(at: written)
    // Whole in one file, as the older version put it into its archives.
    let database = directory.appendingPathComponent("older-mac/snapshot.sqlite")
    try DatabaseStack.backup(fileAt: written, to: database)
    let files = try OlderDatabase.csvFiles(of: database)
    var counts: [String: Int] = [:]
    for (path, data) in files {
      let table = String(path.dropFirst(ArchivePaths.csvDirectory.count).dropLast(4))
      counts[table] = ArchiveOpener.countCSVRows(data)
    }
    var builder = ArchiveBuilder(
      metadata: ArchiveBuilder.Metadata(
        appVersion: "1.0.0", schemaVersion: 3,
        createdAt: DateOnly(year: 2026, month: 9, day: 20), platform: "macOS", rowCounts: counts))
    try builder.add(path: ArchivePaths.database, data: Data(contentsOf: database))
    try builder.add(files: files)
    // Nothing in it: what it carries would be put into the defaults of the test host.
    try builder.add(path: ArchivePaths.settings, text: "{}")
    let archive = directory.appendingPathComponent("older.ohmymoneyarchive")
    try builder.build().write(to: archive)
    return (archive, database)
  }

  func testAnArchiveOfTheOlderVersionIsImportedCopiedAndUpdated() async throws {
    let (archive, database) = try olderArchive()
    let counts = try DatabaseStack.rowCounts(fileAt: database)
    XCTAssertEqual(counts["transactions"], 5)

    // The archive is opened and staged by this build, over the database it has.
    let current = await start()
    XCTAssertEqual(current.state, .ready)
    let archives = try XCTUnwrap(current.archives)
    let opened = try ArchiveImportFlow.open(archive, password: nil, archives: archives)
    XCTAssertEqual(opened.manifest.schemaVersion, 3)
    XCTAssertEqual(opened.csvTables.count, 18)
    try await ArchiveImportFlow.stageReplacement(
      opened: opened, archives: archives, backups: try XCTUnwrap(current.backups),
      target: AppPaths.pendingReplacementURL)
    await current.close()

    // The next start puts it in place, copies it, and only then updates it.
    let environment = await start()
    XCTAssertEqual(environment.state, .ready)
    let stack = try XCTUnwrap(environment.stack)
    XCTAssertEqual(try stack.appliedMigrations().count, 16)
    XCTAssertEqual(stack.applied.applied, 12)
    XCTAssertEqual(
      UpgradeFromFirstVersionTests.accountsStep(stack.applied.dataSteps),
      ["mainKept": 1, "mainChosen": 0, "mainCreated": 0, "defaultsCleared": 2, "assigned": 3])
    XCTAssertEqual(stack.applied.dataSteps["countsRecorded"], 0)

    let copies = try copiesBeforeAnUpdate()
    XCTAssertEqual(copies.count, 1, "no copy of the imported database before its update")
    let copy = try XCTUnwrap(copies.first)
    XCTAssertEqual(
      try DatabaseStack.pendingMigrations(fileAt: copy, schema: BundleSchemaSource()),
      [
        "0004_accounts", "0005_cards", "0006_banks", "0007_debts_and_deposits", "0008_capital",
        "0009_credit_and_allocation",
        "0010_scenarios",
        "0011_travel",
        "0012_sync",
        "0013_spending_rules",
        "0014_import_year_questions_subscriptions",
        "0015_bank_conditions",
        "0017_attachments",
      ],
      "the copy is not the database as the older version left it")
    XCTAssertEqual(try DatabaseStack.rowCounts(fileAt: copy), counts)

    // Every row came over; the three tables of the accounts are new and empty.
    let migrated = try DatabaseStack.rowCounts(fileAt: AppPaths.databaseURL)
    for (table, count) in counts {
      XCTAssertEqual(migrated[table], count, table)
    }
    for table in ["account_groups", "transfers", "reconciliation_balances"] {
      XCTAssertEqual(migrated[table], 0, table)
    }
    let accounts = try XCTUnwrap(environment.accounts).accounts(includeArchived: true)
    XCTAssertEqual(accounts.filter(\.isMain).map(\.id.uuidString), [OlderDatabase.card])
    let dataset = try await DatasetRepository(writer: stack.writer).load(version: 0)
    XCTAssertEqual(dataset.entries.count, 4)
    XCTAssertTrue(dataset.entries.allSatisfy { $0.transaction.paymentMethodId != nil })
    // The setup of the accounts is still ahead of the owner, as for any older database.
    XCTAssertNil(environment.accountSetup)
    XCTAssertEqual(environment.defaultCurrency, .rub)
  }
}

/// The start of a database the older version left in place: a copy first, then the update —
/// or, without a copy, no update at all.
@MainActor
final class MigrationAtStartTests: XCTestCase {
  private var directory: URL!
  private var dataDirectoryBefore: String?
  private var environments: [AppEnvironment] = []

  override func setUp() async throws {
    dataDirectoryBefore = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-update-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    setenv("OHMYMONEY_DATA_DIR", directory.path, 1)
  }

  override func tearDown() async throws {
    for environment in environments { await environment.close() }
    try? FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: AppPaths.backupsDirectory.path)
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

  private func olderDatabaseInPlace() throws -> [String: Int] {
    try AppPaths.ensureDirectories()
    try OlderDatabase.write(at: AppPaths.databaseURL)
    return try DatabaseStack.rowCounts(fileAt: AppPaths.databaseURL)
  }

  private func copies() -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: AppPaths.backupsDirectory.path)) ?? [])
      .sorted()
  }

  func testTheDatabaseOfTheOlderVersionIsCopiedThenUpdated() async throws {
    let counts = try olderDatabaseInPlace()
    let logs = directory.appendingPathComponent("journal", isDirectory: true)
    Logbook.shared.open(directory: logs, threshold: .debug)
    defer { Task { Logbook.shared.close() } }

    let environment = await start()

    XCTAssertEqual(environment.state, .ready)
    XCTAssertEqual(try environment.stack?.appliedMigrations().count, 16)
    let copy = try XCTUnwrap(
      copies().first { (BackupService.isBeforeMigration($0) && $0.hasSuffix(".sqlite")) })
    let url = AppPaths.backupsDirectory.appendingPathComponent(copy)
    XCTAssertEqual(try DatabaseStack.rowCounts(fileAt: url), counts)
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
        "0017_attachments",
      ])
    // The copy, then what the update did — counts, never a value.
    var lines: [String] = []
    for _ in 0..<50 {
      lines = Logbook.shared.lines()
      if lines.contains(where: { $0.contains("db.migrationStep") }) { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    let written = try XCTUnwrap(lines.first { $0.contains("db.migrationCopy.written") })
    XCTAssertTrue(written.contains("bytes="), written)
    let step = try XCTUnwrap(lines.first { $0.contains("db.migrationStep") })
    XCTAssertTrue(step.contains("assigned=3"), step)
    XCTAssertTrue(step.contains("defaultsCleared=2"), step)
    XCTAssertFalse(lines.contains { $0.contains("Card") || $0.contains("Groceries") })

    // Opened again, the database needs no update and gets no second copy.
    await environment.close()
    let again = await start()
    XCTAssertEqual(again.state, .ready)
    XCTAssertEqual(
      copies().filter { (BackupService.isBeforeMigration($0) && $0.hasSuffix(".sqlite")) }, [copy])
  }

  /// «Нет копии — нет миграции, приложение говорит почему»: the folder of the copies cannot be
  /// written, the start says so, and the database is still the older version's — «Повторить»
  /// updates it once the copy can be made.
  func testWithoutACopyTheDatabaseIsNotUpdated() async throws {
    let counts = try olderDatabaseInPlace()
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o555], ofItemAtPath: AppPaths.backupsDirectory.path)

    let environment = await start()

    XCTAssertEqual(environment.state, .failed(.copyBeforeUpdate))
    let pending = try DatabaseStack.pendingMigrations(
      fileAt: AppPaths.databaseURL, schema: BundleSchemaSource())
    XCTAssertEqual(
      pending,
      [
        "0004_accounts", "0005_cards", "0006_banks", "0007_debts_and_deposits", "0008_capital",
        "0009_credit_and_allocation",
        "0010_scenarios",
        "0011_travel",
        "0012_sync",
        "0013_spending_rules",
        "0014_import_year_questions_subscriptions",
        "0015_bank_conditions",
        "0017_attachments",
      ],
      "the database was updated without a copy")
    XCTAssertEqual(try DatabaseStack.rowCounts(fileAt: AppPaths.databaseURL), counts)
    XCTAssertEqual(copies(), [])
    let language = AppLanguage()
    for choice in [AppLanguage.Choice.english, .russian] {
      language.choice = choice
      let message = language(StartFailure.copyBeforeUpdate.messageKey)
      XCTAssertNotEqual(message, StartFailure.copyBeforeUpdate.messageKey, "\(choice)")
    }

    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: AppPaths.backupsDirectory.path)
    XCTAssertTrue(environment.forgetFailedStart())
    await environment.start()
    XCTAssertEqual(environment.state, .ready)
    XCTAssertEqual(try environment.stack?.appliedMigrations().count, 16)
    XCTAssertEqual(
      copies().filter { (BackupService.isBeforeMigration($0) && $0.hasSuffix(".sqlite")) }.count, 1)
  }

  /// An older database that reads but fails its integrity check — an index no longer matches
  /// its table — gives no sound copy, so it is not updated. The start says the file is damaged,
  /// which restoring a copy answers; not that the copy could not be saved, which no retry would
  /// ever change.
  func testADamagedDatabaseOfTheOlderVersionIsNotUpdatedAndSaysSo() async throws {
    let counts = try olderDatabaseInPlace()
    try breakAnIndex(of: AppPaths.databaseURL)
    XCTAssertFalse(DatabaseStack.integrityCheckPassed(at: AppPaths.databaseURL))
    XCTAssertEqual(
      try DatabaseStack.rowCounts(fileAt: AppPaths.databaseURL), counts, "the file stopped reading")

    let environment = await start()

    XCTAssertEqual(environment.state, .failed(.damaged))
    XCTAssertEqual(
      try DatabaseStack.pendingMigrations(
        fileAt: AppPaths.databaseURL, schema: BundleSchemaSource()),
      [
        "0004_accounts", "0005_cards", "0006_banks", "0007_debts_and_deposits", "0008_capital",
        "0009_credit_and_allocation",
        "0010_scenarios",
        "0011_travel",
        "0012_sync",
        "0013_spending_rules",
        "0014_import_year_questions_subscriptions",
        "0015_bank_conditions",
        "0017_attachments",
      ],
      "a damaged database was updated")
    XCTAssertEqual(try DatabaseStack.rowCounts(fileAt: AppPaths.databaseURL), counts)
    XCTAssertEqual(copies(), [], "a copy that failed its check was left")
  }

  /// Breaks one entry of an index the way a disk or a crash might: the entry of the first
  /// operation in `idx_transactions_place` names a row that is not there. The index keeps its
  /// shape, so the file still reads, but it no longer passes its integrity check.
  private func breakAnIndex(of url: URL) throws {
    try OlderDatabase.execute(at: url, "PRAGMA wal_checkpoint(TRUNCATE)")
    func number(_ sql: String) throws -> Int {
      try XCTUnwrap(Int(XCTUnwrap(OlderDatabase.rows(at: url, sql).first?.first ?? nil)))
    }
    let size = try number("PRAGMA page_size")
    let root = try number(
      "SELECT rootpage FROM sqlite_master WHERE name = 'idx_transactions_place'")
    var bytes = try Data(contentsOf: url)
    let page = (root - 1) * size
    XCTAssertEqual(bytes[page], 0x0A, "the index is not one leaf page")
    // The first cell: its payload size, then the record — the size of its header, the type of
    // the place (NULL), the type of the rowid.
    let cell = page + (Int(bytes[page + 8]) << 8 | Int(bytes[page + 9]))
    XCTAssertEqual(bytes[cell + 1], 3)
    XCTAssertEqual(bytes[cell + 2], 0)
    switch bytes[cell + 3] {
    // The rowid 1, stored as the constant one: make it the constant zero.
    case 9: bytes[cell + 3] = 8
    // A rowid in one byte: make it one no operation has.
    case 1: bytes[cell + 4] = 0x7F
    default: XCTFail("an unexpected record in the index")
    }
    try bytes.write(to: url)
  }

  /// An update that stops is tried again at the next start, from the same file: the copy the
  /// first attempt made — checked, never pruned — still holds that file, and it is kept rather
  /// than written again. Every attempt would otherwise add a whole copy nothing ever prunes, and
  /// on a nearly full disk the second would not fit although the first is right there.
  func testAnUpdateTriedAgainKeepsItsOneCopy() async throws {
    _ = try olderDatabaseInPlace()
    // A table of the update is there already: its SQL stops, and nothing of it is applied.
    try OlderDatabase.execute(at: AppPaths.databaseURL, "CREATE TABLE account_groups (id TEXT)")
    let logs = directory.appendingPathComponent("journal", isDirectory: true)
    Logbook.shared.open(directory: logs, threshold: .debug)
    defer { Task { Logbook.shared.close() } }

    let environment = await start()
    XCTAssertEqual(environment.state, .failed(.other))
    let first = copies().filter { (BackupService.isBeforeMigration($0) && $0.hasSuffix(".sqlite")) }
    XCTAssertEqual(first.count, 1)
    let copy = AppPaths.backupsDirectory.appendingPathComponent(try XCTUnwrap(first.first))
    let attributes = try FileManager.default.attributesOfItem(atPath: copy.path)
    let file = attributes[.systemFileNumber] as? Int

    XCTAssertTrue(environment.forgetFailedStart())
    await environment.start()

    XCTAssertEqual(environment.state, .failed(.other))
    XCTAssertEqual(
      copies().filter { (BackupService.isBeforeMigration($0) && $0.hasSuffix(".sqlite")) }, first)
    XCTAssertEqual(
      try FileManager.default.attributesOfItem(atPath: copy.path)[.systemFileNumber] as? Int,
      file, "the copy was written again")
    var lines: [String] = []
    for _ in 0..<50 {
      lines = Logbook.shared.lines()
      if lines.contains(where: { $0.contains("db.migrationCopy.reused") }) { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertTrue(lines.contains { $0.contains("db.migrationCopy.reused") })
  }

  /// The older version was used between two attempts — here one amount was edited, so every
  /// table still has its number of rows: the copy of the earlier state is not the way back to
  /// this one, and a copy of what the file holds now is written.
  func testADatabaseChangedSinceItsCopyGetsANewOne() async throws {
    _ = try olderDatabaseInPlace()
    try OlderDatabase.execute(at: AppPaths.databaseURL, "CREATE TABLE account_groups (id TEXT)")
    let environment = await start()
    XCTAssertEqual(environment.state, .failed(.other))
    XCTAssertEqual(
      copies().filter { (BackupService.isBeforeMigration($0) && $0.hasSuffix(".sqlite")) }.count, 1)

    let edited = "0D000000-0000-0000-0000-000000000001"
    try OlderDatabase.execute(
      at: AppPaths.databaseURL,
      "UPDATE transactions SET amount_e4 = 2600000 WHERE id = '\(edited)'")
    XCTAssertTrue(environment.forgetFailedStart())
    await environment.start()

    XCTAssertEqual(environment.state, .failed(.other))
    let newest = try XCTUnwrap(
      BackupService.newestFirst(
        copies().filter { (BackupService.isBeforeMigration($0) && $0.hasSuffix(".sqlite")) }
          .map { AppPaths.backupsDirectory.appendingPathComponent($0) }
      ).first)
    XCTAssertEqual(
      try OlderDatabase.rows(
        at: newest, "SELECT amount_e4 FROM transactions WHERE id = '\(edited)'"),
      [["2600000"]], "the copy is not of the database as it is now")
  }

  /// A write cut short left two live accounts flagged main: the start leaves one.
  func testTheStartLeavesOneMainAccount() async throws {
    try AppPaths.ensureDirectories()
    let stack = try DatabaseStack(url: AppPaths.databaseURL, schema: BundleSchemaSource())
    let references = ReferenceRepository(writer: stack.writer)
    let first = PaymentMethod(name: "First", isDefault: true)
    let second = PaymentMethod(name: "Second")
    try references.save(first)
    try references.save(second)
    try stack.close()
    try OlderDatabase.execute(
      at: AppPaths.databaseURL, "UPDATE payment_methods SET is_default = 1")

    let environment = await start()

    XCTAssertEqual(environment.state, .ready)
    let accounts = try XCTUnwrap(environment.accounts).accounts()
    XCTAssertEqual(accounts.filter(\.isMain).map(\.id), [first.id])
  }

  /// The first launch switches on the ten currencies of a fresh install, and never switches off
  /// one an account holds: the settings refuse that, and the refusal stopped the start.
  func testTheFirstLaunchKeepsTheCurrencyOfAnAccount() throws {
    let stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    let references = ReferenceRepository(writer: stack.writer)
    let settings = SettingsRepository(writer: stack.writer)
    let pounds = CurrencyCode("GBP")
    try settings.setEnabledCurrencies([.rub, pounds])
    try references.save(PaymentMethod(name: "London card", currency: pounds))

    XCTAssertNoThrow(
      try AppEnvironment.seed(
        references: references, settings: settings, language: "en", isDataSet: false))

    let enabled = try settings.enabledCurrencies()
    XCTAssertEqual(Array(enabled.prefix(2)), [.rub, pounds])
    // The ten of a fresh install after the two on already: there is no limit any more.
    XCTAssertEqual(enabled.count, CurrencyCode.defaultEnabled.count + 1)
    XCTAssertTrue(enabled.contains(.usd))
    XCTAssertEqual(try settings.string("app.seeded"), "1")
  }
}
