import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// «Восстановление — из настроек, с подтверждением. Перед восстановлением — автоматическая
/// копия текущего состояния». At the next launch the staged file takes the place of the
/// database and the old one is deleted, so whatever is not on disk before the
/// staging is gone for good.
final class BackupRestoreFlowTests: XCTestCase {
  private var directory: URL!
  private var stack: DatabaseStack!
  private var target: URL!

  override func setUpWithError() throws {
    try super.setUpWithError()
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-restore-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    stack = try DatabaseStack(
      url: directory.appendingPathComponent("finance.sqlite"),
      schema: BundleSchemaSource(bundle: .main))
    var draft = TransactionDraft(amount: AmountE4(whole: 250), note: "synthetic")
    draft.normalizeSinglePart()
    try TransactionRepository(writer: stack.writer).save(try draft.materialize())
    target = directory.appendingPathComponent("finance.pending.sqlite")
  }

  override func tearDownWithError() throws {
    stack = nil
    try? FileManager.default.removeItem(at: directory)
    try super.tearDownWithError()
  }

  /// A copy the owner could pick in the Backups tab: a real snapshot of the test database.
  private func chosenCopy() throws -> URL {
    let url = directory.appendingPathComponent("chosen/finance-2026-09-10T101500.sqlite")
    try stack.backup(to: url)
    return url
  }

  private var staged: Bool { FileManager.default.fileExists(atPath: target.path) }

  func testRestoringWritesTheCopyOfTheCurrentStateAndStagesTheChosenOne() async throws {
    let backups = BackupService(stack: stack, directory: directory.appendingPathComponent("b"))

    try await BackupRestoreFlow.stage(copy: try chosenCopy(), backups: backups, target: target)

    XCTAssertTrue(staged)
    let copies = try await backups.backups()
    XCTAssertEqual(copies.count, 1)
    let written = copies.first.flatMap { BackupCopy.parse($0.lastPathComponent) }
    XCTAssertEqual(written?.reason, .beforeRestore)
    XCTAssertEqual(written?.damaged, false)
    let restored = try DatabaseStack(url: target, schema: BundleSchemaSource(bundle: .main))
    XCTAssertEqual(try TransactionRepository(writer: restored.writer).count(), 1)
  }

  /// A copy of 1.12 is named by date, version and reason, in either language, and a name with
  /// spaces, dots and «·» is restored as a copy of 1.11 is: what is staged is the file chosen.
  func testACopyWithANameOfOnePointTwelveIsRestoredAsAnyOther() async throws {
    let backups = BackupService(stack: stack, directory: directory.appendingPathComponent("b"))
    let moment = Date(timeIntervalSince1970: 1_789_000_000)
    for code in ["ru", "en"] {
      let name = BackupName(moment: moment, appVersion: "1.12.0", reason: .daily)
        .fileName(words: BackupWords.writer(code: code))
      let url = directory.appendingPathComponent("chosen-\(code)/\(name)")
      try stack.backup(to: url)
      try? FileManager.default.removeItem(at: target)

      try await BackupRestoreFlow.stage(copy: url, backups: backups, target: target)

      XCTAssertTrue(staged, name)
      let restored = try DatabaseStack(url: target, schema: BundleSchemaSource(bundle: .main))
      XCTAssertEqual(try TransactionRepository(writer: restored.writer).count(), 1, name)
      try restored.close()
    }
  }

  /// The folder of copies cannot be written — here it is a file, as good as a full disk. The
  /// copy of the current state cannot exist, so nothing may be staged.
  func testRestoringStopsWhenTheCopyOfTheCurrentStateCannotBeWritten() async throws {
    let blocked = directory.appendingPathComponent("backups")
    try Data("a file where the folder should be".utf8).write(to: blocked)
    let backups = BackupService(stack: stack, directory: blocked)
    let chosen = try chosenCopy()

    do {
      try await BackupRestoreFlow.stage(copy: chosen, backups: backups, target: target)
      XCTFail("the restore went on without a copy of the current state")
    } catch {
      XCTAssertEqual(error as? BackupRestoreFlow.Failure, .noCopyOfTheCurrentState)
    }
    XCTAssertFalse(staged, "a copy was staged with nothing to come back to")
  }

