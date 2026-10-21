import AppCore
import AppDatabase
import SQLite3
import XCTest

@testable import OhMyMoney

/// The weekly check of the database, «Проверить сейчас» and «Исправить» (1.12, part 5).
@MainActor
final class IntegrityCheckServiceTests: XCTestCase {
  private var directory: URL!
  private var stack: DatabaseStack!
  private var defaults: UserDefaults!
  private var suite: String!
  private var copies: URL { directory.appendingPathComponent("backups", isDirectory: true) }

  override func setUp() async throws {
    try await super.setUp()
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-integrity-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    stack = try DatabaseStack(
      url: directory.appendingPathComponent("finance.sqlite"),
      schema: BundleSchemaSource(bundle: .main))
    var draft = TransactionDraft(amount: AmountE4(whole: 250), note: "synthetic")
    draft.normalizeSinglePart()
    try TransactionRepository(writer: stack.writer).save(try draft.materialize())
    suite = "ohmymoney-integrity-\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suite)
  }

  override func tearDown() async throws {
    defaults.removePersistentDomain(forName: suite)
    stack = nil
    try? FileManager.default.removeItem(at: directory)
    try await super.tearDown()
  }

  private func service(backups: BackupService? = nil) -> IntegrityCheckService {
    IntegrityCheckService(
      stack: stack,
      backups: backups ?? BackupService(stack: stack, directory: copies), defaults: defaults)
  }

  private func environment(_ choice: AppLanguage.Choice) -> AppEnvironment {
    let environment = AppEnvironment()
    environment.language.choice = choice
    return environment
  }

  /// Runs statements on a connection of its own, the foreign keys off as a damaged file holds them.
  private func exec(_ sql: String) throws {
    var handle: OpaquePointer?
    defer { sqlite3_close(handle) }
    guard sqlite3_open(stack.url.path, &handle) == SQLITE_OK else {
      throw CocoaError(.fileWriteUnknown)
    }
    sqlite3_busy_timeout(handle, 5_000)
    guard sqlite3_exec(handle, "PRAGMA foreign_keys = OFF; " + sql, nil, nil, nil) == SQLITE_OK
    else { throw CocoaError(.fileWriteUnknown) }
  }

  private func count(_ sql: String) throws -> Int {
    var handle: OpaquePointer?
    defer { sqlite3_close(handle) }
    guard sqlite3_open_v2(stack.url.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
      throw CocoaError(.fileReadUnknown)
    }
    var statement: OpaquePointer?
    defer { sqlite3_finalize(statement) }
    guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
      sqlite3_step(statement) == SQLITE_ROW
    else { throw CocoaError(.fileReadCorruptFile) }
    return Int(sqlite3_column_int64(statement, 0))
  }

  private func breakWithAnOrphanPart() throws {
    try exec(
      """
      INSERT INTO transaction_parts (id, transaction_id, amount_e4, amount_rub_e4)
      VALUES ('orphan', 'nothing', 1, 1)
      """)
  }

  // MARK: The schedule

  func testTheCheckRunsWhenNothingWasCheckedAndThenWaitsAWeek() async {
    let service = service()
    let start = Date(timeIntervalSince1970: 1_790_000_000)
    await service.runIfDue(now: start)
    XCTAssertEqual(service.record?.checkedAt, start)
    XCTAssertEqual(service.record?.report.operations, 1)

    await service.runIfDue(now: start.addingTimeInterval(6 * 86_400))
    XCTAssertEqual(service.record?.checkedAt, start, "it ran again before a week was over")

    await service.runIfDue(now: start.addingTimeInterval(7 * 86_400))
    XCTAssertEqual(service.record?.checkedAt, start.addingTimeInterval(7 * 86_400))
  }

  func testACheckAskedForMovesTheWeek() async {
    let service = service()
    let start = Date(timeIntervalSince1970: 1_790_000_000)
    await service.runIfDue(now: start)
    await service.check(now: start.addingTimeInterval(5 * 86_400))
    await service.runIfDue(now: start.addingTimeInterval(8 * 86_400))
    XCTAssertEqual(service.record?.checkedAt, start.addingTimeInterval(5 * 86_400))
  }

  func testTheLastResultSurvivesALaunch() async {
    let first = service()
    let when = Date(timeIntervalSince1970: 1_790_000_000)
    await first.check(now: when)
    let second = service()
    XCTAssertEqual(second.record, first.record)
    XCTAssertEqual(second.record?.checkedAt, when)
  }

  func testAHealthyBookStoresNoProblemsAndWritesNothing() async throws {
    let service = service()
    await service.check()
    XCTAssertEqual(IntegrityCheckService.storedProblems(in: defaults), 0)
    XCTAssertEqual(service.record?.report.isHealthy, true)
    XCTAssertFalse(FileManager.default.fileExists(atPath: copies.path), "a check made a copy")
  }

  func testAProblemIsRememberedForTheLineOfWorthALook() async throws {
    try breakWithAnOrphanPart()
    let service = service()
    await service.check()
    XCTAssertEqual(service.record?.report.problemCount, 1)
    XCTAssertEqual(IntegrityCheckService.storedProblems(in: defaults), 1)
  }

  // MARK: The repair

