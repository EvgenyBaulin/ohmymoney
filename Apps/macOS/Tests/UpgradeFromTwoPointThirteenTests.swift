import AppCore
import AppDatabase
import SQLite3
import XCTest

@testable import OhMyMoney

// Synthetic data only.

/// The schema of 2.13.1: the migrations up to `0021_history_and_cashback_choice`.
private struct ReleasedSchema: SchemaSource {
  func migrations() throws -> [SchemaMigration] {
    try BundleSchemaSource(bundle: .main).migrations()
      .filter { $0.name <= "0021_history_and_cashback_choice" }
  }
}

/// What the first start of this build does to the installed copy's database (the Sparkle part,
/// replacing the app, is not here): the database of 2.13.1 is copied as it is, updated to the
/// newest schema with every row and sum in place, and the copy before the update is never
/// pruned afterwards.
@MainActor
final class UpgradeFromTwoPointThirteenTests: XCTestCase {
  private var directory: URL!
  private var dataDirectoryBefore: String?
  private var environments: [AppEnvironment] = []

  private static let account = "0A000000-0000-0000-0000-000000000001"
  private static let loan = "0B000000-0000-0000-0000-000000000001"
  private static let newestMigration = "0026_mcc_fee_valuations_wish_image"

  override func setUp() async throws {
    dataDirectoryBefore = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-two-thirteen-\(UUID().uuidString)", isDirectory: true)
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

  private func execute(_ sql: String, on url: URL) throws {
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

  /// Reads from a throwaway copy of the file, so asking a question never touches a backup (a
  /// read-only open of a WAL file also needs a -wal file beside it).
  private func scalar(_ sql: String, at url: URL) throws -> Int64 {
    let scratch = directory.appendingPathComponent("read-\(UUID().uuidString).sqlite")
    try FileManager.default.copyItem(at: url, to: scratch)
    for suffix in ["-wal", "-shm"] {
      let side = URL(fileURLWithPath: url.path + suffix)
      if FileManager.default.fileExists(atPath: side.path) {
        try FileManager.default.copyItem(
          at: side, to: URL(fileURLWithPath: scratch.path + suffix))
      }
    }
    var handle: OpaquePointer?
    guard sqlite3_open(scratch.path, &handle) == SQLITE_OK else {
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
    guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
    return sqlite3_column_int64(statement, 0)
  }

  /// A file of 2.13.1: an account and a card, three operations (one in parts, one deleted), a
  /// loan with its journal, a goal, the setup done.
  private func writeReleasedFile(at url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try DatabaseStack(url: url, schema: ReleasedSchema()).close()
    try execute(
      """
      INSERT INTO banks (id, name) VALUES ('0C000000-0000-0000-0000-000000000001', 'Bank A');
      INSERT INTO payment_methods (id, name, kind, currency, aliases, is_default, archived, bank_id)
        VALUES ('\(Self.account)', 'Bank A', 'card', 'RUB', '', 1, 0,
          '0C000000-0000-0000-0000-000000000001');
      INSERT INTO cards (id, payment_method_id, name) VALUES
        ('0D000000-0000-0000-0000-000000000001', '\(Self.account)', 'Main');
      INSERT INTO transactions
        (id, kind, occurred_at, amount_e4, amount_rub_e4, note, created_at, updated_at)
        VALUES
        ('T1', 'expense', '2026-10-20 10:00:00.000', 25000000, 25000000, 'coffee beans',
         '2026-10-20 10:00:00.000', '2026-10-20 10:00:00.000'),
        ('T2', 'expense', '2026-10-21 10:00:00.000', 70000000, 70000000, 'groceries',
         '2026-10-21 10:00:00.000', '2026-10-21 10:00:00.000'),
        ('T3', 'income', '2026-10-22 10:00:00.000', 1000000000, 1000000000, 'pay',
         '2026-10-22 10:00:00.000', '2026-10-22 10:00:00.000');
      INSERT INTO transaction_parts (id, transaction_id, amount_e4, amount_rub_e4) VALUES
        ('P1', 'T1', 25000000, 25000000),
        ('P2', 'T2', 40000000, 40000000),
        ('P3', 'T2', 30000000, 30000000),
        ('P4', 'T3', 1000000000, 1000000000);
      UPDATE transactions SET deleted_at = '2026-10-23 10:00:00.000' WHERE id = 'T1';
      INSERT INTO debts (id, direction, type, name, currency, interest_rate, monthly_payment_e4,
        payment_day, origin) VALUES
        ('\(Self.loan)', 'i_owe', 'loan', 'Loan', 'RUB', '19.9', 150000000, 15, 'existing');
      INSERT INTO debt_entries (id, debt_id, date, amount_e4, kind) VALUES
        ('0E000000-0000-0000-0000-000000000001', '\(Self.loan)', '2026-06-15', 5000000000,
          'borrowed');
      INSERT INTO goals (id, name, target_e4) VALUES
        ('13000000-0000-0000-0000-000000000001', 'Trip', 1000000000);
      INSERT INTO currencies (code, enabled, sort) VALUES ('RUB', 1, 0);
      INSERT INTO settings (key, value) VALUES ('app.seeded', '1'), ('accounts.setup', 'done');
      """, on: url)
  }

  private func copiesBeforeAnUpdate() throws -> [URL] {
    try FileManager.default
      .contentsOfDirectory(at: AppPaths.backupsDirectory, includingPropertiesForKeys: nil)
      .filter {
        $0.pathExtension == "sqlite" && BackupService.isBeforeMigration($0.lastPathComponent)
      }
  }

  func testTheDatabaseOfTheReleasedVersionIsCopiedUpdatedAndKeepsItsNumbers() async throws {
    let url = AppPaths.databaseURL
    try writeReleasedFile(at: url)
    let before = try DatabaseStack.pendingMigrations(fileAt: url, schema: BundleSchemaSource())
    XCTAssertEqual(before.count, 5, "\(before)")
    XCTAssertEqual(before.first, "0022_borrowed_card")
    XCTAssertEqual(before.last, Self.newestMigration)
    let counts = try DatabaseStack.rowCounts(fileAt: url)
    let liveSum = "SELECT SUM(amount_rub_e4) FROM transactions WHERE deleted_at IS NULL"
    let allSum = "SELECT SUM(amount_rub_e4) FROM transactions"
    XCTAssertEqual(try scalar(liveSum, at: url), 1_070_000_000)

    let environment = await start()

    XCTAssertEqual(environment.state, .ready)
    let stack = try XCTUnwrap(environment.stack)
    XCTAssertEqual(try stack.appliedMigrations().last, Self.newestMigration)
    XCTAssertEqual(stack.applied.applied, 5)

    // The copy before the update is the database as 2.13.1 left it.
    let copies = try copiesBeforeAnUpdate()
    XCTAssertEqual(copies.count, 1, "no copy of the database before its update")
    let copy = try XCTUnwrap(copies.first)
    XCTAssertEqual(
      try DatabaseStack.pendingMigrations(fileAt: copy, schema: BundleSchemaSource()), before)
    XCTAssertEqual(try DatabaseStack.rowCounts(fileAt: copy), counts)
    XCTAssertEqual(try scalar(liveSum, at: copy), 1_070_000_000)

    // The data stand: every row of the old tables, the sums, the soft delete, the parts.
    let migrated = try DatabaseStack.rowCounts(fileAt: url)
    for (table, count) in counts where !["categories", "settings"].contains(table) {
      XCTAssertEqual(migrated[table], count, table)
    }
    XCTAssertEqual(try scalar(liveSum, at: url), 1_070_000_000)
    XCTAssertEqual(try scalar(allSum, at: url), 1_095_000_000)
    XCTAssertEqual(
      try scalar("SELECT COUNT(*) FROM transactions WHERE deleted_at IS NOT NULL", at: url), 1)
    XCTAssertEqual(
      try scalar("SELECT SUM(amount_rub_e4) FROM transaction_parts WHERE transaction_id = 'T2'", at: url),
      70_000_000)
    XCTAssertEqual(
      try scalar("SELECT SUM(amount_e4) FROM debt_entries", at: url), 5_000_000_000)
    XCTAssertEqual(try scalar("SELECT target_e4 FROM goals", at: url), 1_000_000_000)
    XCTAssertEqual(try XCTUnwrap(environment.references).debts().map(\.id.uuidString), [Self.loan])

    // Opened again: nothing to update, no second copy.
    await environment.close()
    let again = await start()
    XCTAssertEqual(again.state, .ready)
    XCTAssertEqual(again.stack?.applied.applied, 0)
    XCTAssertEqual(try copiesBeforeAnUpdate().count, 1)
  }

  func testTheCopyBeforeTheUpdateSurvivesEveryLaterPruneAndStillOpensAsTheOldSchema() async throws {
    try writeReleasedFile(at: AppPaths.databaseURL)
    let environment = await start()
    let stack = try XCTUnwrap(environment.stack)
    let copy = try XCTUnwrap(try copiesBeforeAnUpdate().first)

    // Years later, with a pile of ordinary copies written since: the prune leaves it alone.
    let service = BackupService(stack: stack, directory: AppPaths.backupsDirectory)
    try await service.applyRetention(now: Date().addingTimeInterval(5 * 366 * 86_400))
    XCTAssertEqual(try copiesBeforeAnUpdate(), [copy])
    XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path))
    // The retention list for «older than a year» may offer it, but nothing removes it unasked.
    XCTAssertEqual(
      try DatabaseStack.pendingMigrations(fileAt: copy, schema: BundleSchemaSource()).count, 5)
  }
}