  /// A file that is not a database — a copy left half-written by an older build, or one
  /// damaged on the disk — never reaches the place of the owner's database.
  func testRestoringRefusesACopyThatIsNotADatabase() async throws {
    let backups = BackupService(stack: stack, directory: directory.appendingPathComponent("b"))
    let chosen = directory.appendingPathComponent("finance-2026-09-10T101500.sqlite")
    try Data((0..<8192).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }).write(to: chosen)

    do {
      try await BackupRestoreFlow.stage(copy: chosen, backups: backups, target: target)
      XCTFail("a damaged copy was staged")
    } catch {
      XCTAssertEqual(error as? BackupRestoreFlow.Failure, .damagedCopy)
    }
    XCTAssertFalse(staged)
  }

  /// An empty file opens as an empty database, and an empty database passes
  /// `PRAGMA integrity_check`: this is what a copy that failed halfway used to leave behind.
  func testRestoringRefusesAnEmptyCopy() async throws {
    let backups = BackupService(stack: stack, directory: directory.appendingPathComponent("b"))
    let chosen = directory.appendingPathComponent("finance-2026-09-10T101500.sqlite")
    FileManager.default.createFile(atPath: chosen.path, contents: Data())

    do {
      try await BackupRestoreFlow.stage(copy: chosen, backups: backups, target: target)
      XCTFail("an empty copy was staged")
    } catch {
      XCTAssertEqual(error as? BackupRestoreFlow.Failure, .damagedCopy)
    }
    XCTAssertFalse(staged)
  }

  /// A copy written by a newer build passes its integrity check, and this build refuses to open
  /// it — at the next launch, after the database it replaced was gone. It is refused now.
  func testRestoringRefusesACopyOfANewerBuild() async throws {
    let backups = BackupService(stack: stack, directory: directory.appendingPathComponent("b"))
    let future = directory.appendingPathComponent("future.sqlite")
    try stack.backup(to: future)
    try DatabaseStack(url: future, schema: FutureSchema()).close()
    let chosen = directory.appendingPathComponent("finance-2026-09-10T101500.sqlite")
    try DatabaseStack.backup(fileAt: future, to: chosen)

    do {
      try await BackupRestoreFlow.stage(copy: chosen, backups: backups, target: target)
      XCTFail("a copy of a newer build was staged")
    } catch {
      XCTAssertEqual(error as? BackupRestoreFlow.Failure, .newerCopy)
    }
    XCTAssertFalse(staged)
    let copies = try await backups.backups()
    XCTAssertEqual(copies, [], "a copy of the current state for a restore that never happens")
  }

  /// The owner confirmed; the copy went away in the meantime. That is said, not swallowed.
  func testRestoringACopyThatIsGoneSaysSo() async throws {
    let backups = BackupService(stack: stack, directory: directory.appendingPathComponent("b"))
    let gone = directory.appendingPathComponent("finance-2026-09-10T101500.sqlite")

    do {
      try await BackupRestoreFlow.stage(copy: gone, backups: backups, target: target)
      XCTFail("a copy that is not there was restored in silence")
    } catch {
      XCTAssertEqual(error as? BackupRestoreFlow.Failure, .notStaged)
    }
    XCTAssertFalse(staged)
  }

  /// The one case where the copy of the current state cannot pass the check: the database
  /// itself is damaged, which is when a restore is needed most. The copy is as good as the
  /// state it copies, so it is kept — marked — and the restore goes on.
  func testADamagedCurrentStateIsKeptMarkedAndTheRestoreGoesOn() async throws {
    let backups = BackupService(
      source: DamagedSource(), directory: directory.appendingPathComponent("b"))

    try await BackupRestoreFlow.stage(copy: try chosenCopy(), backups: backups, target: target)

    XCTAssertTrue(staged)
    let copies = try await backups.backups().map(\.lastPathComponent)
    XCTAssertEqual(copies.count, 1)
    XCTAssertTrue(
      copies.first.flatMap { BackupCopy.parse($0) }.map {
        $0.reason == .beforeRestore && $0.damaged
      }
        == true, "\(copies)")
  }

  /// The words the owner reads when a restore stops, in both languages.
  @MainActor
  func testEveryReasonARestoreStopsHasWordsInBothLanguages() {
    let language = AppLanguage()
    let failures: [BackupRestoreFlow.Failure] = [
      .damagedCopy, .newerCopy, .noCopyOfTheCurrentState, .notStaged,
    ]
    for choice in [AppLanguage.Choice.english, .russian] {
      language.choice = choice
      for failure in failures {
        let key = failure.messageKey
        XCTAssertNotEqual(language(key, table: "Settings"), key, "\(key) in \(choice.rawValue)")
      }
    }
  }
}

