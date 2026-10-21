import AppCore
import AppDatabase
import AppKit
import SQLite3
import SwiftUI
import XCTest

@testable import OhMyMoney

/// The owner's interface language and theme survive the tests (`AppDefaultsGuard`).
final class AppDefaultsGuardTests: XCTestCase {
  func testThePrincipalClassRegisteredTheGuard() {
    XCTAssertTrue(AppDefaultsGuard.isRegistered, "NSPrincipalClass of the test bundle")
  }

  func testEveryTestStartsWithoutAChoiceOfLanguage() throws {
    let domain = try XCTUnwrap(Bundle.main.bundleIdentifier)
    XCTAssertEqual(
      AppDefaultsGuard.Snapshot(of: .standard, domain: domain),
      AppDefaultsGuard.Snapshot())
  }

  /// The owner has Russian and no `AppleLanguages`; a test switches to English and writes
  /// both keys. Afterwards the owner has Russian again and no `AppleLanguages` — neither the
  /// test's nor a copy of the system's list.
  func testTheOwnersKeysComeBackAfterATestThatChangedThem() throws {
    let suite = "ohmymoney.tests.language.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("ru", forKey: AppDefaultsGuard.languageKey)

    let guardian = AppDefaultsGuard(defaults: defaults, domain: suite)
    XCTAssertEqual(guardian.owner, AppDefaultsGuard.Snapshot(language: "ru"))

    guardian.testCaseWillStart(self)
    XCTAssertEqual(
      AppDefaultsGuard.Snapshot(of: defaults, domain: suite), AppDefaultsGuard.Snapshot())

    defaults.set("en", forKey: AppDefaultsGuard.languageKey)
    defaults.set(["en"], forKey: AppDefaultsGuard.appleLanguagesKey)
    guardian.testCaseDidFinish(self)
    XCTAssertEqual(
      AppDefaultsGuard.Snapshot(of: defaults, domain: suite),
      AppDefaultsGuard.Snapshot(language: "ru"))

    // An owner with both keys gets both back.
    defaults.set(["ru"], forKey: AppDefaultsGuard.appleLanguagesKey)
    let both = AppDefaultsGuard(defaults: defaults, domain: suite)
    both.testCaseWillStart(self)
    AppLanguageWriter.choose("en", in: defaults)
    both.testBundleDidFinish(Bundle.main)
    XCTAssertEqual(
      AppDefaultsGuard.Snapshot(of: defaults, domain: suite),
      AppDefaultsGuard.Snapshot(language: "ru", appleLanguages: ["ru"]))
  }
}

/// What a choice of language writes (`AppLanguage.choice`), into any defaults.
private enum AppLanguageWriter {
  static func choose(_ code: String, in defaults: UserDefaults) {
    defaults.set(code, forKey: AppDefaultsGuard.languageKey)
    defaults.set([code], forKey: AppDefaultsGuard.appleLanguagesKey)
  }
}

/// The frames the secondary windows kept from the placeholders they began as go once
/// (`WindowFrames`).
final class WindowFramesTests: XCTestCase {
  func testTheSavedFramesOfTheSecondaryWindowsGoOnceAndNothingElse() throws {
    let suite = "ohmymoney.tests.frames.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let placeholder = "578 406 900 532 0 0 2056 1290 "
    let sidebar = "NSSplitView Subview Frames %@, SidebarNavigationSplitView"
    for window in ["transactions", "analytics", "reports"] {
      defaults.set(placeholder, forKey: "NSWindow Frame \(window)")
      defaults.set(
        ["0.000000, 0.000000, 240.000000, 532.000000, NO, NO"],
        forKey: String(format: sidebar, window))
    }
    let main = "453 357 1100 720 0 0 2056 1290 "
    defaults.set(main, forKey: "NSWindow Frame main-AppWindow-1")
    defaults.set("overview", forKey: "analytics.section")
    defaults.set(Data("{}".utf8), forKey: "transactions.columns")

    XCTAssertTrue(WindowFrames.resetOnce(in: defaults))
    XCTAssertNil(defaults.object(forKey: "transactions.columns"), "widths of the old order")
    for window in ["transactions", "analytics", "reports"] {
      XCTAssertNil(defaults.object(forKey: "NSWindow Frame \(window)"), window)
      XCTAssertNil(defaults.object(forKey: String(format: sidebar, window)), window)
    }
    XCTAssertEqual(defaults.string(forKey: "NSWindow Frame main-AppWindow-1"), main)
    XCTAssertEqual(defaults.string(forKey: "analytics.section"), "overview")
    XCTAssertTrue(defaults.bool(forKey: WindowFrames.resetFlag))

    // A size the owner gives a window afterwards is kept.
    let chosen = "100 100 1000 700 0 0 2056 1290 "
    defaults.set(chosen, forKey: "NSWindow Frame analytics")
    XCTAssertFalse(WindowFrames.resetOnce(in: defaults))
    XCTAssertEqual(defaults.string(forKey: "NSWindow Frame analytics"), chosen)
  }

  func testEverySecondaryWindowIsReset() {
    XCTAssertEqual(Set(WindowFrames.windows), ["transactions", "analytics", "reports", "whatif"])
  }
}