  func testTheRepairMakesACopyFirstThenRemovesTheOrphanAndChecksAgain() async throws {
    try breakWithAnOrphanPart()
    let service = service()
    await service.check()
    XCTAssertTrue(service.record?.report.hasRepairs == true)

    let outcome = await service.repair()

    XCTAssertEqual(outcome, .repaired(removed: 1))
    XCTAssertEqual(service.record?.report.isHealthy, true)
    XCTAssertEqual(IntegrityCheckService.storedProblems(in: defaults), 0)
    let made = try FileManager.default.contentsOfDirectory(atPath: copies.path)
      .filter { $0.hasSuffix(".sqlite") }
    XCTAssertEqual(made.count, 1)
    let copy = copies.appendingPathComponent(made[0])
    XCTAssertEqual(BackupCopy.parse(made[0])?.reason, .beforeRepair)
    // The copy is the state before: it still holds the orphan.
    let kept = try DatabaseStack.rowCounts(fileAt: copy)["transaction_parts"]
    XCTAssertEqual(kept, 2, "the copy was made after the repair")
  }

  func testWithoutACopyNothingIsRepaired() async throws {
    try breakWithAnOrphanPart()
    // A file where the folder of copies should be: no copy can be written.
    try Data("x".utf8).write(to: copies)
    let service = service()
    await service.check()

    let outcome = await service.repair()

    XCTAssertEqual(outcome, .noCopy)
    XCTAssertEqual(try count("SELECT COUNT(*) FROM transaction_parts WHERE id = 'orphan'"), 1)
  }

  func testWhatIsNotRepairableIsLeftAndTheReportStillHasIt() async throws {
    try exec("UPDATE transactions SET amount_e4 = amount_e4 + 10000")
    let service = service()
    await service.check()
    XCTAssertEqual(service.record?.report.hasRepairs, false)
    let outcome = await service.repair()
    XCTAssertEqual(outcome, .repaired(removed: 0))
    XCTAssertEqual(service.record?.report.problemCount, 1)
  }

  // MARK: Words

  func testTheStatusAndTheFindingsReadInBothLanguages() async throws {
    try breakWithAnOrphanPart()
    let service = service()
    await service.check(now: Date(timeIntervalSince1970: 1_790_000_000))
    let record = try XCTUnwrap(service.record)
    for choice in [AppLanguage.Choice.english, .russian] {
      let environment = environment(choice)
      let status = IntegrityText.status(record, in: environment)
      XCTAssertFalse(status.contains("integrity."), status)
      XCTAssertTrue(status.contains("1"), status)
      for finding in record.report.findings {
        let line = IntegrityText.finding(finding, in: environment)
        XCTAssertFalse(line.contains("integrity."), line)
        XCTAssertTrue(line.contains("transaction_parts"), line)
      }
      XCTAssertEqual(
        IntegrityText.status(nil, in: environment),
        environment.language("integrity.never", table: "Settings"))
      for outcome in [
        IntegrityCheckService.Repair.repaired(removed: 3), .noCopy, .failed,
      ] {
        XCTAssertFalse(IntegrityText.outcome(outcome, in: environment).contains("integrity."))
      }
      XCTAssertFalse(IntegrityText.repairMessage(rows: 2, in: environment).contains("integrity."))
    }
  }

  func testAHealthyStatusSaysAllIsWellWithTheCounts() async {
    let service = service()
    await service.check(now: Date(timeIntervalSince1970: 1_790_000_000))
    let english = IntegrityText.status(service.record, in: environment(.english))
    XCTAssertTrue(english.contains("All is well") && english.contains("1 operation"), english)
    let russian = IntegrityText.status(service.record, in: environment(.russian))
    XCTAssertTrue(russian.contains("Всё в порядке") && russian.contains("1 операция"), russian)
  }

  func testEveryKeyOfTheCheckHasBothLanguages() {
    var keys = [
      "integrity.heading", "integrity.never", "integrity.ok", "integrity.check",
      "integrity.checking", "integrity.finding.repairable", "integrity.finding.reportOnly",
      "integrity.repair", "integrity.repair.title", "integrity.repair.yes",
      "integrity.repair.noCopy", "integrity.repair.failed", "integrity.report",
      "backups.name.beforeRepair",
    ]
    keys += DatabaseCheck.Rule.allCases.filter { $0 != .foreignKeys }.map {
      "integrity.finding.\($0.rawValue)"
    }
    keys.append("integrity.finding.foreignKeys")
    for choice in [AppLanguage.Choice.english, .russian] {
      let language = AppLanguage()
      language.choice = choice
      for key in keys {
        XCTAssertNotEqual(language(key, table: "Settings"), key, "\(key) in \(choice.rawValue)")
      }
    }
  }

  func testTheNameOfACopyBeforeARepairReadsInBothLanguages() {
    let moment = Date(timeIntervalSince1970: 1_790_000_000)
    for code in ["en", "ru"] {
      let name = BackupName(moment: moment, appVersion: "1.12.0", reason: .beforeRepair)
        .fileName(words: BackupWords.writer(code: code))
      XCTAssertEqual(BackupCopy.parse(name)?.reason, .beforeRepair, name)
      XCTAssertFalse(BackupReadable.isKept(for: .beforeRepair))
    }
  }
}