/// A source whose every copy fails the check. By default the database fails it too — a damaged
/// database; with `databaseIsSound` the database is fine and only its copies come out wrong.
struct DamagedSource: BackupSource {
  var databaseIsSound = false

  func backup(to destination: URL) throws {
    try FileManager.default.createDirectory(
      at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("SQLite format 3\u{0}, and then nothing a reader could use".utf8).write(
      to: destination)
  }

  func integrityCheckPassed() throws -> Bool { databaseIsSound }
}

/// «Восстановление — из настроек»: exactly when the database does not open is when a copy is
/// needed. Every way back used to hang on the services an open database
/// gives the environment: the Backups tab said «no copies» over a folder of them, «Restore» did
/// nothing, and the main window showed the name of a Swift type.
@MainActor
final class DatabaseThatDoesNotOpenTests: XCTestCase {
  private var directory: URL!
  private var environment: AppEnvironment?

  override func setUp() async throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-unopened-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    setenv("OHMYMONEY_DATA_DIR", directory.path, 1)
  }

  override func tearDown() async throws {
    if let environment { await environment.close() }
    unsetenv("OHMYMONEY_DATA_DIR")
    try? FileManager.default.removeItem(at: directory)
  }

  /// A database of the owner's with one operation, and one copy of it in `backups/`.
  private func bookWithACopy() async throws {
    let stack = try DatabaseStack(
      url: AppPaths.databaseURL, schema: BundleSchemaSource(bundle: .main))
    var draft = TransactionDraft(amount: AmountE4(whole: 250), note: "synthetic")
    draft.normalizeSinglePart()
    try TransactionRepository(writer: stack.writer).save(try draft.materialize())
    let backups = BackupService(stack: stack, directory: AppPaths.backupsDirectory)
    _ = try await backups.writeBackup(now: Date(timeIntervalSince1970: 1_789_000_000))
    try stack.close()
  }

  private func start() async -> AppEnvironment {
    let environment = AppEnvironment()
    self.environment = environment
    environment.backupFolder = BookmarkStore(key: "tests.unopened.\(UUID().uuidString)")
    await environment.start()
    return environment
  }

  private func failureKey(of environment: AppEnvironment) -> String? {
    guard case .failed(let failure) = environment.state else { return nil }
    return failure.messageKey
  }

  /// The words of a failure are a key of the catalog, in both languages — never a type name.
  private func assertWords(_ key: String?, file: StaticString = #filePath, line: UInt = #line) {
    guard let key else { return XCTFail("the database opened", file: file, line: line) }
    let language = AppLanguage()
    for choice in [AppLanguage.Choice.english, .russian] {
      language.choice = choice
      XCTAssertNotEqual(language(key), key, "\(key) in \(choice.rawValue)", file: file, line: line)
    }
  }

  /// A copy written by a build with a migration this one does not have — restored from a
  /// newer build, or the database itself after a downgrade. The owner is asked to update, the
  /// copies are listed, and a restore still writes the state before it first.
  func testADatabaseOfANewerBuildIsExplainedAndItsCopiesStayReachable() async throws {
    try await bookWithACopy()
    let newer = try DatabaseStack(url: AppPaths.databaseURL, schema: FutureSchema())
    try newer.close()

    let environment = await start()

    XCTAssertEqual(failureKey(of: environment), "error.database.newerSchema")
    assertWords(failureKey(of: environment))
    let backups = try XCTUnwrap(environment.backups, "the Backups tab has nothing to list")
    let copies = try await backups.backups()
    XCTAssertEqual(copies.count, 1, "the copy on disk is not offered")

    try await BackupRestoreFlow.stage(
      copy: try XCTUnwrap(copies.first), backups: backups, target: AppPaths.pendingReplacementURL)

    XCTAssertTrue(FileManager.default.fileExists(atPath: AppPaths.pendingReplacementURL.path))
    let before = try await backups.backups().map(\.lastPathComponent)
    let copyOfTheNewer = try XCTUnwrap(
      before.first { BackupCopy.parse($0)?.reason == .beforeRestore })
    // The state before the restore is the newer database itself, whole: a newer build opens it.
    let reopened = try DatabaseStack(
      url: AppPaths.backupsDirectory.appendingPathComponent(copyOfTheNewer), schema: FutureSchema())
    XCTAssertEqual(try TransactionRepository(writer: reopened.writer).count(), 1)
    try reopened.close()
  }