/// Any window starts the app (`AppLaunch`): a launch that restores only a secondary window
/// opens the database and runs the pipeline once; the windows after it change nothing.
@MainActor
final class AppLaunchTests: XCTestCase {
  /// A database of the test's own: `AppEnvironment.start` opens it there.
  private func scratchData() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-launch-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    setenv("OHMYMONEY_DATA_DIR", directory.path, 1)
    return directory
  }

  /// The folder goes only after the start of the test was stopped: its database closed, the
  /// mark of its session removed from it. A stop still pending when the override is
  /// unset closes a file nobody can reach, and removes the mark in the owner's Debug container
  /// instead.
  private func dropScratchData(
    _ directory: URL, file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertFalse(
      AppLaunch.hasStarted, "the scratch folder is about to go under a start still running",
      file: file, line: line)
    unsetenv("OHMYMONEY_DATA_DIR")
    try? FileManager.default.removeItem(at: directory)
  }

  func testASecondaryWindowAloneStartsThePipelineAndOnlyOnce() async throws {
    let directory = try scratchData()
    let environment = AppEnvironment()
    let store = TransactionsStore()
    let compute = ComputeStore(calendar: .utc)
    // The pipeline is still reading when the test ends: it is stopped and the database closed
    // before the folder goes.
    defer { dropScratchData(directory) }
    var made = 0
    let sources: AppLaunch.Sources = { _, _, calendar in
      made += 1
      return ComputeSources(
        loadData: { mark, today, _ in
          DataSnapshot.build(
            dataset: Dataset(entries: [], version: mark), calendar: calendar, today: today,
            context: SnapshotContext(), version: DataVersion(load: mark))
        },
        refineRates: { RefinementResult() })
    }

    // Transactions restored at launch, the main window closed before quitting.
    await AppLaunch.start(
      environment, store: store, compute: compute, startsPipeline: true, sources: sources)
    XCTAssertEqual(environment.state, .ready)
    XCTAssertTrue(store.isAttached)
    XCTAssertTrue(compute.isAttached)
    XCTAssertEqual(compute.lastRun, RunID(1), "the run of the launch")
    XCTAssertTrue(compute.isRunning)

    // Then the main window and Analytics: nothing is attached or run a second time.
    await AppLaunch.start(
      environment, store: store, compute: compute, startsPipeline: true, sources: sources)
    await AppLaunch.start(
      environment, store: store, compute: compute, startsPipeline: true, sources: sources)
    XCTAssertEqual(made, 1)
    XCTAssertEqual(compute.lastRun, RunID(1))

    await AppLaunch.stop(environment, compute: compute)
  }

  /// The scratch folder is removed only after the pipeline has stopped and the database is
  /// closed. Removed underneath them, SQLite writes «BUG IN CLIENT OF libsqlite3.dylib …
  /// vnode unlinked while in use» into the log and reads a file nobody can reach any more.
  func testTheDataIsClosedBeforeItsFolderGoes() async throws {
    let probe = LogProbe()
    let before = probe.counts(of: [LogProbe.Message.vnodeUnlinked])
    let directory = try scratchData()
    let environment = AppEnvironment()
    let store = TransactionsStore()
    let compute = ComputeStore(calendar: .utc)
    await AppLaunch.start(
      environment, store: store, compute: compute, startsPipeline: true,
      sources: Self.emptySources)
    XCTAssertTrue(compute.isRunning)

    await AppLaunch.stop(environment, compute: compute)
    dropScratchData(directory)
    // Whatever was still reading has to notice before the check means anything.
    for _ in 0..<10 { try? await Task.sleep(for: .milliseconds(50)) }

    probe.assertQuiet(
      about: [LogProbe.Message.vnodeUnlinked], comparedWith: before,
      "the folder went while the database was open")
  }

  /// A pipeline that reads nothing: the point of these tests is the order of the steps.
  private static let emptySources: AppLaunch.Sources = { _, _, calendar in
    ComputeSources(
      loadData: { mark, today, _ in
        DataSnapshot.build(
          dataset: Dataset(entries: [], version: mark), calendar: calendar, today: today,
          context: SnapshotContext(), version: DataVersion(load: mark))
      },
      refineRates: { RefinementResult() })
  }

  /// The ordered shutdown is final. `applicationShouldTerminate` answers `.terminateLater`,
  /// so for up to two seconds the app is still alive and still interactive: ⌘⇧T, a click in
  /// the Dock, a window macOS restores late — every one of them runs an `AppScenes.root`
  /// `.task` that has not run yet, and that calls `AppLaunch.start`. Before this test, that
  /// start passed its guard (`close()` leaves the state at `.starting`), opened the database
  /// a second time, moved a staged restore into place on the way, and left the stack open
  /// for the rest of the process — the very thing the ordered shutdown exists to prevent.
  func testAClosedEnvironmentDoesNotStartAgain() async throws {
    let directory = try scratchData()
    defer { dropScratchData(directory) }
    let environment = AppEnvironment()
    let store = TransactionsStore()
    let compute = ComputeStore(calendar: .utc)
    await AppLaunch.start(
      environment, store: store, compute: compute, startsPipeline: true,
      sources: Self.emptySources)
    XCTAssertEqual(environment.state, .ready)
    await AppLaunch.stop(environment, compute: compute)

    // A restore or an archive import staged a database before quitting: the next start is
    // what swaps it in, and it must be the next launch, not this process.
    let staged = AppPaths.pendingReplacementURL
    try Data("staged, not a database".utf8).write(to: staged)

    await AppLaunch.start(
      environment, store: store, compute: compute, startsPipeline: true,
      sources: Self.emptySources)

    XCTAssertNil(environment.stack, "a closed environment opened the database again")
    XCTAssertEqual(environment.state, .starting)
    XCTAssertTrue(environment.isClosed)
    XCTAssertFalse(compute.isAttached, "a stopped pipeline was attached again")
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: staged.path),
      "the staged database was swapped in after the shutdown")
    // Nor does it begin a session: a mark left now outlives the process and the next launch
    // reads it as a crash, and the journal the quit closed stays closed.
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: SessionMarker.url(in: AppPaths.logsDirectory).path),
      "a start after the shutdown left the mark of a running session")
    XCTAssertEqual(Logbook.shared.files(), [], "the journal was opened again after the shutdown")
  }

  /// Closing lets go of everything that was built on the database, not only of the
  /// repositories. The services are reached through the environment by name —
  /// `scheduleBackup()`, `applyRate(...)` — so left wired they went on writing through a
  /// closed connection for the whole terminate-later window, and the shutdown's promise that a
  /// late reader gets `nil` held only for readers that came through the repositories.
  func testTheOrderedStopLetsGoOfEverythingBuiltOnTheDatabase() async throws {
    let directory = try scratchData()
    defer { dropScratchData(directory) }
    let environment = AppEnvironment()
    let store = TransactionsStore()
    let compute = ComputeStore(calendar: .utc)
    await AppLaunch.start(
      environment, store: store, compute: compute, startsPipeline: true,
      sources: Self.emptySources)
    XCTAssertNotNil(environment.backups)
    XCTAssertTrue(store.isAttached)
    let rates = try XCTUnwrap(environment.rateService)

    await AppLaunch.stopStarted()

    XCTAssertNil(environment.backups)
    XCTAssertNil(environment.csvExport)
    XCTAssertNil(environment.archives)
    XCTAssertNil(environment.rateService)
    // A request `applyRate` fired before the stop holds the service itself: closed, it
    // writes nothing when the answer comes back.
    let ratesClosed = await rates.isClosed
    XCTAssertTrue(ratesClosed, "the rate service can still write after the database closed")
    XCTAssertNil(environment.mirrorFolder)
    XCTAssertFalse(store.isAttached, "the store still holds the database it was handed")
    XCTAssertTrue(
      store.didWrite == nil, "a write would still be reported to a closed environment")
    XCTAssertTrue(compute.onSnapshot == nil)
  }

  /// «Бэкап после каждого изменения: с задержкой несколько секунд» — the delay collapses a
  /// burst of edits into one copy, not the last edit into none. The owner saves «такси 540»
  /// and presses ⌘Q two seconds later: the ordered stop used to drop the copy still waiting
  /// out its debounce (cancelled so that nothing ran against a closing database), and the
  /// operation was in no copy — neither in `backups/` nor in the mirrored
  /// folder — until some later session wrote again.
  func testAChangeMadeJustBeforeQuittingIsInTheLastCopy() async throws {
    let directory = try scratchData()
    defer { dropScratchData(directory) }
    let environment = AppEnvironment()
    let store = TransactionsStore()
    let compute = ComputeStore(calendar: .utc)
    await AppLaunch.start(
      environment, store: store, compute: compute, startsPipeline: false,
      sources: Self.emptySources)
    var draft = TransactionDraft(amount: AmountE4(whole: 540), note: "synthetic")
    draft.normalizeSinglePart()
    let entry = try draft.materialize()

    XCTAssertTrue(store.save(entry))
    // The copy is armed; its debounce is seconds long, and the quit comes well inside it.
    try await Task.sleep(for: .milliseconds(200))
    await AppLaunch.stop(environment, compute: compute, store: store)

    let copies = try FileManager.default
      .contentsOfDirectory(at: AppPaths.backupsDirectory, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "sqlite" }
      .sorted { $0.lastPathComponent > $1.lastPathComponent }
    let last = try XCTUnwrap(copies.first, "the quit left no copy of the last change")
    let copy = try DatabaseStack(url: last, schema: BundleSchemaSource(bundle: .main))
    defer { try? copy.close() }
    XCTAssertNotNil(
      try TransactionRepository(writer: copy.writer).entry(id: entry.id),
      "the last copy does not have the change made before the quit")
  }

  /// «Бэкап после каждого изменения» holds for every write, not only for the store's: a change
  /// made in the settings through `environment.attempt` — the default currency, the enabled
  /// currencies — armed no copy, and a quit right after it left the newest copy without it.
  func testAChangeMadeInTheSettingsJustBeforeQuittingIsInTheLastCopy() async throws {
    let directory = try scratchData()
    defer { dropScratchData(directory) }
    let environment = AppEnvironment()
    let store = TransactionsStore()
    let compute = ComputeStore(calendar: .utc)
    await AppLaunch.start(
      environment, store: store, compute: compute, startsPipeline: false,
      sources: Self.emptySources)
    let enabled = try XCTUnwrap(environment.settings).enabledCurrencies()

    XCTAssertTrue(CurrenciesSettingsView.chooseDefault(.usd, in: environment))
    XCTAssertTrue(
      CurrenciesSettingsView.switchCurrency(
        .eur, on: true, enabled: try XCTUnwrap(environment.settings).enabledCurrencies(),
        in: environment))
    XCTAssertNotEqual(enabled, try XCTUnwrap(environment.settings).enabledCurrencies())
    // The copy is armed; its debounce is seconds long, and the quit comes well inside it.
    try await Task.sleep(for: .milliseconds(200))
    await AppLaunch.stop(environment, compute: compute, store: store)

    let copies = try FileManager.default
      .contentsOfDirectory(at: AppPaths.backupsDirectory, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "sqlite" }
      .sorted { $0.lastPathComponent > $1.lastPathComponent }
    let last = try XCTUnwrap(copies.first, "the quit left no copy of the change in the settings")
    let copy = try DatabaseStack(url: last, schema: BundleSchemaSource(bundle: .main))
    defer { try? copy.close() }
    let settings = SettingsRepository(writer: copy.writer)
    XCTAssertEqual(
      try settings.defaultCurrency(), .usd,
      "the last copy does not have the default currency chosen before the quit")
    XCTAssertTrue(
      try settings.enabledCurrencies().contains(.eur),
      "the last copy does not have the currency switched on before the quit")
  }

  /// The journal of a clean quit ends with the lines of the quit: the database closed, the
  /// application put down. They are what tells a clean quit from a crash, and they were
  /// logged into a journal whose close had already overtaken them.
  func testTheJournalOfACleanQuitEndsWithItsExitLines() async throws {
    let directory = try scratchData()
    defer { dropScratchData(directory) }
    let environment = AppEnvironment()
    let store = TransactionsStore()
    let compute = ComputeStore(calendar: .utc)
    await AppLaunch.start(
      environment, store: store, compute: compute, startsPipeline: false,
      sources: Self.emptySources)

    await AppLaunch.stop(environment, compute: compute, store: store)

    let journal = AppPaths.logsDirectory.appendingPathComponent("ohmymoney.log")
    let lines = try String(contentsOf: journal, encoding: .utf8).split(separator: "\n")
    XCTAssertTrue(lines.contains { $0.contains(" db.closed ") }, "no line says the database closed")
    XCTAssertTrue(
      lines.last?.contains(" app.stopped ") == true,
      "the journal does not end with the line of a clean quit")
  }

  /// A ⌘Q whose stop runs past the two seconds of `AppQuit` — the first run of a large set, a
  /// step of the model at launch — ended the process before the stop ended the session: the
  /// mark stayed, and the next launch wrote `session.interrupted` and offered a problem report
  /// after a quit the owner asked for. The quit now says in the journal that the stop overran,
  /// and ends the session and the journal itself before it answers.
  func testAQuitPastItsLimitIsNotReadAsACrash() async throws {
    let directory = try scratchData()
    defer { dropScratchData(directory) }
    let environment = AppEnvironment()
    let compute = ComputeStore(calendar: .utc)
    await AppLaunch.start(
      environment, store: TransactionsStore(), compute: compute, startsPipeline: false,
      sources: Self.emptySources)
    let mark = SessionMarker.url(in: AppPaths.logsDirectory)
    let journal = AppPaths.logsDirectory.appendingPathComponent("ohmymoney.log")
    XCTAssertTrue(FileManager.default.fileExists(atPath: mark.path))

    let delegate = AppDelegate()
    let clock = ManualClock()
    let gate = Gate()
    let answered = expectation(description: "AppKit is answered")
    delegate.clock = clock.clock
    delegate.stop = { await gate.wait() }
    delegate.answer = { _ in answered.fulfill() }
    XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateLater)
    clock.fire()
    await fulfillment(of: [answered], timeout: 2)

    XCTAssertFalse(
      FileManager.default.fileExists(atPath: mark.path),
      "the next launch will report a crash after a quit the owner asked for")
    let lines = try String(contentsOf: journal, encoding: .utf8).split(separator: "\n")
    XCTAssertTrue(lines.last?.contains(" app.stopOverran ") == true, String(lines.last ?? ""))

    gate.open()
    await AppLaunch.stop(environment, compute: compute)
  }

  /// «Перезапустить» pressed during a ⌘Q, or ⌘Q during a relaunch: two stops of one launch at
  /// once. The second found `running` still set — it is cleared only once the database has
  /// closed — and put the same environment down beside the first: two `app.stopping`, and the
  /// second, finding nothing left to close, ended the session and closed the journal while the
  /// first was still closing the database, so its `db.closed` never reached the file. The
  /// second stop now waits for the first.
  func testTwoStopsAtOnceAreOneStop() async throws {
    let directory = try scratchData()
    defer { dropScratchData(directory) }
    let environment = AppEnvironment()
    let compute = ComputeStore(calendar: .utc)
    await AppLaunch.start(
      environment, store: TransactionsStore(), compute: compute, startsPipeline: false,
      sources: Self.emptySources)
    let journal = AppPaths.logsDirectory.appendingPathComponent("ohmymoney.log")

    async let quit: Void = AppLaunch.stopStarted()
    async let relaunch: Void = AppLaunch.stopStarted()
    _ = await (quit, relaunch)

    XCTAssertTrue(environment.isClosed)
    let lines = try String(contentsOf: journal, encoding: .utf8).split(separator: "\n")
    XCTAssertEqual(lines.filter { $0.contains(" app.stopping ") }.count, 1, "two stops ran")
    XCTAssertEqual(lines.filter { $0.contains(" app.stopped ") }.count, 1, "two stops ran")
    XCTAssertTrue(lines.contains { $0.contains(" db.closed ") }, "no line says the database closed")
    XCTAssertTrue(lines.last?.contains(" app.stopped ") == true, String(lines.last ?? ""))
  }

  /// «System» chosen in an older build left the language of an earlier choice in
  /// `AppleLanguages` of the app's domain, and macOS draws the menus of every later launch in
  /// it. A launch makes that key agree with the choice stored beside it.
  func testALaunchMakesTheLanguageOfTheMenusAgreeWithTheChoice() async throws {
    let directory = try scratchData()
    defer { dropScratchData(directory) }
    let domain = try XCTUnwrap(Bundle.main.bundleIdentifier)
    let defaults = UserDefaults.standard
    defaults.set("system", forKey: AppDefaultsGuard.languageKey)
    defaults.set(["ru"], forKey: AppDefaultsGuard.appleLanguagesKey)
    let environment = AppEnvironment()
    let compute = ComputeStore(calendar: .utc)

    await AppLaunch.start(
      environment, store: TransactionsStore(), compute: compute, startsPipeline: false,
      sources: Self.emptySources)
    await AppLaunch.stop(environment, compute: compute)

    XCTAssertNil(
      defaults.persistentDomain(forName: domain)?[AppDefaultsGuard.appleLanguagesKey],
      "the menus of the next launch keep the language of a choice the owner took back")
  }

  /// Every window calls `AppLaunch.start`, so opening a second one must not look like a
  /// session that never ended. The mark belongs to the process, not to the window.
  func testASecondWindowDoesNotReportAnInterruptedSession() async throws {
    let directory = try scratchData()
    defer { dropScratchData(directory) }
    let environment = AppEnvironment()
    let store = TransactionsStore()
    let compute = ComputeStore(calendar: .utc)

    await AppLaunch.start(
      environment, store: store, compute: compute, startsPipeline: false,
      sources: Self.emptySources)
    XCTAssertFalse(environment.lastSessionWasInterrupted, "the first start reported a crash")

    await AppLaunch.start(
      environment, store: store, compute: compute, startsPipeline: false,
      sources: Self.emptySources)

    XCTAssertFalse(
      environment.lastSessionWasInterrupted,
      "a second window was read as a session that never ended")
    // Stopped here, before the folder goes: a stop left to a task of its own ran after the
    // folder was removed and the override unset, on a database nobody could reach, and took
    // the mark of the owner's running Debug session instead of this one.
    await AppLaunch.stop(environment, compute: compute, store: store)
  }

  /// «Любая перехваченная ошибка: тип». The type is the one diagnostic `db.failed` carries,
  /// and a name longer than a token — 24 characters — was written as `<not-a-token>`.
  func testTheTypeOfAnErrorIsInTheJournalWhateverItsLength() async throws {
    let logs = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-journal-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: logs) }
    Logbook.shared.open(directory: logs, threshold: .debug)
    let environment = AppEnvironment()

    await environment.start(preparing: { throw TheDatabaseFileCouldNotBeReadAtAll() })
    Logbook.shared.close()

    let journal = try String(
      contentsOf: logs.appendingPathComponent("ohmymoney.log"), encoding: .utf8)
    let failed = try XCTUnwrap(journal.split(separator: "\n").first { $0.contains(" db.failed ") })
    XCTAssertTrue(failed.contains(" error=TheDatabaseFileCouldNotBeReadAtAll"), String(failed))
  }

  private struct TheDatabaseFileCouldNotBeReadAtAll: Error {}

  /// «Миграции базы: с какой версии на какую, длительность, результат».
  /// An open that migrated said it in `db.opened`; a migration that stopped
  /// said only the type of its error — not which migration, nor from where to where.
  func testAMigrationThatStoppedSaysWhichOneAndFromWhereToWhere() async throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-migration-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("finance.sqlite")
    try DatabaseStack(url: url, schema: Self.TwoMigrations(count: 1)).close()
    Logbook.shared.open(directory: folder.appendingPathComponent("Logs"), threshold: .debug)
    let environment = AppEnvironment()

    await environment.start(preparing: {
      try DatabaseStack(url: url, schema: Self.TwoMigrations(count: 2))
    })
    Logbook.shared.close()

    XCTAssertEqual(environment.state, .failed(.other))
    let journal = try String(
      contentsOf: folder.appendingPathComponent("Logs/ohmymoney.log"), encoding: .utf8)
    let failed = try XCTUnwrap(journal.split(separator: "\n").first { $0.contains(" db.failed ") })
    for pair in ["from=1", "to=2", "migration=0002_broken", "error=DatabaseError"] {
      XCTAssertTrue(failed.contains(" \(pair)"), "\(pair) is not in: \(failed)")
    }
    XCTAssertTrue(failed.contains(" ms="), String(failed))
  }

  /// The first migration makes a table, the second makes it again and stops.
  private struct TwoMigrations: SchemaSource {
    let count: Int
    func migrations() throws -> [SchemaMigration] {
      Array(
        [
          SchemaMigration(name: "0001_first", sql: "CREATE TABLE a (id INTEGER);"),
          SchemaMigration(name: "0002_broken", sql: "CREATE TABLE a (id INTEGER);"),
        ].prefix(count))
    }
  }

  /// The line of the launch, with the versions, belongs to the process as the session does:
  /// three windows restored at launch are one launch, and a journal that read three
  /// `app.started` in a row looked like three launches of one session.
  func testThreeWindowsWriteOneLineOfTheLaunch() async throws {
    let directory = try scratchData()
    defer { dropScratchData(directory) }
    let environment = AppEnvironment()
    let store = TransactionsStore()
    let compute = ComputeStore(calendar: .utc)

    for _ in 0..<3 {
      await AppLaunch.start(
        environment, store: store, compute: compute, startsPipeline: false,
        sources: Self.emptySources)
    }
    let journal = AppPaths.logsDirectory.appendingPathComponent("ohmymoney.log")
    await AppLaunch.stop(environment, compute: compute, store: store)

    let lines = try String(contentsOf: journal, encoding: .utf8).split(separator: "\n")
    XCTAssertEqual(
      lines.filter { $0.contains(" app.started ") }.count, 1,
      "every window wrote a line of the launch")
  }

  /// «Если при следующем старте отметка осталась, в журнал пишется, что сессия оборвалась, и
  /// приложение предлагает собрать отчёт». The offer used to be a grey label at the bottom of
  /// a tab of the settings, where nobody looks after a crash; now the start raises it for the
  /// main window to ask.
  func testAnInterruptedSessionIsOfferedAProblemReport() async throws {
    let directory = try scratchData()
    defer { dropScratchData(directory) }
    try FileManager.default.createDirectory(
      at: AppPaths.logsDirectory, withIntermediateDirectories: true)
    try Data("started".utf8).write(to: SessionMarker.url(in: AppPaths.logsDirectory))
    let environment = AppEnvironment()
    let compute = ComputeStore(calendar: .utc)

    await AppLaunch.start(
      environment, store: TransactionsStore(), compute: compute, startsPipeline: false,
      sources: Self.emptySources)
    await AppLaunch.stop(environment, compute: compute)

    XCTAssertTrue(environment.lastSessionWasInterrupted)
    XCTAssertTrue(environment.offersProblemReport, "nothing offers to gather a report")
  }

  /// The same, with the two windows macOS restores at launch starting together rather than one
  /// after the other: the second used to pass the guard while the first was still opening the
  /// journal, find the mark the first had just left, and report a crash after a clean quit.
  func testTwoWindowsStartingTogetherDoNotReportAnInterruptedSession() async throws {
    let directory = try scratchData()
    defer { dropScratchData(directory) }
    let environment = AppEnvironment()
    let store = TransactionsStore()
    let compute = ComputeStore(calendar: .utc)

    async let first: Void = AppLaunch.start(
      environment, store: store, compute: compute, startsPipeline: false,
      sources: Self.emptySources)
    async let second: Void = AppLaunch.start(
      environment, store: store, compute: compute, startsPipeline: false,
      sources: Self.emptySources)
    _ = await (first, second)
    let journal = AppPaths.logsDirectory.appendingPathComponent("ohmymoney.log")
    await AppLaunch.stop(environment, compute: compute, store: store)

    XCTAssertFalse(
      environment.lastSessionWasInterrupted,
      "two windows starting together were read as a session that never ended")
    let lines = (try? String(contentsOf: journal, encoding: .utf8)) ?? ""
    XCTAssertFalse(lines.contains("session.interrupted"), "the journal reports a crash")
  }

  /// `--open` asks for its windows from the `.task` of the main window, before the root of
  /// that window has finished its start, so their starts run beside it (`LaunchWindows`).
  /// The open lets go of the main actor: a window that asks meanwhile is turned away at once,
  /// and the first attaches the store and runs the pipeline — once, whichever window it is.
  func testWindowsStartingBesideAnOpenGetOneDatabaseAndOneRun() async throws {
    let directory = try scratchData()
    defer { dropScratchData(directory) }
    let environment = AppEnvironment()
    let store = TransactionsStore()
    let compute = ComputeStore(calendar: .utc)
    var made = 0
    let sources: AppLaunch.Sources = { stack, rates, calendar in
      made += 1
      return Self.emptySources(stack, rates, calendar)
    }

    async let main: Void = AppLaunch.start(
      environment, store: store, compute: compute, startsPipeline: true, sources: sources)
    async let analytics: Void = AppLaunch.start(
      environment, store: store, compute: compute, startsPipeline: true, sources: sources)
    async let reports: Void = AppLaunch.start(
      environment, store: store, compute: compute, startsPipeline: true, sources: sources)
    _ = await (main, analytics, reports)

    XCTAssertEqual(environment.state, .ready)
    XCTAssertTrue(store.isAttached)
    XCTAssertTrue(compute.isAttached)
    XCTAssertEqual(made, 1, "the pipeline was wired more than once")
    XCTAssertEqual(compute.lastRun, RunID(1), "more than the one run of the launch")
    await AppLaunch.stop(environment, compute: compute, store: store)
  }

  /// A window of the app builds itself in the test host like any other, and its root used
  /// to start everything from `.task`: the owner's Debug database opened, a store attached
  /// to it, and `AppLaunch.running` left pointing at an environment no test can see. The
  /// database the tests want is their own; the app's must stay shut.
  func testAWindowOfTheAppStartsNothingInTheTestHost() throws {
    let directory = try scratchData()
    // Even while this was failing, nothing was written outside the scratch folder.
    defer { dropScratchData(directory) }
    XCTAssertTrue(AppEnvironment.isTestHost)
    let deps = AppDependencies(
      environment: AppEnvironment(), store: TransactionsStore(),
      compute: ComputeStore(calendar: .utc))
    let host = NSHostingView(rootView: AppScenes.root(deps, window: .main) { _ in Color.clear })
    host.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
    host.layoutSubtreeIfNeeded()
    for _ in 0..<20 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }

    XCTAssertEqual(deps.environment.state, .starting, "a window of the app opened a database")
    XCTAssertNil(deps.environment.stack)
    XCTAssertFalse(deps.store.isAttached)
    XCTAssertFalse(AppLaunch.hasStarted, "the quit was left something of the app's to close")
  }

  /// Two starts, one after another: the first is the one the quit closes. It used to be the
  /// last, so a test that started an environment of its own took the app's place — and a
  /// test that forgot to stop it left `stopStarted()` closing a test's database.
  func testTheFirstStartIsTheOneTheQuitCloses() async throws {
    let directory = try scratchData()
    defer { dropScratchData(directory) }
    let first = AppEnvironment()
    let second = AppEnvironment()
    let firstCompute = ComputeStore(calendar: .utc)
    let secondCompute = ComputeStore(calendar: .utc)
    await AppLaunch.start(
      first, store: TransactionsStore(), compute: firstCompute, startsPipeline: false,
      sources: Self.emptySources)
    await AppLaunch.start(
      second, store: TransactionsStore(), compute: secondCompute, startsPipeline: false,
      sources: Self.emptySources)

    await AppLaunch.stopStarted()

    XCTAssertTrue(first.isClosed, "the quit closed something other than the first start")
    XCTAssertFalse(second.isClosed, "the quit closed a start it never owned")
    await AppLaunch.stop(second, compute: secondCompute)
  }

  /// The window of a launch shows the start while the database opens: the migrations run off
  /// the main thread, as `start(preparing:)` makes a data set. Opened on the main actor, the
  /// start held it to the end — the progress of `.starting` was never drawn, and a slow
  /// migration of a future schema would freeze the first window with no sign of life.
  func testTheDatabaseOpensWhileTheMainActorIsFree() async throws {
    let directory = try scratchData()
    defer { dropScratchData(directory) }
    let environment = AppEnvironment()
    var seen: [AppEnvironment.State] = []
    // Waits for the main actor: it gets it only if the start lets go of it.
    let watcher = Task { @MainActor in seen.append(environment.state) }

    await environment.start()
    await watcher.value

    XCTAssertEqual(seen, [.starting], "the start held the main actor while the database opened")
    XCTAssertEqual(environment.state, .ready)
    await environment.close()
  }

  /// The open lets go of the main actor, so a ⌘Q can come while it runs: the quit closes the
  /// environment, and the stack the open makes afterwards is closed too — never handed to the
  /// closed environment, where it would stay open for the rest of the process — and nothing
  /// is said to have failed.
  func testAQuitWhileTheDatabaseOpensLeavesNothingOpen() async throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-overtaken-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("finance.sqlite")
    let entered = expectation(description: "the open has begun")
    let release = DispatchSemaphore(value: 0)
    let made = MadeStack()
    let environment = AppEnvironment()

    let start = Task { @MainActor in
      _ = await environment.start(preparing: {
        entered.fulfill()
        release.wait()
        let stack = try DatabaseStack(url: url, schema: BundleSchemaSource())
        made.stack = stack
        return stack
      })
    }
    await fulfillment(of: [entered], timeout: 5)
    await environment.close()
    release.signal()
    await start.value

    XCTAssertTrue(environment.isClosed)
    XCTAssertNil(environment.stack, "the open handed its stack to a closed environment")
    XCTAssertNil(environment.transactions)
    XCTAssertEqual(environment.state, .starting, "a start the quit overtook is not a failure")
    let stack = try XCTUnwrap(made.stack)
    XCTAssertThrowsError(
      try stack.appliedMigrations(), "the stack made after the quit was left open")
  }

  /// The stack a detached open made, read back once the open is over.
  private final class MadeStack: @unchecked Sendable {
    var stack: DatabaseStack?
  }

  /// «Ошибка одного блока интерфейса не роняет приложение: блок показывает сообщение и кнопку
  /// повтора». A database that did not open said only the name of the error's type —
  /// `DatabaseError` for a damaged file and for one a newer build wrote
  /// alike — so the window could not say which it was, nor what to do about it.
  func testADamagedDatabaseAndOneOfANewerBuildAreToldApart() async throws {
    let directory = try scratchData()
    defer { dropScratchData(directory) }
    try Self.writeDamagedDatabase()
    let damaged = AppEnvironment()
    await damaged.start()
    XCTAssertEqual(damaged.state, .failed(.damaged))
    Self.removeDatabase()

    try Self.writeDatabaseOfANewerBuild()
    let newer = AppEnvironment()
    await newer.start()
    XCTAssertEqual(newer.state, .failed(.newerSchema))

    // And each says so in words, in both languages.
    let language = AppLanguage()
    for choice in [AppLanguage.Choice.english, .russian] {
      language.choice = choice
      let messages = StartFailure.allCases.map { language($0.messageKey) }
      XCTAssertEqual(Set(messages).count, StartFailure.allCases.count, "\(choice): \(messages)")
      for (failure, message) in zip(StartFailure.allCases, messages) {
        XCTAssertNotEqual(message, failure.messageKey, "\(choice): no text for \(failure)")
      }
    }
  }

  /// «…и кнопку повтора»: the start is made again, and a database that opens then gets what a
  /// start gives it — the store attached, the pipeline too where there is one.
  func testAFailedStartIsMadeAgainAndAttachesWhatAStartAttaches() async throws {
    let directory = try scratchData()
    defer { dropScratchData(directory) }
    try Self.writeDamagedDatabase()
    let environment = AppEnvironment()
    let store = TransactionsStore()
    let compute = ComputeStore(calendar: .utc)
    await AppLaunch.start(
      environment, store: store, compute: compute, startsPipeline: true,
      sources: Self.emptySources)
    XCTAssertEqual(environment.state, .failed(.damaged))
    XCTAssertFalse(store.isAttached)

    // Retrying what has not changed fails the same way, and nothing is attached.
    await AppLaunch.retry(
      environment, store: store, compute: compute, startsPipeline: true,
      sources: Self.emptySources)
    XCTAssertEqual(environment.state, .failed(.damaged))
    XCTAssertFalse(store.isAttached)

    Self.removeDatabase()
    await AppLaunch.retry(
      environment, store: store, compute: compute, startsPipeline: true,
      sources: Self.emptySources)
    XCTAssertEqual(environment.state, .ready)
    XCTAssertTrue(store.isAttached, "the retried start left the store without the database")
    XCTAssertTrue(compute.isAttached, "the retried start left the pipeline without the database")

    // A start that is done is not made again.
    let stack = environment.stack
    await AppLaunch.retry(
      environment, store: store, compute: compute, startsPipeline: true,
      sources: Self.emptySources)
    XCTAssertTrue(environment.stack === stack)
    await AppLaunch.stop(environment, compute: compute, store: store)
  }

  /// Settings → Backups → Restore guarded on the backup service, which is built on the database
  /// that did not open: it did nothing, silently. A copy is now put in place without the
  /// database — the state before it copied into the list of copies as a restore always does,
  /// the file that did not open kept whole besides, never deleted — and
  /// the start made again opens the copy.
  func testACopyIsRestoredInPlaceOfADatabaseThatDidNotOpen() async throws {
    let directory = try scratchData()
    defer { dropScratchData(directory) }
    try AppPaths.ensureDirectories()
    // A copy as the app writes one: through the backup API, whole in its file. A restore
    // checks the file it puts in place, and the log of a database closed a moment ago may
    // still hold its tables.
    let copy = AppPaths.backupsDirectory.appendingPathComponent("finance-2026-09-20-0900.sqlite")
    let source = try DatabaseStack(
      url: directory.appendingPathComponent("source.sqlite"), schema: BundleSchemaSource())
    try source.backup(to: copy)
    try source.close()
    try Self.writeDamagedDatabase()
    let environment = AppEnvironment()
    let store = TransactionsStore()
    let compute = ComputeStore(calendar: .utc)

    // Nothing is moved while the database is open, or before a start has failed.
    do {
      try await DatabaseRecovery.stage(copy, replacing: environment)
      XCTFail("a copy was staged in place of a database whose start had not failed")
    } catch {
      XCTAssertEqual(error as? BackupRestoreFlow.Failure, .notStaged)
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: AppPaths.databaseURL.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: AppPaths.pendingReplacementURL.path))

    await AppLaunch.start(
      environment, store: store, compute: compute, startsPipeline: false,
      sources: Self.emptySources)
    XCTAssertEqual(environment.state, .failed(.damaged))
    // The copies are listed by the same service as ever, built over the file.
    let backups = try XCTUnwrap(environment.backups, "the copies are out of reach")
    let listed = try await backups.backups()
    XCTAssertEqual(listed, [copy])

    try await DatabaseRecovery.stage(copy, replacing: environment)
    await AppLaunch.retry(
      environment, store: store, compute: compute, startsPipeline: false,
      sources: Self.emptySources)

    XCTAssertEqual(environment.state, .ready)
    XCTAssertTrue(store.isAttached)
    XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path), "the copy itself went")
    let kept = try FileManager.default.contentsOfDirectory(
      at: DatabaseRecovery.damagedDirectory, includingPropertiesForKeys: nil)
    XCTAssertEqual(kept.count, 1, "the file that did not open was not kept: \(kept)")
    XCTAssertEqual(try kept.first.map { try Data(contentsOf: $0) }, Self.damagedBytes)
    let copies = try FileManager.default.contentsOfDirectory(
      atPath: AppPaths.backupsDirectory.path)
    XCTAssertTrue(
      copies.contains {
        $0.hasSuffix(".sqlite") && BackupCopy.parse($0)?.reason == .beforeRestore
          && BackupCopy.parse($0)?.damaged == true
      },
      "the state before the restore is not in the list of copies: \(copies)")
    await AppLaunch.stop(environment, compute: compute, store: store)
  }

  private static let damagedBytes = Data(repeating: 0x2A, count: 8_192)

  /// A file where the database should be that is not a database.
  private static func writeDamagedDatabase() throws {
    try AppPaths.ensureDirectories()
    try damagedBytes.write(to: AppPaths.databaseURL)
  }

  /// The database as it is on disk: the file, its log and its shared memory.
  private static func removeDatabase() {
    for part in ["", "-wal", "-shm"] {
      try? FileManager.default.removeItem(atPath: AppPaths.databaseURL.path + part)
    }
  }

  /// A database whose schema has a migration this build does not know: what a newer build
  /// leaves behind (`DatabaseError.migrationMismatch`).
  private static func writeDatabaseOfANewerBuild() throws {
    let stack = try DatabaseStack(url: AppPaths.databaseURL, schema: BundleSchemaSource())
    try stack.close()
    var handle: OpaquePointer?
    XCTAssertEqual(sqlite3_open(AppPaths.databaseURL.path, &handle), SQLITE_OK)
    defer { sqlite3_close(handle) }
    XCTAssertEqual(
      sqlite3_exec(
        handle, "INSERT INTO grdb_migrations (identifier) VALUES ('9999_newer')", nil, nil, nil),
      SQLITE_OK)
  }

  func testTheTestHostOpensTheDatabaseButStartsNoPipeline() async throws {
    let directory = try scratchData()
    defer { dropScratchData(directory) }
    XCTAssertTrue(AppEnvironment.isTestHost)
    let environment = AppEnvironment()
    let store = TransactionsStore()
    let compute = ComputeStore(calendar: .utc)
    await AppLaunch.start(environment, store: store, compute: compute)
    XCTAssertEqual(environment.state, .ready)
    XCTAssertTrue(store.isAttached)
    XCTAssertFalse(compute.isAttached)
    XCTAssertEqual(compute.lastRun, RunID(0))

    // Nothing was started here, and stopping must be safe all the same.
    await AppLaunch.stop(environment, compute: compute)
  }
}

