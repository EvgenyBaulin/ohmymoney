import AppCore
import AppDatabase
import AppKit
import SwiftUI
import XCTest

@testable import OhMyMoney

/// No window of the app is a tab, the menus carry no tab items, a secondary window stands over
/// a main window in full screen at a size that fits the screen, and ⌘⇧T brings the same window
/// forward rather than a second one.
@MainActor
final class AppWindowsTests: XCTestCase {
  private var windows: [NSWindow] = []
  /// The windows the test host had on screen, put away for the test and shown again after it.
  private var putAway: [NSWindow] = []

  override func setUp() async throws {
    AppWindows.forgetAll()
  }

  override func tearDown() async throws {
    for window in windows {
      window.contentViewController = nil
      window.close()
    }
    windows = []
    for window in putAway { window.orderFront(nil) }
    putAway = []
    AppWindows.forgetAll()
    try await Task.sleep(for: .milliseconds(100))
  }

  private func clearTheScreen() {
    putAway = NSApp.windows.filter(\.isVisible)
    for window in putAway { window.orderOut(nil) }
  }

  private func window<Content: View>(_ content: Content, width: CGFloat = 760) -> NSWindow {
    let window = NSWindow(
      contentRect: CGRect(x: 40, y: 40, width: width, height: 520),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    // dependencies: none — the content is a plain colour with the mark of its role.
    window.contentViewController = NSHostingController(rootView: content)
    windows.append(window)
    return window
  }

  private func waitUntil(_ condition: () -> Bool, seconds: TimeInterval = 3) {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition(), Date() < deadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
  }

  // MARK: - Rules

  func testTheMainWindowGoesFullScreenAndTheOthersStandOverIt() {
    let main = AppWindows.collectionBehavior(for: .main, from: [.fullScreenAuxiliary])
    XCTAssertTrue(main.contains(.fullScreenPrimary))
    XCTAssertFalse(main.contains(.fullScreenAuxiliary))
    XCTAssertFalse(main.contains(.moveToActiveSpace))

    for role in [AppWindows.Role.secondary(scene: "transactions"), .settings] {
      let behavior = AppWindows.collectionBehavior(
        for: role, from: [.fullScreenPrimary, .canJoinAllSpaces, .managed])
      XCTAssertTrue(behavior.contains(.fullScreenAuxiliary), "\(role)")
      XCTAssertTrue(behavior.contains(.moveToActiveSpace), "\(role)")
      XCTAssertFalse(behavior.contains(.fullScreenPrimary), "\(role): two kinds of full screen")
      XCTAssertFalse(behavior.contains(.canJoinAllSpaces), "\(role): two Space moves")
      XCTAssertTrue(behavior.contains(.managed), "\(role): what else it had is kept")
    }
  }

  func testAFrameIsNeverLargerThanTheScreen() {
    let screen = CGRect(x: 0, y: 0, width: 1440, height: 875)
    let fits = CGRect(x: 100, y: 80, width: 1100, height: 760)
    XCTAssertEqual(AppWindows.fitting(fits, in: screen), fits, "a frame that fits stays")

    let wide = AppWindows.fitting(CGRect(x: 300, y: 200, width: 2000, height: 1200), in: screen)
    XCTAssertEqual(wide, screen, "shrunk to the screen and moved onto it")

    let off = AppWindows.fitting(CGRect(x: 1000, y: -50, width: 800, height: 500), in: screen)
    XCTAssertEqual(off, CGRect(x: 640, y: 0, width: 800, height: 500), "moved, not shrunk")

    let second = CGRect(x: 1440, y: 0, width: 1920, height: 1055)
    let there = AppWindows.fitting(CGRect(x: 1500, y: 100, width: 1120, height: 720), in: second)
    XCTAssertEqual(there, CGRect(x: 1500, y: 100, width: 1120, height: 720), "a second screen")
  }

  func testClosingTheMainWindowOrTheLastOneQuits() {
    let transactions = AppWindows.Role.secondary(scene: "transactions")
    XCTAssertTrue(AppWindows.quitsOnClose(.main, othersOpen: []))
    XCTAssertTrue(
      AppWindows.quitsOnClose(.main, othersOpen: [transactions, .settings]),
      "the main window quits even with Transactions and Settings open")
    XCTAssertFalse(
      AppWindows.quitsOnClose(transactions, othersOpen: [.main]),
      "a secondary window closed beside the main one only closes")
    XCTAssertFalse(AppWindows.quitsOnClose(.settings, othersOpen: [.main, transactions]))
    XCTAssertTrue(AppWindows.quitsOnClose(transactions, othersOpen: []), "the last window")
    XCTAssertTrue(AppWindows.quitsOnClose(.settings, othersOpen: []), "the last window")
  }

  /// ⌃⌘F opens and closes full screen of the main window (owner, 15.10): the menu carries the
  /// item with exactly that shortcut, and with no main window open it does nothing.
  func testControlCommandFToggleFullScreenOfTheMainWindow() {
    XCTAssertFalse(AppWindows.toggleFullScreen(), "no main window, nothing to toggle")
    func items(_ menu: NSMenu?) -> [NSMenuItem] {
      (menu?.items ?? []).flatMap { [$0] + items($0.submenu) }
    }
    let found = items(NSApp.mainMenu).filter {
      $0.keyEquivalent == "f"
        && $0.keyEquivalentModifierMask.intersection([.command, .control, .option, .shift])
          == [.command, .control]
    }
    XCTAssertFalse(found.isEmpty, "no ⌃⌘F in the menus")
  }

  // MARK: - The app

  /// The app turns the system's automatic tabbing off before its first window.
  func testTheAppAllowsNoAutomaticTabbing() {
    XCTAssertFalse(NSWindow.allowsAutomaticWindowTabbing)
  }

  /// The menu bar the test host built has no item of the tabs.
  func testTheMenusHaveNoTabItems() {
    func items(_ menu: NSMenu?) -> [NSMenuItem] {
      (menu?.items ?? []).flatMap { [$0] + items($0.submenu) }
    }
    let tabActions: Set<String> = [
      "toggleTabBar:", "toggleTabOverview:", "mergeAllWindows:", "moveTabToNewWindow:",
      "selectNextTab:", "selectPreviousTab:", "newWindowForTab:",
    ]
    let found = items(NSApp.mainMenu).filter {
      $0.action.map { tabActions.contains(NSStringFromSelector($0)) } ?? false
    }
    XCTAssertTrue(found.isEmpty, "tab items in the menus: \(found.map(\.title))")
  }

  // MARK: - Real windows

  /// The main window, a secondary one and Settings: none can become a tab, each has the
  /// behaviour of its role, and a window shown beside the main one stays a window of its own.
  func testEveryWindowIsAWindowOfItsOwn() throws {
    try TestEnvironment.requireScreen(width: 800)
    clearTheScreen()
    let main = window(Color.clear.appWindow(.main))
    main.orderFront(nil)
    let analytics = window(Color.clear.appWindow(.secondary(scene: "analytics.test")))
    analytics.orderFront(nil)
    let settings = window(Color.clear.appWindow(.settings))
    settings.orderFront(nil)
    waitUntil { AppWindows.openRoles().count == 3 }

    for (window, name) in [(main, "main"), (analytics, "analytics"), (settings, "settings")] {
      XCTAssertEqual(window.tabbingMode, .disallowed, name)
      XCTAssertTrue(window.tabbedWindows == nil, "\(name) is a tab")
    }
    XCTAssertTrue(main.collectionBehavior.contains(.fullScreenPrimary))
    for window in [analytics, settings] {
      XCTAssertTrue(window.collectionBehavior.contains(.fullScreenAuxiliary))
      XCTAssertTrue(window.collectionBehavior.contains(.moveToActiveSpace))
    }

    // What «Merge All Windows» would do, were it offered: nothing merges.
    main.mergeAllWindows(nil)
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    XCTAssertTrue(main.tabbedWindows == nil, "the windows merged into tabs")
  }

  /// A second ⌘⇧T brings the same window forward: there is one window of the scene, in front.
  func testASecondOpeningBringsTheSameWindowForward() throws {
    try TestEnvironment.requireScreen(width: 800)
    clearTheScreen()
    let main = window(Color.clear.appWindow(.main))
    main.orderFront(nil)
    let role = AppWindows.Role.secondary(scene: "transactions.test")
    let transactions = window(Color.clear.appWindow(role))
    transactions.orderFront(nil)
    waitUntil { AppWindows.window(of: role) === transactions }
    // Put behind everything, as a window left under others is.
    transactions.orderOut(nil)
    XCTAssertFalse(transactions.isVisible)

    let brought = AppWindows.bringForward(role)
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    XCTAssertTrue(brought === transactions, "a second window of the scene")
    XCTAssertTrue(transactions.isVisible, "it did not come forward")
    // AppKit reorders the windows of an app that is not active only loosely; while the test host
    // is the active app, the window stands in front of the main one.
    try TestEnvironment.requireActiveApp()
    XCTAssertLessThan(transactions.orderedIndex, main.orderedIndex, "behind the main window")
    XCTAssertEqual(AppWindows.openRoles().filter { $0 == role }.count, 1)
  }

  /// A secondary window larger than the screen opens fitted to it.
  func testASecondaryWindowLargerThanTheScreenIsFitted() throws {
    try TestEnvironment.requireScreen(width: 800)
    clearTheScreen()
    let huge = window(Color.clear, width: 6000)
    huge.orderFront(nil)
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    AppWindows.mark(huge, as: .secondary(scene: "reports.test"))
    let visible = try XCTUnwrap((huge.screen ?? NSScreen.main)?.visibleFrame)
    XCTAssertLessThanOrEqual(huge.frame.width, visible.width)
    XCTAssertLessThanOrEqual(huge.frame.height, visible.height)
  }

  // MARK: - Closing

  /// Closing a secondary window beside the main one only closes it; closing the main one asks
  /// the app to quit, though Settings is still open.
  func testClosingTheMainWindowAsksTheAppToQuit() throws {
    var asked = 0
    let terminate = AppWindows.terminate
    AppWindows.terminate = { asked += 1 }
    defer { AppWindows.terminate = terminate }
    let main = window(Color.clear)
    let reports = window(Color.clear)
    let settings = window(Color.clear)
    AppWindows.mark(main, as: .main)
    AppWindows.mark(reports, as: .secondary(scene: "reports.close"))
    AppWindows.mark(settings, as: .settings)

    reports.close()
    XCTAssertEqual(asked, 0, "a secondary window closed beside the main one quit the app")
    main.close()
    XCTAssertEqual(asked, 1, "closing the main window did not ask to quit")
    settings.close()
    XCTAssertEqual(asked, 2, "the test host asks again: it never really quits")
  }

  /// The last window of the app, whichever it is, quits when it closes.
  func testClosingTheLastWindowAsksTheAppToQuit() throws {
    var asked = 0
    let terminate = AppWindows.terminate
    AppWindows.terminate = { asked += 1 }
    defer { AppWindows.terminate = terminate }
    let analytics = window(Color.clear)
    let reports = window(Color.clear)
    AppWindows.mark(analytics, as: .secondary(scene: "analytics.last"))
    AppWindows.mark(reports, as: .secondary(scene: "reports.last"))

    analytics.close()
    XCTAssertEqual(asked, 0)
    reports.close()
    XCTAssertEqual(asked, 1, "the last window closed and the app stayed")
  }

  /// The quit asked by the window of the test host itself never ends the host.
  func testTheHostNeverQuits() {
    XCTAssertTrue(AppEnvironment.isTestHost)
    let main = window(Color.clear)
    AppWindows.mark(main, as: .main)
    // The app's own `terminate`: in the test host it does nothing, or this test would not end.
    main.close()
    XCTAssertTrue(NSApp.isRunning)
  }
}

/// Closing the main window quits through the same path as ⌘Q: the pipeline stops, the copy of the
/// last change is written, the database closes — and only then is AppKit answered.
@MainActor
final class WindowCloseQuitTests: XCTestCase {
  private func scratchData() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-close-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    setenv("OHMYMONEY_DATA_DIR", directory.path, 1)
    return directory
  }