  /// The file is not a database at all — the power went, the disk failed. Its copy is kept,
  /// marked, as it is, and the restore goes on.
  func testAFileThatIsNotADatabaseStillLetsACopyBeRestored() async throws {
    try await bookWithACopy()
    // The log goes too: a page of the database still in it would be read in place of the file.
    for part in ["-wal", "-shm"] {
      try? FileManager.default.removeItem(atPath: AppPaths.databaseURL.path + part)
    }
    try Data((0..<8192).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
      .write(to: AppPaths.databaseURL)

    let environment = await start()

    XCTAssertEqual(failureKey(of: environment), "error.database.damaged")
    assertWords(failureKey(of: environment))
    let backups = try XCTUnwrap(environment.backups, "the Backups tab has nothing to list")
    let copies = try await backups.backups()
    XCTAssertEqual(copies.count, 1)

    try await BackupRestoreFlow.stage(
      copy: try XCTUnwrap(copies.first), backups: backups, target: AppPaths.pendingReplacementURL)

    XCTAssertTrue(FileManager.default.fileExists(atPath: AppPaths.pendingReplacementURL.path))
    let before = try await backups.backups().map(\.lastPathComponent)
    XCTAssertTrue(
      before.contains {
        BackupCopy.parse($0).map { $0.reason == .beforeRestore && $0.damaged } == true
      }, "\(before)")
  }
}

/// «Перед заменой — автоматический бэкап текущего состояния»: the owner
/// confirmed a restore or an import and saw the app relaunch. When the staged file could not
/// be put in place, the launch used to open the old database without a word and try again at
/// every launch after, in silence for good.
@MainActor
final class StagedReplacementAtLaunchTests: XCTestCase {
  private var directory: URL!
  private var environment: AppEnvironment?
  private var aside: URL { URL(fileURLWithPath: AppPaths.databaseURL.path + ".replaced") }

  override func setUp() async throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-staged-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    setenv("OHMYMONEY_DATA_DIR", directory.path, 1)
    Logbook.shared.open(
      directory: directory.appendingPathComponent("TestLogs", isDirectory: true),
      threshold: .debug)
  }