/// The line under the cards of Overview when no day is listed: an empty book points to the
/// floating entry line.
@MainActor
final class OverviewEmptyLineTests: XCTestCase {
  private let today = DateOnly(year: 2026, month: 9, day: 18)

  private func snapshot(_ entries: [TransactionEntry]) -> DataSnapshot {
    DataSnapshot.build(
      dataset: Dataset(entries: entries, version: 1), calendar: .utc, today: today,
      context: SnapshotContext(), version: DataVersion(load: 1))
  }

  func testAnEmptyBookAsksForTheFirstOperationInTheFloatingLine() throws {
    XCTAssertNil(OverviewView.emptyLine(for: nil), "the state of the data step is shown then")

    let empty = try XCTUnwrap(OverviewView.emptyLine(for: snapshot([])))
    XCTAssertEqual(empty.key, "transactions.empty")
    XCTAssertEqual(empty.table, "Transactions")
    let language = AppLanguage()
    language.choice = .english
    XCTAssertEqual(
      language(empty.key, table: empty.table),
      "No operations yet. Type the first one in the floating entry line at the bottom of the "
        + "window.")
    language.choice = .russian
    XCTAssertEqual(
      language(empty.key, table: empty.table),
      "Операций пока нет. Введите первую в плавающей строке ввода внизу окна.")
  }