  private func dropScratchData(_ directory: URL) {
    XCTAssertFalse(AppLaunch.hasStarted, "the folder is about to go under a running start")
    unsetenv("OHMYMONEY_DATA_DIR")
    try? FileManager.default.removeItem(at: directory)
  }

  private static let emptySources: AppLaunch.Sources = { _, _, calendar in
    ComputeSources(
      loadData: { mark, today, _ in
        DataSnapshot.build(
          dataset: Dataset(entries: [], version: mark), calendar: calendar, today: today,
          context: SnapshotContext(), version: DataVersion(load: mark))
      },
      refineRates: { RefinementResult() })
  }

  override func setUp() async throws {
    AppWindows.forgetAll()
  }

  override func tearDown() async throws {
    AppWindows.forgetAll()
  }

  func testAChangeMadeJustBeforeTheMainWindowClosesIsInTheLastCopy() async throws {
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
    // The copy is armed; its debounce is seconds long, and the window closes well inside it.
    try await Task.sleep(for: .milliseconds(200))

    // The delegate the app has, with the stop of this test's environment, and AppKit's answer
    // caught: what `NSApp.terminate` reaches when the main window closes.
    let delegate = AppDelegate()
    var steps: [String] = []
    let answered = expectation(description: "AppKit is answered")
    delegate.hasStarted = { true }
    delegate.stop = {
      await AppLaunch.stop(environment, compute: compute, store: store)
      steps.append("stopped")
    }
    delegate.answer = {
      steps.append("answer \($0)")
      answered.fulfill()
    }
    let terminate = AppWindows.terminate
    var reply: NSApplication.TerminateReply?
    AppWindows.terminate = { reply = delegate.applicationShouldTerminate(NSApplication.shared) }
    defer { AppWindows.terminate = terminate }

    let main = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled, .closable],
      backing: .buffered, defer: false)
    main.isReleasedWhenClosed = false
    AppWindows.mark(main, as: .main)
    main.close()
    await fulfillment(of: [answered], timeout: 10)

    XCTAssertEqual(reply, .terminateLater, "the quit did not wait for the database")
    XCTAssertEqual(steps, ["stopped", "answer true"], "AppKit was answered before the stop")
    let copies = try FileManager.default
      .contentsOfDirectory(at: AppPaths.backupsDirectory, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "sqlite" }
      .sorted { $0.lastPathComponent > $1.lastPathComponent }
    let last = try XCTUnwrap(copies.first, "closing the window left no copy of the last change")
    let copy = try DatabaseStack(url: last, schema: BundleSchemaSource(bundle: .main))
    defer { try? copy.close() }
    XCTAssertNotNil(
      try TransactionRepository(writer: copy.writer).entry(id: entry.id),
      "the last copy does not have the change made before the window closed")
  }
}