  override func tearDown() async throws {
    if let environment { await environment.close() }
    Logbook.shared.close()
    try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: aside.path)
    unsetenv("OHMYMONEY_DATA_DIR")
    try? FileManager.default.removeItem(at: directory)
  }

  private func start() async -> AppEnvironment {
    let environment = AppEnvironment()
    self.environment = environment
    environment.backupFolder = BookmarkStore(key: "tests.staged.\(UUID().uuidString)")
    await environment.start()
    return environment
  }

  private func journal(contains needle: String) async -> Bool {
    for _ in 0..<50 {
      if Logbook.shared.lines().contains(where: { $0.contains(needle) }) { return true }
      try? await Task.sleep(for: .milliseconds(20))
    }
    return false
  }

  /// A database in place and a sound one staged beside it.
  private func stageASoundDatabase() throws {
    try DatabaseStack(url: AppPaths.databaseURL, schema: BundleSchemaSource(bundle: .main))
      .close()
    try DatabaseStack.backup(fileAt: AppPaths.databaseURL, to: AppPaths.pendingReplacementURL)
  }

  /// The place the database is moved aside to is taken and cannot be cleared — as good as a
  /// folder a sync client holds, or a file without write permission.
  private func blockTheWayAside() throws {
    try FileManager.default.createDirectory(at: aside, withIntermediateDirectories: true)
    try Data("held".utf8).write(to: aside.appendingPathComponent("held"))
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: aside.path)
  }

  func testAStagedDatabaseThatCannotBePutInPlaceIsSaidNotSwallowed() async throws {
    try stageASoundDatabase()
    try blockTheWayAside()

    let environment = await start()

    XCTAssertEqual(environment.state, .ready, "the database there was is not open")
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: AppPaths.pendingReplacementURL.path),
      "the staged file is gone, and with it the retry")
    let logged = await journal(contains: "db.replacementFailed")
    XCTAssertTrue(logged, "the replacement that did not happen is not in the journal")
    XCTAssertEqual(
      environment.replacementProblem, .notApplied, "the main window is not asked to say so")
  }

  /// A staged database this build cannot open — a newer build wrote it, and a build that did
  /// not check staged it — used to cost the database it replaced: that one was deleted before
  /// the new one was tried, and the launch ended on «the database could not be opened». Now the
  /// staged file is asked first: it is dropped, the database there was stays, and the owner is
  /// told.
  func testAStagedDatabaseThisBuildCannotOpenDoesNotTakeThePlaceOfTheOne() async throws {
    let live = try DatabaseStack(
      url: AppPaths.databaseURL, schema: BundleSchemaSource(bundle: .main))
    var draft = TransactionDraft(amount: AmountE4(whole: 250), note: "synthetic")
    draft.normalizeSinglePart()
    try TransactionRepository(writer: live.writer).save(try draft.materialize())
    try live.close()
    let future = directory.appendingPathComponent("future.sqlite")
    try DatabaseStack(url: future, schema: FutureSchema()).close()
    try DatabaseStack.backup(fileAt: future, to: AppPaths.pendingReplacementURL)

    let environment = await start()

    XCTAssertEqual(environment.state, .ready, "the database there was did not come back")
    XCTAssertEqual(try environment.transactions?.count(), 1)
    XCTAssertFalse(FileManager.default.fileExists(atPath: AppPaths.pendingReplacementURL.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: aside.path), "a copy was left aside")
    let logged = await journal(contains: "db.replacementRefused")
    XCTAssertTrue(logged, "the database that did not open is not in the journal")
    XCTAssertEqual(environment.replacementProblem, .refused, "the owner is not told")
  }

  /// A staged file that is not a database at all goes the same way.
  func testAStagedFileThatIsNotADatabaseDoesNotTakeThePlaceOfTheOne() async throws {
    try stageASoundDatabase()
    try Data("not a database".utf8).write(to: AppPaths.pendingReplacementURL)

    let environment = await start()

    XCTAssertEqual(environment.state, .ready)
    XCTAssertEqual(environment.replacementProblem, .refused)
    XCTAssertFalse(FileManager.default.fileExists(atPath: AppPaths.pendingReplacementURL.path))
  }

  /// The database put in place opens: the one it replaced is not kept a moment longer.
  func testAStagedDatabaseThatOpensLeavesNothingAside() async throws {
    try stageASoundDatabase()

    let environment = await start()

    XCTAssertEqual(environment.state, .ready)
    XCTAssertNil(environment.replacementProblem)
    XCTAssertFalse(FileManager.default.fileExists(atPath: aside.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: AppPaths.pendingReplacementURL.path))
  }

  /// «Отказаться»: the staged file goes, and the next launch tries nothing.
  func testGivingUpOnAStagedDatabaseStopsTheRetries() async throws {
    try stageASoundDatabase()
    try blockTheWayAside()
    let environment = await start()
    XCTAssertEqual(environment.replacementProblem, .notApplied)

    AppPaths.discardPendingReplacement()

    XCTAssertFalse(FileManager.default.fileExists(atPath: AppPaths.pendingReplacementURL.path))
  }

  /// The words of the alert, in both languages.
  func testTheAlertAboutAStagedDatabaseHasWordsInBothLanguages() {
    let language = AppLanguage()
    let keys = [
      "replacement.notApplied.title", "replacement.notApplied.message", "replacement.giveUp",
      "replacement.refused.title", "replacement.refused.message",
    ]
    for choice in [AppLanguage.Choice.english, .russian] {
      language.choice = choice
      for key in keys {
        XCTAssertNotEqual(language(key), key, "\(key) in \(choice.rawValue)")
      }
    }
  }
}

/// The schema of a build newer than this one: every migration of `Schema/` and one more.
struct FutureSchema: SchemaSource {
  func migrations() throws -> [SchemaMigration] {
    try BundleSchemaSource(bundle: .main).migrations() + [
      SchemaMigration(name: "9999_future", sql: "CREATE TABLE future_things (id INTEGER)")
    ]
  }
}