  func testABookOfOldOperationsPointsToTheTransactionsWindow() throws {
    var draft = TransactionDraft(
      occurredAt: CalendarContext.utc.startOfDay(DateOnly(year: 2026, month: 5, day: 4))
        .addingTimeInterval(9 * 3600),
      amount: AmountE4(whole: 250), note: "Coffee")
    draft.normalizeSinglePart()
    let line = try XCTUnwrap(OverviewView.emptyLine(for: snapshot([try draft.materialize()])))
    XCTAssertEqual(line.key, "overview.noRecent")
    XCTAssertEqual(line.table, "Overview")
  }
}

/// `--seed` of `make demo`: a Debug launch generates its set from the seed it was given, a
/// Release build ignores it, and anything that is not a whole number a journal can count is
/// passed over.
final class LaunchSeedTests: XCTestCase {
  func testADebugLaunchTakesTheSeedOfTheDemo() {
    let demo = LaunchOptions(
      arguments: ["OhMyMoney", "--data-set", "demo", "--generate", "12", "--seed", "184467440737"],
      debug: true)
    XCTAssertEqual(demo.dataSet, .demo)
    XCTAssertEqual(demo.generation, .months(12))
    XCTAssertEqual(demo.seed, 184_467_440_737)
    XCTAssertEqual(LaunchOptions(arguments: ["OhMyMoney", "--seed", "0"], debug: true).seed, 0)
    XCTAssertNil(LaunchOptions(arguments: ["OhMyMoney", "--generate", "6"], debug: true).seed)
  }

