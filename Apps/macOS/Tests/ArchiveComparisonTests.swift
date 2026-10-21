import AppCore
import AppDatabase
import SQLite3
import XCTest

@testable import OhMyMoney

/// «Сравнить с архивом…» (1.12, part 6): an archive of the transfer against the database now,
/// with and without a password, of the current schema and of an older one. Nothing is written to
/// the database, and no scratch folder is left however the comparison ends.
final class ArchiveComparisonTests: XCTestCase {
  private var directory: URL!
  private var scratch: URL!
  private var stack: DatabaseStack!

  /// The migrations of the bundle up to one name: the schema an older build shipped.
  private struct UpTo: SchemaSource {
    let last: String
    func migrations() throws -> [SchemaMigration] {
      try BundleSchemaSource(bundle: .main).migrations().filter { $0.name <= last }
    }
  }

  override func setUpWithError() throws {
    try super.setUpWithError()
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-archive-compare-\(UUID().uuidString)", isDirectory: true)
    scratch = directory.appendingPathComponent("scratch", isDirectory: true)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    stack = try DatabaseStack(
      url: directory.appendingPathComponent("finance.sqlite"),
      schema: BundleSchemaSource(bundle: .main))
    try save(note: "first")
  }

  override func tearDownWithError() throws {
    stack = nil
    try? FileManager.default.removeItem(at: directory)
    try super.tearDownWithError()
  }

  private func save(note: String) throws {
    var draft = TransactionDraft(amount: AmountE4(whole: 250), note: note)
    draft.normalizeSinglePart()
    try TransactionRepository(writer: stack.writer).save(try draft.materialize())
  }

  /// Runs one statement on a file with a connection of its own.
  private func sql(_ statement: String, on url: URL) throws {
    var handle: OpaquePointer?
    defer { sqlite3_close(handle) }
    guard sqlite3_open(url.path, &handle) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
    sqlite3_busy_timeout(handle, 5_000)
    guard sqlite3_exec(handle, statement, nil, nil, nil) == SQLITE_OK else {
      throw CocoaError(.fileWriteUnknown)
    }
  }

