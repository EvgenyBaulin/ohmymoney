import AppCore
import AppDatabase
import SQLite3
import XCTest

@testable import OhMyMoney

/// The schema of 1.8: the migrations up to `0008_capital`.
private struct CapitalSchema: SchemaSource {
  func migrations() throws -> [SchemaMigration] {
    try BundleSchemaSource(bundle: .main).migrations().filter { $0.name <= "0008_capital" }
  }
}

/// A database of 1.8 found at the start is copied as it is — the copy taken before the update
/// is the database of 1.8 — and then updated to the credits and the allocation of income: every
/// row stays, every debt waits to be reviewed, the new tables are empty.
@MainActor
final class UpgradeFromOnePointEightTests: XCTestCase {
  private var directory: URL!
  private var dataDirectoryBefore: String?
  private var environments: [AppEnvironment] = []

  private static let account = "0A000000-0000-0000-0000-000000000001"
  private static let loan = "0B000000-0000-0000-0000-000000000001"

  override func setUp() async throws {
    dataDirectoryBefore = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-one-eight-\(UUID().uuidString)", isDirectory: true)
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

  /// A file of 1.8: an account with a card, a loan with its journal, a goal, the setup done.
  private func writeOlderFile(at url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try DatabaseStack(url: url, schema: CapitalSchema()).close()
    var handle: OpaquePointer?
    guard sqlite3_open(url.path, &handle) == SQLITE_OK else {
      sqlite3_close(handle)
      throw CocoaError(.fileReadCorruptFile)
    }
    defer { sqlite3_close(handle) }
    let sql = """
      INSERT INTO banks (id, name) VALUES ('0C000000-0000-0000-0000-000000000001', 'Т-Банк');
      INSERT INTO payment_methods (id, name, kind, currency, aliases, is_default, archived, bank_id)
        VALUES ('\(Self.account)', 'Т-Банк', 'card', 'RUB', '', 1, 0,
          '0C000000-0000-0000-0000-000000000001');
      INSERT INTO cards (id, payment_method_id, name) VALUES
        ('0D000000-0000-0000-0000-000000000001', '\(Self.account)', 'Black');
      INSERT INTO debts (id, direction, type, name, currency, interest_rate, monthly_payment_e4,
        payment_day, origin) VALUES
        ('\(Self.loan)', 'i_owe', 'loan', 'Кредит', 'RUB', '19.9', 150000000, 15, 'existing');
      INSERT INTO debt_entries (id, debt_id, date, amount_e4, kind) VALUES
        ('0E000000-0000-0000-0000-000000000001', '\(Self.loan)', '2026-06-15', 5000000000,
          'borrowed');
      INSERT INTO goals (id, name, target_e4) VALUES
        ('13000000-0000-0000-0000-000000000001', 'Отпуск', 1000000000);
      INSERT INTO currencies (code, enabled, sort) VALUES ('RUB', 1, 0);
      INSERT INTO settings (key, value) VALUES ('app.seeded', '1'), ('accounts.setup', 'done');
      """
    guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
      throw NSError(
        domain: "sqlite", code: Int(sqlite3_errcode(handle)),
        userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(handle))])
    }
  }

  private func copiesBeforeAnUpdate() throws -> [URL] {
    try FileManager.default
      .contentsOfDirectory(at: AppPaths.backupsDirectory, includingPropertiesForKeys: nil)
      .filter {
        $0.pathExtension == "sqlite" && BackupService.isBeforeMigration($0.lastPathComponent)
      }
  }

  func testADatabaseOfOnePointEightIsCopiedThenUpdated() async throws {
    try writeOlderFile(at: AppPaths.databaseURL)
    let counts = try DatabaseStack.rowCounts(fileAt: AppPaths.databaseURL)
    XCTAssertEqual(
      try DatabaseStack.pendingMigrations(
        fileAt: AppPaths.databaseURL, schema: BundleSchemaSource()),
      ["0009_credit_and_allocation", "0010_scenarios", "0011_travel", "0012_sync", "0013_spending_rules"])

    let environment = await start()

    XCTAssertEqual(environment.state, .ready)
    let stack = try XCTUnwrap(environment.stack)
    XCTAssertEqual(try stack.appliedMigrations().last, "0013_spending_rules")
    XCTAssertEqual(stack.applied.applied, 5)
    let copies = try copiesBeforeAnUpdate()
    XCTAssertEqual(copies.count, 1, "no copy of the database before its update")
    let copy = try XCTUnwrap(copies.first)
    XCTAssertEqual(
      try DatabaseStack.pendingMigrations(fileAt: copy, schema: BundleSchemaSource()),
      ["0009_credit_and_allocation", "0010_scenarios", "0011_travel", "0012_sync", "0013_spending_rules"],
      "the copy is not the database as 1.8 left it")
    XCTAssertEqual(try DatabaseStack.rowCounts(fileAt: copy), counts)

    let migrated = try DatabaseStack.rowCounts(fileAt: AppPaths.databaseURL)
    // The start seeds the starting categories and its own settings; everything else stays.
    for (table, count) in counts where !["categories", "settings"].contains(table) {
      XCTAssertEqual(migrated[table], count, table)
    }
    for table in ["debt_instalments", "debt_costs", "allocation_rules", "custom_currencies"] {
      XCTAssertEqual(migrated[table], 0, table)
    }
    let debts = try XCTUnwrap(environment.references).debts()
    XCTAssertEqual(debts.map(\.id.uuidString), [Self.loan])
    XCTAssertEqual(debts.first?.termsReviewed, false)
    XCTAssertEqual(debts.first?.prepayAnyDay, true)

    // Opened again, the database needs no update and gets no second copy.
    await environment.close()
    let again = await start()
    XCTAssertEqual(again.state, .ready)
    XCTAssertEqual(again.stack?.applied.applied, 0)
    XCTAssertEqual(try copiesBeforeAnUpdate().count, 1)
  }
}