  func testAReleaseBuildIgnoresTheSeed() {
    let release = LaunchOptions(
      arguments: ["OhMyMoney", "--data-set", "demo", "--seed", "42"], debug: false)
    XCTAssertEqual(release.dataSet, .demo, "a Release build still opens a set that is there")
    XCTAssertNil(release.seed)
  }

  func testAMistypedSeedIsPassedOver() {
    for text in ["-5", "abc", "1.5", "", "9223372036854775808", "18446744073709551615"] {
      XCTAssertNil(
        LaunchOptions(arguments: ["OhMyMoney", "--seed", text], debug: true).seed, text)
    }
    XCTAssertEqual(
      LaunchOptions(arguments: ["OhMyMoney", "--seed", "9223372036854775807"], debug: true).seed,
      UInt64(Int.max))
  }

  #if DEBUG
    func testASetIsGeneratedFromTheSeedOfTheLaunchOrTheFixedOne() {
      let demo = LaunchOptions(arguments: ["OhMyMoney", "--seed", "42"], debug: true)
      XCTAssertEqual(DataSetGeneration.seed(of: demo), 42)
      XCTAssertEqual(
        DataSetGeneration.seed(of: LaunchOptions(arguments: ["OhMyMoney"], debug: true)), 20_260_918
      )
      XCTAssertEqual(DataSetGeneration.fixedSeed, 20_260_918)
    }
  #endif
}