  private func text(_ query: String, on url: URL) throws -> String {
    var handle: OpaquePointer?
    defer { sqlite3_close(handle) }
    guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
      throw CocoaError(.fileReadUnknown)
    }
    var statement: OpaquePointer?
    defer { sqlite3_finalize(statement) }
    guard sqlite3_prepare_v2(handle, query, -1, &statement, nil) == SQLITE_OK,
      sqlite3_step(statement) == SQLITE_ROW, let cString = sqlite3_column_text(statement, 0)
    else { throw CocoaError(.fileReadCorruptFile) }
    return String(cString: cString)
  }

  /// One operation written the way a build of 1.5 wrote it: in the columns it had, with the
  /// stamps of the operation the current database holds.
  private func writeOlderOperation(note: String, into older: URL) throws {
    let stamp = try text("SELECT occurred_at FROM transactions LIMIT 1", on: stack.url)
    let id = UUID().uuidString
    try sql(
      """
      INSERT INTO transactions
        (id, kind, occurred_at, currency, amount_e4, amount_rub_e4, note, created_at, updated_at)
      VALUES ('\(id)', 'expense', '\(stamp)', 'RUB', 2500000, 2500000, '\(note)', '\(stamp)',
              '\(stamp)');
      INSERT INTO transaction_parts (id, transaction_id, amount_e4, amount_rub_e4)
      VALUES ('\(UUID().uuidString)', '\(id)', 2500000, 2500000);
      """, on: older)
  }

  private func service() -> ArchiveService {
    ArchiveService(stack: stack, appVersion: "1.12.0", iterations: 1_000)
  }

  private func current() async throws -> Dataset {
    try await DatasetRepository(writer: stack.writer).load(version: 0)
  }

  private func leftInScratch() -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: scratch.path)) ?? []).sorted()
  }

  func testAnArchiveWithoutAPasswordShowsWhatChangedSince() async throws {
    let url = directory.appendingPathComponent("plain.ohmymoneyarchive")
    try service().exportArchive(to: url)
    try save(note: "second")

    let comparison = try ArchiveComparison.compare(
      archiveAt: url, password: nil, with: try await current(), archives: service(),
      scratch: scratch)

    XCTAssertEqual(comparison.operationsInCopy, 1)
    XCTAssertEqual(comparison.operationsNow, 2)
    XCTAssertEqual(comparison.added.map(\.note), ["second"])
    XCTAssertTrue(comparison.vanished.isEmpty)
    XCTAssertEqual(leftInScratch(), [], "a scratch folder was left behind")
  }

  func testAnArchiveWithAPasswordAsksForItAndOpensWithIt() async throws {
    let url = directory.appendingPathComponent("sealed.ohmymoneyarchive")
    try service().exportArchive(to: url, password: "correct horse")
    XCTAssertTrue(ArchiveComparison.needsPassword(url, archives: service()))
    let plain = directory.appendingPathComponent("plain.ohmymoneyarchive")
    try service().exportArchive(to: plain)
    XCTAssertFalse(ArchiveComparison.needsPassword(plain, archives: service()))

    let comparison = try ArchiveComparison.compare(
      archiveAt: url, password: "correct horse", with: try await current(), archives: service(),
      scratch: scratch)

    XCTAssertTrue(comparison.isIdentical)
    XCTAssertEqual(leftInScratch(), [])
  }

  func testAWrongPasswordIsRefusedAndLeavesNothingBehind() async throws {
    let url = directory.appendingPathComponent("sealed.ohmymoneyarchive")
    try service().exportArchive(to: url, password: "correct horse")
    let dataset = try await current()
    let service = service()

    for wrong in ["", "battery staple", "Correct horse"] {
      do {
        _ = try ArchiveComparison.compare(
          archiveAt: url, password: wrong, with: dataset, archives: service, scratch: scratch)
        XCTFail("a wrong password must be refused: \(wrong)")
      } catch {
        let key = await MainActor.run { BackupComparisonSheet.failureKey(of: error) }
        XCTAssertEqual(key, "backups.compareArchive.wrongPassword", "\(wrong)")
      }
    }
    XCTAssertEqual(leftInScratch(), [])
  }

  func testTheDatabaseAndTheArchiveAreLeftAsTheyWere() async throws {
    let url = directory.appendingPathComponent("plain.ohmymoneyarchive")
    try service().exportArchive(to: url)
    try save(note: "second")
    let archiveBefore = try Data(contentsOf: url)
    let rowsBefore = try DatabaseStack.rowCounts(fileAt: stack.url)
    let dataset = try await current()

    _ = try ArchiveComparison.compare(
      archiveAt: url, password: nil, with: dataset, archives: service(), scratch: scratch)

    XCTAssertEqual(try Data(contentsOf: url), archiveBefore)
    XCTAssertEqual(try DatabaseStack.rowCounts(fileAt: stack.url), rowsBefore)
  }

  func testAnArchiveThatIsNotOneFailsWithoutAFolder() async throws {
    let url = directory.appendingPathComponent("junk.ohmymoneyarchive")
    try Data("not an archive".utf8).write(to: url)
    let dataset = try await current()
    XCTAssertThrowsError(
      try ArchiveComparison.compare(
        archiveAt: url, password: nil, with: dataset, archives: service(), scratch: scratch))
    XCTAssertEqual(leftInScratch(), [])
  }

  /// An archive written by an earlier build holds a database of an earlier schema: it is read
  /// in a scratch file brought up to date, and the comparison is the same.
  func testAnArchiveOfAnOlderSchemaIsComparedToo() async throws {
    let older = try DatabaseStack(
      url: directory.appendingPathComponent("older.sqlite"), schema: UpTo(last: "0006_banks"))
    try writeOlderOperation(note: "first", into: older.url)
    try? older.close()
    let file = directory.appendingPathComponent("older-snapshot.sqlite")
    try DatabaseStack.backup(fileAt: older.url, to: file)
    var builder = ArchiveBuilder(
      metadata: ArchiveBuilder.Metadata(
        appVersion: "1.5.0", schemaVersion: 6,
        createdAt: DateOnly(year: 2026, month: 9, day: 20), platform: "macOS", rowCounts: [:]))
    try builder.add(path: ArchivePaths.database, data: Data(contentsOf: file))
    try builder.add(path: ArchivePaths.settings, text: "{}")
    let url = directory.appendingPathComponent("older.ohmymoneyarchive")
    try builder.build().write(to: url)
    try save(note: "second")

    let comparison = try ArchiveComparison.compare(
      archiveAt: url, password: nil, with: try await current(), archives: service(),
      scratch: scratch)

    XCTAssertEqual(comparison.operationsInCopy, 1)
    XCTAssertEqual(comparison.operationsNow, 2)
    XCTAssertEqual(comparison.vanished.count, 1, "the older operation is not in the book now")
    XCTAssertEqual(comparison.added.count, 2)
    XCTAssertEqual(leftInScratch(), [])
  }

  /// A copy made before an update has the older schema as well; «Сравнить с текущей» reads it.
  func testACopyBeforeAnUpdateCanBeComparedAndDescribed() async throws {
    let older = try DatabaseStack(
      url: directory.appendingPathComponent("older.sqlite"), schema: UpTo(last: "0006_banks"))
    try writeOlderOperation(note: "first", into: older.url)
    try? older.close()
    let copy = directory.appendingPathComponent("copy.sqlite")
    try DatabaseStack.backup(fileAt: directory.appendingPathComponent("older.sqlite"), to: copy)

    let comparison = try BackupComparison.of(copyAt: copy, with: try await current())
    XCTAssertEqual(comparison.operationsInCopy, 1)

    let description = BackupDescription.compute(forCopyAt: copy, keeping: false)
    XCTAssertEqual(description?.operations, 1)
  }

  @MainActor
  func testTheWordsOfTheComparisonWithAnArchiveAreInBothLanguages() {
    for choice in [AppLanguage.Choice.english, .russian] {
      let language = AppLanguage()
      language.choice = choice
      for key in [
        "backups.compareArchive", "backups.compareArchive.note",
        "backups.compareArchive.wrongPassword", "backups.compare.failed",
      ] {
        XCTAssertNotEqual(language(key, table: "Settings"), key, "\(key) in \(choice.rawValue)")
      }
    }
  }
}
