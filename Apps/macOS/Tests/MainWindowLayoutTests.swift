import AppCore
import AppDatabase
import AppKit
import SwiftUI
import XCTest

@testable import OhMyMoney

/// Touch ID that always says it is the owner.
private struct PassingAuthenticator: LockAuthenticator {
  func authenticate(reason: String) async -> LockAuthentication { .passed }
}

/// The main window keeps the same promise the window of Transactions was made to keep on
/// 19.09: nothing measured off the screen comes back into the layout, and the
/// window settles.
///
/// The entry bar is the reason this file exists. It floats over the list, and the list has to
/// keep its last rows clear of it — but the room it needs must come from the safe area, not
/// from a height the bar measures and hands back. The second promise is the one that is easy
/// to break while keeping the first: the ↓ panel and the caption come and go while somebody
/// is typing, and the list must not jump every time they do. Only the capsule, the chips and
/// the selection bar count.
///
/// Some of these tests take the app's activity away and give it back, as
/// `TransactionsLayoutTests` does; the focus blinks for a moment while they run.
@MainActor
final class MainWindowLayoutTests: XCTestCase {
  private var environment: AppEnvironment!
  private var store: TransactionsStore!
  private var compute: ComputeStore!
  private var actions: OperationActions!
  private var directory: URL!
  private var suiteName: String!
  private var defaults: UserDefaults!
  private var windows: [NSWindow] = []
  private var missingReadersBefore: Set<String> = []
  private var dataDirectoryBefore: String?

  private var everything: [TransactionEntry]!
  private var first: TransactionEntry!
  private let food = CoreKit.Category(kind: .expense, name: "Food")
  private let salary = CoreKit.Category(kind: .income, name: "Salary")

  override func setUp() async throws {
    missingReadersBefore = AppDependencies.missingReaders
    AppDependencies.missingReaders = []
    dataDirectoryBefore = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-main-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    setenv("OHMYMONEY_DATA_DIR", directory.path, 1)
    environment = AppEnvironment()
    await environment.start(preparing: {
      try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    })
    store = TransactionsStore()
    store.attach(
      try XCTUnwrap(environment.transactions), references: environment.references,
      planning: environment.planning)
    compute = ComputeStore(calendar: .system, rebuildsInline: true)
    compute.onSnapshot = { [store] snapshot in store?.show(snapshot.ledger) }
    suiteName = "ohmymoney-main-\(UUID().uuidString)"
    defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    seed()
  }

  override func tearDown() async throws {
    for window in windows {
      window.contentViewController = nil
      window.close()
    }
    windows = []
    defaults?.removePersistentDomain(forName: suiteName)
    if let dataDirectoryBefore {
      setenv("OHMYMONEY_DATA_DIR", dataDirectoryBefore, 1)
    } else {
      unsetenv("OHMYMONEY_DATA_DIR")
    }
    AppDependencies.missingReaders = missingReadersBefore
    if let directory { try? FileManager.default.removeItem(at: directory) }
  }

  // MARK: - The history

  private func seed() {
    first = entry(.expense, 1_250, daysAgo: 0, hour: 12, note: "Coffee and a bun")
    let rest = (1..<40).map { day in
      entry(.expense, Int64(200 + day * 7), daysAgo: day % 27, hour: 8, note: "Row \(day)")
    }
    everything = [first] + rest
    show(everything, version: 0)
  }

  private func show(_ entries: [TransactionEntry], version: Int) {
    compute.applyLight(
      DataSnapshot.build(
        dataset: Dataset(entries: entries, categories: [food, salary]), calendar: .system,
        today: environment.today, context: SnapshotContext(),
        version: DataVersion(load: version)))
  }

  private func entry(
    _ kind: TransactionKind, _ amount: Int64, daysAgo: Int, hour: Int, note: String
  ) -> TransactionEntry {
    let id = UUID()
    let day = CalendarContext.system.day(
      of: Date().addingTimeInterval(TimeInterval(-86_400 * daysAgo)))
    let when = CalendarContext.system.startOfDay(day).addingTimeInterval(TimeInterval(hour * 3_600))
    let part = TransactionPart(
      transactionId: id, categoryId: kind == .income ? salary.id : food.id,
      quality: kind.hasQuality ? .neutral : nil,
      qualitySource: kind.hasQuality ? .category : nil, amountE4: AmountE4(whole: amount))
    return TransactionEntry(
      transaction: Transaction(
        id: id, kind: kind, occurredAt: when, amountE4: AmountE4(whole: amount), note: note,
        createdAt: when, updatedAt: when),
      parts: [part])
  }

  // MARK: - The window

  private func makeWindow(
    width: CGFloat = 1120, height: CGFloat = 760, opensDetails: Bool = false,
    selection: SidebarItem = .section(.operations)
  ) -> NSWindow {
    let deps = AppDependencies(environment: environment, store: store, compute: compute)
    let actions = OperationActions()
    self.actions = actions
    // `measuresWindowWidth()` is applied to the scene in `OhMyMoneyApp` and is not reachable from
    // here, so the width the entry bar takes its column from is handed over directly.
    let root =
      AppScenes.root(deps, window: .main, launches: false) { deps in
        // «Траты» lists the operations the selection bar and the room under it are about.
        MainWindow(
          deps: deps, actions: actions, opensDetails: opensDetails,
          selection: selection)
      }
      .environment(\.windowWidth, width)
      .defaultAppStorage(defaults)
    let controller = NSHostingController(rootView: root)
    controller.sceneBridgingOptions = [.toolbars]
    let window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: width, height: height),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentViewController = controller
    window.setContentSize(CGSize(width: width, height: height))
    window.toolbarStyle = .unified
    window.orderFront(nil)
    windows.append(window)
    return window
  }

  /// Runs the loop until the Overview list has rows, or gives up and says so.
  private func waitForList(_ window: NSWindow, timeout: TimeInterval = 5) throws {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
      RunLoop.main.run(until: Date().addingTimeInterval(0.05))
      window.layoutIfNeeded()
      if let table = Self.firstSubview(of: window.contentView!) as NSTableView?,
        table.numberOfRows > 0
      {
        return
      }
    } while Date() < deadline
    XCTFail("the list of «Траты» never filled")
    throw XCTSkip("no list, nothing to measure")
  }

  private static func firstSubview<V: NSView>(of view: NSView) -> V? {
    if let found = view as? V { return found }
    for subview in view.subviews {
      if let found: V = firstSubview(of: subview) { return found }
    }
    return nil
  }

  private static func allSubviews<V: NSView>(of view: NSView, into found: inout [V]) {
    if let match = view as? V { found.append(match) }
    for subview in view.subviews { allSubviews(of: subview, into: &found) }
  }

  private static func viewCount(of view: NSView) -> Int {
    1 + view.subviews.reduce(0) { $0 + viewCount(of: $1) }
  }

  // MARK: - What the layout is doing

  private struct LayoutRecord: Equatable, CustomStringConvertible {
    var items: [String]
    var views: Int

    var description: String { "views \(views); " + items.joined(separator: " | ") }
  }

  private func record(_ window: NSWindow) -> LayoutRecord {
    guard let frame = window.contentView?.superview ?? window.contentView else {
      return LayoutRecord(items: [], views: 0)
    }
    var splits: [NSSplitView] = []
    Self.allSubviews(of: frame, into: &splits)
    var items: [String] = []
    for (index, split) in splits.enumerated() {
      let widths = split.arrangedSubviews.map { String(format: "%.1f", $0.frame.width) }
      items.append("split\(index) [\(widths.joined(separator: ", "))]")
      guard let controller = split.delegate as? NSSplitViewController else { continue }
      for (itemIndex, item) in controller.splitViewItems.enumerated() {
        items.append(
          "split\(index).item\(itemIndex) "
            + "min \(String(format: "%.1f", item.minimumThickness)) "
            + "collapsed \(item.isCollapsed)")
      }
    }
    items.append(contentsOf: Self.scrollRooms(in: frame))
    return LayoutRecord(items: items, views: Self.viewCount(of: frame))
  }

  /// The room every scroll view of the window keeps at its bottom. This is where the clearance
  /// under the entry bar shows up in AppKit, whichever way SwiftUI puts it there.
  private static func scrollRooms(in frame: NSView) -> [String] {
    var scrolls: [NSScrollView] = []
    allSubviews(of: frame, into: &scrolls)
    return scrolls.enumerated().map { index, scroll in
      "scroll\(index) inset \(String(format: "%.1f", scroll.contentInsets.bottom)) "
        + "clip \(String(format: "%.1f", scroll.contentView.frame.height))"
    }
  }

  /// Drives the layout by hand and records what the window does on every pass.
  @discardableResult
  private func settle(_ window: NSWindow, passes: Int = 30, _ what: String) -> [LayoutRecord] {
    var records: [LayoutRecord] = []
    for _ in 0..<passes {
      window.updateConstraintsIfNeeded()
      window.layoutIfNeeded()
      window.displayIfNeeded()
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
      let record = record(window)
      print("main layout \(what) pass \(records.count): \(record)")
      records.append(record)
      if records.count >= 10, records.suffix(10).allSatisfy({ $0 == record }) { break }
    }
    return records
  }

  private func assertSettled(
    _ records: [LayoutRecord], _ window: NSWindow, _ what: String,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    let tail = records.suffix(10)
    let settled = tail.allSatisfy { $0 == tail.first }
    XCTAssertTrue(
      settled,
      "the window never settled \(what): "
        + Set(tail.map(\.description)).sorted().joined(separator: "  ≠  "),
      file: file, line: line)
    XCTAssertFalse(
      window.contentView?.needsLayout ?? false, "layout still dirty \(what)", file: file,
      line: line)
    XCTAssertFalse(
      window.contentView?.needsUpdateConstraints ?? false, "constraints still dirty \(what)",
      file: file, line: line)
  }

  /// The watchdog's side of a step. The queue that notices the overrun can only leave a
  /// complaint; failing the test is the main thread's to do. `XCTFail` is not usable off the
  /// main queue, and `abort()` — what stood here — took the whole process down with every
  /// other test in it and no attribution at all.
  private final class Watch: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var complaint: String?
    func finish() {
      lock.lock()
      finished = true
      lock.unlock()
    }
    /// Records the complaint unless the step has finished in the meantime. Under the one
    /// lock, so a step that finishes just as the watch fires cannot be failed for it.
    func complainIfRunning(_ text: String) {
      lock.lock()
      if !finished { complaint = text }
      lock.unlock()
    }
    var complaintIfAny: String? {
      lock.lock()
      defer { lock.unlock() }
      return complaint
    }
  }

  private func watched<T>(
    _ seconds: TimeInterval, _ what: String, file: StaticString = #filePath, line: UInt = #line,
    _ body: () -> T
  ) -> T {
    let watch = Watch()
    let since = Date()
    let messages = loopMessages
    // Only the flag is set here, never the report: reading the log takes long enough that
    // the step can finish first, and then the complaint would land after the main thread had
    // already looked for it. The report is read below, where there is time for it.
    DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
      watch.complainIfRunning("main layout watchdog: \(what) did not finish in \(seconds) s")
    }
    let value = body()
    watch.finish()
    // A step that ran long is a failure, not a killed process: `abort()` — what stood here —
    // took every other test in the run down with it and named none of them. The log report is
    // the valuable part, so it is gathered now and said out loud.
    if let complaint = watch.complaintIfAny {
      let report = LogProbe.report(of: messages, since: since)
      XCTFail("\(complaint); the log says \(report)", file: file, line: line)
    }
    return value
  }

  private var loopMessages: [String] {
    [
      LogProbe.Message.layoutLoop, LogProbe.Message.updateConstraints,
      LogProbe.Message.reentrantTable, LogProbe.Message.invalidGeometry,
      LogProbe.Message.stateDuringUpdate,
    ]
  }

  // MARK: - The window settles

  func testTheMainWindowSettlesWhenItOpens() throws {
    let window = makeWindow()
    try waitForList(window)
    let probe = LogProbe()
    let before = probe.counts(of: loopMessages)
    let records = settle(window, "on opening")

    assertSettled(records, window, "on opening")
    probe.assertQuiet(about: loopMessages, comparedWith: before, "on opening")
    XCTAssertEqual(AppDependencies.missingReaders, [])
  }

  /// The table of «Операции» is filled without being changed from inside its own delegate.
  /// AppKit says «reentrant operation in its NSTableView delegate» when it is, and promises an
  /// assert for it; it was said once on every opening, before the probes of the other tests
  /// started counting, so they caught it only when it came a little late. Counted here from
  /// before the window exists.
  func testOpeningTheOperationsTouchesNoTableFromItsOwnDelegate() throws {
    let probe = LogProbe()
    let before = probe.counts(of: loopMessages)
    let window = makeWindow()
    try waitForList(window)
    settle(window, "opening «Операции»")
    probe.assertQuiet(about: loopMessages, comparedWith: before, "opening «Операции»")
  }

  /// «Аналитика» and «Отчёты» are sections of this window: chosen by ⌘8 and ⌘9 (what the menu
  /// posts) they lay out without a loop, and the table of «Отчёты» is made empty and filled one
  /// turn later, never touched from its own delegate. Counted from before the window exists.
  func testOpeningAnalyticsAndReportsTouchesNoTableFromItsOwnDelegate() throws {
    let probe = LogProbe()
    let before = probe.counts(of: loopMessages)
    let window = makeWindow()
    try waitForList(window)
    for section in [MainWindow.Section.analytics, .reports, .operations, .reports] {
      NotificationCenter.default.post(name: .selectSection, object: section.shortcutIndex)
      for _ in 0..<20 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
      settle(window, "opening «\(section.rawValue)»")
    }
    probe.assertQuiet(about: loopMessages, comparedWith: before, "opening Analytics and Reports")
  }

  /// A window opened on «Отчёты» (`--open reports` of the recipes) draws its table from the
  /// first frame without touching it from its delegate.
  func testAWindowOpenedOnReportsTouchesNoTableFromItsOwnDelegate() throws {
    let probe = LogProbe()
    let before = probe.counts(of: loopMessages)
    let window = makeWindow(selection: .section(.reports))
    for _ in 0..<40 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    settle(window, "opening on «Отчёты»")
    probe.assertQuiet(about: loopMessages, comparedWith: before, "opening on «Отчёты»")
    XCTAssertEqual(AppDependencies.missingReaders, [])
  }

  func testOpeningTheOperationsBesideTheFormTouchesNoTableFromItsOwnDelegate() throws {
    environment.entryStyle = .form
    let probe = LogProbe()
    let before = probe.counts(of: loopMessages)
    let window = makeWindow(width: 820, height: 480)
    try waitForList(window)
    settle(window, "opening «Операции» beside the form")
    probe.assertQuiet(
      about: loopMessages, comparedWith: before, "opening «Операции» beside the form")
  }

  /// «Настроить столбцы…» makes the table again for the new columns: made again, it is filled
  /// the same way, from outside its delegate, and the selection is still there after it.
  func testOtherColumnsMakeTheTableAgainWithoutTouchingItFromItsDelegate() throws {
    let window = makeWindow()
    try waitForList(window)
    actions.selection = [first.transaction.id]
    settle(window, passes: 10, "before the columns change")

    let probe = LogProbe()
    let before = probe.counts(of: loopMessages)
    var layout = OperationColumnLayout.standard
    layout.setShown(true, .event)
    layout.setWidth(260, of: .description)
    defaults.set(layout.storage, forKey: OperationColumnLayout.storageKey)
    for _ in 0..<10 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    let records = settle(window, "with other columns")

    assertSettled(records, window, "with other columns")
    probe.assertQuiet(about: loopMessages, comparedWith: before, "with other columns")
    XCTAssertEqual(actions.selection, [first.transaction.id])
    var tables: [NSTableView] = []
    Self.allSubviews(of: window.contentView!, into: &tables)
    XCTAssertTrue(
      tables.contains { $0.tableColumns.count == layout.visible.count && $0.numberOfRows > 0 },
      "the table of the new columns never filled")
  }

  func testTheMainWindowSettlesWithTheSelectionBarShown() throws {
    let window = makeWindow()
    try waitForList(window)
    settle(window, passes: 10, "before the selection")

    let probe = LogProbe()
    let before = probe.counts(of: loopMessages)
    watched(30, "showing the selection bar") {
      actions.selection = [first.transaction.id]
      for _ in 0..<10 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }
    let records = settle(window, passes: 40, "with the selection bar shown")

    assertSettled(records, window, "with the selection bar shown")
    probe.assertQuiet(about: loopMessages, comparedWith: before, "with the selection bar shown")
  }

  /// The trigger that reproduced the loop in the window of Transactions.
  func testComingBackToTheMainWindowWithTheSelectionBarShownSettles() throws {
    let window = makeWindow()
    try waitForList(window)
    actions.selection = [first.transaction.id]
    settle(window, passes: 10, "with the bar shown")

    let probe = LogProbe()
    let before = probe.counts(of: loopMessages)
    let started = Date()
    watched(30, "activity") {
      NSApp.deactivate()
      for _ in 0..<10 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
      NSApp.activate()
      for _ in 0..<10 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }
    let seconds = Date().timeIntervalSince(started)
    let records = settle(window, passes: 40, "after coming back")

    assertSettled(records, window, "after coming back")
    XCTAssertLessThan(seconds, 30, "coming back to the main window took too long")
    probe.assertQuiet(about: loopMessages, comparedWith: before, "after coming back")
  }

  /// The narrowest the main window is asked to be: the sidebar, the list and the entry bar
  /// all want their room at once.
  func testTheMainWindowSettlesWhenItIsNarrow() throws {
    let window = makeWindow(width: 820, height: 480)
    try waitForList(window)

    let probe = LogProbe()
    let before = probe.counts(of: loopMessages)
    watched(30, "narrow window with a selection") {
      actions.selection = [first.transaction.id]
      for _ in 0..<10 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }
    let records = settle(window, passes: 40, "narrow, with the bar shown")

    assertSettled(records, window, "narrow, with the bar shown")
    probe.assertQuiet(about: loopMessages, comparedWith: before, "narrow, with the bar shown")
  }

  // MARK: - The form at the side

  /// The form of a new operation (`EntryStyle.form`) stands at the right of the detail column:
  /// a fixed width beside the list, nothing measured back, and the window settles as it does with
  /// the line.
  func testTheMainWindowSettlesWithTheFormAtTheSide() throws {
    environment.entryStyle = .form
    // Wide enough to hold the form beside the content (`EntryFormDock`).
    let window = makeWindow(width: 1_280)
    try waitForList(window)
    let probe = LogProbe()
    let before = probe.counts(of: loopMessages)
    let records = settle(window, "with the form at the side")

    assertSettled(records, window, "with the form at the side")
    probe.assertQuiet(
      about: loopMessages, comparedWith: before, "with the form at the side")
    XCTAssertEqual(AppDependencies.missingReaders, [])
  }

  /// The selection bar floats alone over the list, in a container of its own, as in the
  /// window of Transactions — there is no line to carry it.
  func testTheMainWindowSettlesWithTheFormAndTheSelectionBarShown() throws {
    environment.entryStyle = .form
    let window = makeWindow()
    try waitForList(window)
    settle(window, passes: 10, "before the selection")

    let probe = LogProbe()
    let before = probe.counts(of: loopMessages)
    watched(30, "showing the selection bar beside the form") {
      actions.selection = [first.transaction.id]
      for _ in 0..<10 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }
    let records = settle(window, passes: 40, "with the form and the selection bar shown")

    assertSettled(records, window, "with the form and the selection bar shown")
    probe.assertQuiet(
      about: loopMessages, comparedWith: before, "with the form and the selection bar shown")
    XCTAssertEqual(AppDependencies.missingReaders, [])
  }

  func testTheMainWindowSettlesNarrowWithTheFormAtTheSide() throws {
    environment.entryStyle = .form
    let window = makeWindow(width: 820, height: 480)
    try waitForList(window)

    let probe = LogProbe()
    let before = probe.counts(of: loopMessages)
    watched(30, "narrow window with the form and a selection") {
      actions.selection = [first.transaction.id]
      for _ in 0..<10 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }
    let records = settle(window, passes: 40, "narrow, with the form and the bar shown")

    assertSettled(records, window, "narrow, with the form and the bar shown")
    probe.assertQuiet(
      about: loopMessages, comparedWith: before, "narrow, with the form and the bar shown")
  }

  /// Decision 0583 hides the line on Planning (including its Goals sheet) and Reports.
  /// Every other main section keeps it, regardless of whether it lists operations.
  func testEntryLineVisibilityForEverySection() throws {
    environment.entryStyle = .line
    let prompt = environment.language("entry.placeholder", table: "Entry")
    for section in MainWindow.Section.allCases {
      let expected: Bool
      switch section {
      case .planning, .reports: expected = false
      case .overview, .operations, .calendar, .capital, .debts, .purchases, .analytics:
        expected = true
      }
      let window = makeWindow(selection: .section(section))
      settle(window, "entry line in \(section.rawValue)")
      var fields: [NSTextField] = []
      Self.allSubviews(of: try XCTUnwrap(window.contentView), into: &fields)
      XCTAssertEqual(
        fields.contains { $0.placeholderString == prompt }, expected, section.rawValue)
      window.contentViewController = nil
      window.orderOut(nil)
    }

    // Goals and What-if are separate presentations, not cases of MainWindow.Section.
    let deps = AppDependencies(environment: environment, store: store, compute: compute)
    let screens: [(String, AnyView)] = [
      ("goals", AnyView(GoalsScreen())),
      ("whatif", AnyView(WhatIfWindow(deps: deps))),
    ]
    for (name, screen) in screens {
      let root = AppScenes.root(deps, window: .main, launches: false) { _ in screen }
      let host = NSHostingView(rootView: root)
      host.setFrameSize(NSSize(width: 1_120, height: 760))
      host.layoutSubtreeIfNeeded()
      var fields: [NSTextField] = []
      Self.allSubviews(of: host, into: &fields)
      XCTAssertFalse(fields.contains { $0.placeholderString == prompt }, name)
    }
  }

  /// The choice in Settings moves the entry at once: the line is there with the line style, the
  /// form's fields with the form, and each leaves nothing of the other.
  func testTheChoiceInSettingsMovesTheEntryAtOnce() throws {
    // Wide enough to hold the form beside the content (`EntryFormDock`).
    let window = makeWindow(width: 1_280)
    try waitForList(window)
    let prompt = environment.language("entry.placeholder", table: "Entry")
    func textFields() -> [NSTextField] {
      var found: [NSTextField] = []
      Self.allSubviews(of: window.contentView!, into: &found)
      return found
    }
    XCTAssertNotNil(textFields().first { $0.placeholderString == prompt }, "the line")
    XCTAssertNil(textFields().first { $0.placeholderString == "0" }, "no form yet")

    environment.entryStyle = .form
    settle(window, passes: 20, "after choosing the form")
    XCTAssertNil(textFields().first { $0.placeholderString == prompt }, "the line is gone")
    // The form opens on its quick line and the kinds; the fields come with a kind.
    let quick = environment.language("entry.quick.prompt", table: "Entry")
    XCTAssertNotNil(textFields().first { $0.placeholderString == quick }, "the form's quick line")

    environment.entryStyle = .line
    settle(window, passes: 20, "after choosing the line again")
    XCTAssertNotNil(textFields().first { $0.placeholderString == prompt }, "the line is back")
    XCTAssertNil(textFields().first { $0.placeholderString == quick }, "the form is gone")
  }

  // MARK: - Where the room under the bar comes from

  /// The room the list keeps at its bottom for the floating bar. AppKit holds it as the
  /// bottom content inset of the list's scroll view, whichever way SwiftUI puts it there —
  /// measured at 74 pt with the capsule alone and 120 pt with the selection bar as well.
  ///
  /// The list of Overview is the scroll view around the table that has the rows; the sidebar
  /// has a table of three, so the count tells them apart.
  private func overviewRoom(_ window: NSWindow) throws -> CGFloat {
    let frame = try XCTUnwrap(window.contentView?.superview ?? window.contentView)
    var scrolls: [NSScrollView] = []
    Self.allSubviews(of: frame, into: &scrolls)
    for scroll in scrolls {
      var tables: [NSTableView] = []
      Self.allSubviews(of: scroll, into: &tables)
      if tables.contains(where: { $0.numberOfRows > 10 }) { return scroll.contentInsets.bottom }
    }
    XCTFail("the list of «Траты» was not found")
    return 0
  }

  /// Rows are selected under the bar, so while it is shown the last of them must be able to
  /// scroll out from under it: the room grows, and shrinks again when the selection goes.
  func testTheSelectionBarGivesTheListMoreRoomAndTakesItBack() throws {
    let window = makeWindow()
    try waitForList(window)
    settle(window, passes: 10, "before the selection")
    let alone = try overviewRoom(window)
    XCTAssertGreaterThan(alone, 0, "the list keeps no room for the capsule")

    actions.selection = [first.transaction.id]
    for _ in 0..<10 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    settle(window, passes: 20, "with the bar")
    let withBar = try overviewRoom(window)
    XCTAssertGreaterThan(
      withBar, alone, "the selection bar took no room: rows would sit under it")

    actions.selection = []
    for _ in 0..<10 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    settle(window, passes: 20, "after the bar went")
    XCTAssertEqual(
      try overviewRoom(window), alone, accuracy: 0.5,
      "the room did not come back when the selection went")
  }

  /// The promise that is easiest to lose: the ↓ panel and the caption come and go while
  /// somebody types, and the list must not jump every time they do. Only the capsule, the
  /// chips and the selection bar are part of the room — never the panel.
  ///
  /// The panel is asked for when the window is built rather than opened with ↓: a key press
  /// needs a key window and the test host is not always given one. What the panel does to the
  /// layout is the same however it came to be open.
  func testOpeningTheDetailsPanelDoesNotMoveTheList() throws {
    let closedWindow = makeWindow()
    try waitForList(closedWindow)
    settle(closedWindow, passes: 10, "before the panel")
    let closed = try overviewRoom(closedWindow)
    closedWindow.contentViewController = nil
    closedWindow.close()

    let window = makeWindow(opensDetails: true)
    try waitForList(window)
    settle(window, passes: 20, "with the panel open")
    let panel = try XCTUnwrap(Self.detailsPanel(in: window), "the ↓ panel did not open")

    XCTAssertEqual(
      try overviewRoom(window), closed, accuracy: 0.5,
      "opening ↓ moved the list: the panel must stay out of the room the bar takes")
    // Out of the room, but not out of the window: the panel stands above the capsule, and
    // standing there must not put it past the top of the window or under its bottom.
    let inWindow = panel.convert(panel.bounds, to: nil)
    let content = try XCTUnwrap(window.contentView)
    XCTAssertGreaterThan(inWindow.height, 0, "the panel was laid out with no height")
    XCTAssertGreaterThanOrEqual(
      inWindow.minY, 0, "the panel hangs below the bottom of the window")
    XCTAssertLessThanOrEqual(
      inWindow.maxY, content.bounds.height + 1, "the panel runs past the top of the window")
  }

  /// Decision 0583 keeps the entry line on Overview and hides it on Planning. Overview keeps
  /// room for the capsule and chips; Planning needs none and its end remains fully visible.
  /// The window is short on purpose: the section has to scroll for its end to mean anything.
  func testPlanningNeedsNoEntryRoomWhileOverviewKeepsItsRoom() throws {
    try TestEnvironment.requireScreen(width: 1_371)
    environment.entryStyle = .line
    // The chips are part of the room: with templates to show, it grows by their row.
    for text in ["Coffee", "Lunch", "Taxi"] {
      try XCTUnwrap(environment.references).save(Template(text: text))
    }
    let window = makeWindow(width: 1371, height: 560, selection: .section(.overview))
    Self.wait { Self.pageScroll(in: window) != nil }
    settle(window, passes: 10, "on Overview")
    let overview = try XCTUnwrap(Self.pageScroll(in: window), "Overview did not open")
    XCTAssertGreaterThan(overview.contentInsets.bottom, 0, "Overview keeps no room for the bar")
    let prompt = environment.language("entry.placeholder", table: "Entry")
    func hasEntryLine() throws -> Bool {
      var fields: [NSTextField] = []
      Self.allSubviews(of: try XCTUnwrap(window.contentView), into: &fields)
      return fields.contains { $0.placeholderString == prompt }
    }
    XCTAssertTrue(try hasEntryLine(), "Overview has no entry line")

    NotificationCenter.default.post(
      name: .selectSection, object: MainWindow.Section.planning.shortcutIndex)
    settle(window, passes: 20, "on Planning")
    let planning = try XCTUnwrap(Self.pageScroll(in: window), "Planning did not open")
    XCTAssertFalse(try hasEntryLine(), "Planning still shows the entry line")
    XCTAssertEqual(
      planning.contentInsets.bottom, 0, accuracy: 0.5,
      "Planning keeps room for an entry line it does not show")

    let document = try XCTUnwrap(planning.documentView)
    XCTAssertGreaterThan(
      document.bounds.height, planning.contentView.bounds.height,
      "the section fits without scrolling, so its end proves nothing")

    let last = CGRect(
      x: document.bounds.minX, y: document.isFlipped ? document.bounds.maxY - 1 : 0, width: 1,
      height: 1)
    document.scrollToVisible(last)
    settle(window, passes: 10, "at the end of Planning")

    let lastInWindow = document.convert(last, to: nil)
    let viewport = planning.contentView.convert(planning.contentView.bounds, to: nil)
    let content = try XCTUnwrap(window.contentView)
    let windowContent = content.convert(content.bounds, to: nil)
    XCTAssertTrue(
      viewport.insetBy(dx: -0.5, dy: -0.5).contains(lastInWindow),
      "the last line of Planning is clipped at the end of the scroll view")
    XCTAssertTrue(
      windowContent.insetBy(dx: -0.5, dy: -0.5).contains(lastInWindow),
      "the last line of Planning extends beyond the window's bottom edge")
    XCTAssertEqual(AppDependencies.missingReaders, [])
  }

  /// The page scroll view of Overview or Planning: tall and without a table in it. The
  /// sidebar is a table; the chips are a strip one row high.
  private static func pageScroll(in window: NSWindow) -> NSScrollView? {
    guard let frame = window.contentView?.superview ?? window.contentView else { return nil }
    var scrolls: [NSScrollView] = []
    allSubviews(of: frame, into: &scrolls)
    return scrolls.first { scroll in
      var tables: [NSTableView] = []
      allSubviews(of: scroll, into: &tables)
      return tables.isEmpty && scroll.frame.height > 300
    }
  }

  /// The panel is open when its close button is in the window.

  /// The panel itself, found through the close button that only it shows.
  /// The ↓ panel has no view of its own: SwiftUI draws its content into the window's one
  /// hosting layer, and not a single view in this window carries an accessibility identifier
  /// — the detector that looked for one could never have found anything, whatever opened the
  /// panel. What is real AppKit is the scroll view inside the panel, and its height is the
  /// 420 pt the panel caps it at.
  private static func detailsPanel(in window: NSWindow) -> NSView? {
    guard let root = window.contentView else { return nil }
    var views: [NSView] = []
    allSubviews(of: root, into: &views)
    return views.compactMap { $0 as? NSScrollView }.first { $0.frame.height > 300 }
  }

  // MARK: - The toolbar

  /// The toolbar holds no button of its own: the buttons of a screen stand in its header
  /// («Изменить», «Поездка», «Новая операция» on Overview), sections in the sidebar, and every
  /// action of the whole app — Add, the palette, the trip, Reconcile, Export, Recompute, Hide
  /// Amounts, Updates, Settings — is an item of the menu bar (`NavigationShellTests`,
  /// `ShellLayoutTests`).
  func testTheToolbarHoldsNoButtonOfItsOwn() throws {
    let window = makeWindow()
    try waitForList(window)
    settle(window, passes: 10, "with the toolbar")

    let labels = Set(Self.labels(of: window.toolbar?.items ?? []))
    for title in [
      environment.language("action.add"), QuestionsText.t("questions.menu.palette", environment),
      TravelText.t("travel.start.button", environment),
      environment.language("window.transactions"), environment.language("window.analytics"),
      environment.language("window.reports"), environment.language("action.recompute"),
      environment.language("action.reconcile"), environment.language("action.export"),
      UpdateService.title(environment), PrivacyCommands.amountsTitle(environment),
      environment.language("settings.title", table: "Settings"),
    ] {
      XCTAssertFalse(labels.contains(title), "«\(title)» belongs to the menu, not the toolbar")
    }
    XCTAssertEqual(AppDependencies.missingReaders, [])
  }

  /// The rows of the sidebar by the numbers of the design: the column 232 wide, a row 34 high
  /// (7 + a line of 14 + 7, and 3 between two rows), the list's rows 16 from the edges and the
  /// chosen one's plate, drawn 4 beyond its row, 12 from them.
  func testTheRowsOfTheSidebarHaveTheNumbersOfTheDesign() throws {
    let window = makeWindow()
    try waitForList(window)
    settle(window, passes: 10, "with the sidebar")
    var outlines: [NSOutlineView] = []
    Self.allSubviews(of: try XCTUnwrap(window.contentView), into: &outlines)
    let sidebar = try XCTUnwrap(
      outlines.first { $0.convert($0.bounds, to: nil).minX < 1 }, "no sidebar")
    XCTAssertEqual(sidebar.bounds.width, SidebarMetrics.width, accuracy: 1, "the column")
    // Row 0 is the header of the list of sections; then the sections in their order.
    let sections = MainWindow.Section.allCases
    let chosenRow = try 1 + XCTUnwrap(sections.firstIndex(of: .operations))
    // The pages of «Покупки» follow its row: the sections up to it stand one after another.
    // A row the mode of a beginner quiets carries a line more.
    for row in 1...(1 + (sections.firstIndex(of: .purchases) ?? 0))
    where BeginnerModeOnMac.section(of: sections[row - 1]) == nil {
      XCTAssertEqual(sidebar.rect(ofRow: row).height, 34, accuracy: 0.5, "row \(row)")
    }
    let cell = try XCTUnwrap(sidebar.view(atColumn: 0, row: chosenRow, makeIfNecessary: false))
    let cellFrame = cell.convert(cell.bounds, to: sidebar)
    XCTAssertEqual(cellFrame.minX, SidebarMetrics.listRowInset, accuracy: 0.5, "the list's inset")
    XCTAssertEqual(
      sidebar.bounds.width - cellFrame.maxX, SidebarMetrics.listRowInset, accuracy: 0.5)

    // The plate: the button of the chosen section as an assistive client reads it from the
    // cell — the plate is its background, so its frame is the plate's.
    var found: [(String, CGRect)] = []
    func walk(_ element: Any, depth: Int) {
      guard depth < 16, let object = element as? NSObject else { return }
      if let id = WindowAccessibility.attribute(object, "accessibilityIdentifier") as? String,
        !id.isEmpty
      {
        found.append((id, WindowAccessibility.frame(of: object)))
      }
      for child in WindowAccessibility.attribute(object, "accessibilityChildren") as? [Any] ?? [] {
        walk(child, depth: depth + 1)
      }
    }
    walk(cell, depth: 0)
    let button = try XCTUnwrap(found.first { $0.0 == "sidebar.operations" }?.1, "no button")
    let column = window.convertToScreen(sidebar.convert(sidebar.bounds, to: nil))
    // The button is laid out in the list's row, 16 from the edges; its plate is drawn 4 beyond
    // it, 12 from them — nothing on the way clips it.
    XCTAssertEqual(
      button.minX - SidebarMetrics.listOutset - column.minX, 12, accuracy: 0.5,
      "the plate 12 from the left of the column")
    XCTAssertEqual(
      column.maxX - button.maxX - SidebarMetrics.listOutset, 12, accuracy: 0.5,
      "the plate 12 from the right")
    XCTAssertEqual(button.height, 31, accuracy: 1, "7 + a line of 14 + 7")
    let plate = button.insetBy(dx: -SidebarMetrics.listOutset, dy: 0)
    var view: NSView? = cell
    var clipping: [NSView] = cell.subviews.filter(\.clipsToBounds)
    while let current = view, current !== sidebar {
      if current.clipsToBounds || current.layer?.masksToBounds == true { clipping.append(current) }
      view = current.superview
    }
    for view in clipping {
      let bounds = window.convertToScreen(view.convert(view.bounds, to: nil))
      XCTAssertTrue(
        bounds.insetBy(dx: -0.5, dy: -0.5).contains(plate),
        "\(type(of: view)) \(bounds) cuts the plate \(plate) off")
    }
  }

  /// The labels of the toolbar's items, those of the items of a group included.
  private static func labels(of items: [NSToolbarItem]) -> [String] {
    items.flatMap { item -> [String] in
      let own = [item.label, item.paletteLabel, item.toolTip ?? ""].filter { !$0.isEmpty }
      guard let group = item as? NSToolbarItemGroup else { return own }
      return own + labels(of: group.subitems)
    }
  }

  // MARK: - The offer of a problem report

  /// «Если при следующем старте отметка осталась, … приложение предлагает собрать отчёт».
  /// The main window asks, once: «Позже» spends the offer and the window does not ask again.
  func testTheMainWindowOffersAProblemReportOnceAfterAnInterruptedSession() throws {
    environment.offersProblemReport = true
    let window = makeWindow()

    let alert = try XCTUnwrap(
      Self.waitForSheet(of: window), "the main window did not offer to gather a report")
    let later = try XCTUnwrap(
      Self.button(
        titled: environment.language("report.offer.later", table: "Settings"), in: alert),
      "the offer has no «Позже»")
    Self.press(later)
    Self.wait { window.attachedSheet == nil }

    XCTAssertNil(window.attachedSheet, "the offer did not go")
    XCTAssertFalse(environment.offersProblemReport, "«Позже» did not spend the offer")
    XCTAssertEqual(AppDependencies.missingReaders, [])
  }

  /// «Собрать отчёт…» of the offer opens the report itself, gathered, with the list of what
  /// goes into the file and the button that saves it — not the settings, where the section
  /// sits below the fold.
  func testCollectingTheOfferedReportShowsWhatGoesIntoTheFile() throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    environment.offersProblemReport = true
    let window = makeWindow()
    let alert = try XCTUnwrap(
      Self.waitForSheet(of: window), "the main window did not offer to gather a report")
    let collect = try XCTUnwrap(
      Self.button(
        titled: environment.language("report.offer.collect", table: "Settings"), in: alert))
    Self.press(collect)

    let save = environment.language("report.save", table: "Settings")
    Self.wait { window.attachedSheet.flatMap { Self.button(titled: save, in: $0) } != nil }
    let sheet = try XCTUnwrap(window.attachedSheet, "no report was shown")
    XCTAssertNotNil(Self.button(titled: save, in: sheet), "the report was not gathered")
    XCTAssertEqual(AppDependencies.missingReaders, [], "the report went without the dependencies")

    let close = try XCTUnwrap(
      Self.button(titled: environment.language("action.close"), in: sheet), "no way out")
    Self.press(close)
    Self.wait { window.attachedSheet == nil }
    XCTAssertNil(window.attachedSheet)
    XCTAssertFalse(environment.offersProblemReport, "the offer was not spent")
  }

  /// A lock that applies and opens at once, locked: the test host's own lock never locks.
  private func lockTheApp() async -> PrivacyLock {
    let lock = PrivacyLock(
      applies: true, defaults: nil, authenticator: PassingAuthenticator(),
      passwords: InMemoryLockPasswordStore())
    let enabled = await lock.enable(reason: "test")
    XCTAssertTrue(enabled)
    lock.lock(because: .launch)
    environment.lock = lock
    return lock
  }

  /// 1.8.0: the offer «Прошлый сеанс оборвался» stood over the cover of the locked app at
  /// launch, modal, and took the clicks the cover needed — the app could not be entered, and the
  /// next launch after a force quit offered it again. While locked, nothing is asked; once
  /// unlocked, the offer comes.
  func testTheOfferOfAReportWaitsForTheAppToBeUnlocked() async throws {
    let lock = await lockTheApp()
    environment.offersProblemReport = true
    let window = makeWindow()
    Self.wait(timeout: 1.5) { window.attachedSheet != nil }
    XCTAssertNil(window.attachedSheet, "the offer stands over the locked app")

    _ = await lock.unlock(reason: "test")
    XCTAssertNotNil(Self.waitForSheet(of: window), "the offer did not come after the unlock")
    XCTAssertTrue(environment.offersProblemReport)
  }

  /// The lock coming while the offer is up takes the offer down without spending it: it comes
  /// back after the unlock.
  func testTheLockTakesTheOfferDownAndKeepsIt() async throws {
    let lock = await lockTheApp()
    _ = await lock.unlock(reason: "test")
    environment.offersProblemReport = true
    let window = makeWindow()
    XCTAssertNotNil(Self.waitForSheet(of: window), "no offer")

    lock.lock(because: .idle)
    Self.wait { window.attachedSheet == nil }
    XCTAssertNil(window.attachedSheet, "the offer stays over the locked app")
    XCTAssertTrue(environment.offersProblemReport, "the lock spent the offer")

    _ = await lock.unlock(reason: "test")
    XCTAssertNotNil(Self.waitForSheet(of: window), "the offer did not come back")
    XCTAssertTrue(environment.offersProblemReport)
  }

  /// «Справка» → «Собрать отчёт о проблеме…» only opened the settings: on whatever tab they
  /// were left, with the report at the bottom of the General one, below the fold. It opens
  /// the report itself now, gathered, over the settings.
  func testTheHelpMenuOpensTheReportItselfOverTheSettings() throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    let deps = AppDependencies(environment: environment, store: store, compute: compute)
    let window = NSWindow(
      contentViewController: NSHostingController(
        rootView: AppScenes.root(deps, window: .settings, launches: false) {
          SettingsView(deps: $0)
        }))
    window.isReleasedWhenClosed = false
    var opened = 0

    HelpCommands.collectReport(environment) {
      opened += 1
      window.orderFront(nil)
    }
    windows.append(window)

    XCTAssertEqual(opened, 1, "the settings were not opened")
    let save = environment.language("report.save", table: "Settings")
    Self.wait { window.attachedSheet.flatMap { Self.button(titled: save, in: $0) } != nil }
    let sheet = try XCTUnwrap(window.attachedSheet, "the settings opened without the report")
    XCTAssertNotNil(Self.button(titled: save, in: sheet), "the report was not gathered")
    XCTAssertLessThanOrEqual(
      sheet.frame.height, window.frame.height, "the report hangs out of the settings")
    XCTAssertEqual(AppDependencies.missingReaders, [], "the report went without the dependencies")

    let close = try XCTUnwrap(
      Self.button(titled: environment.language("action.close"), in: sheet), "no way out")
    Self.press(close)
    Self.wait { window.attachedSheet == nil }
    XCTAssertNil(window.attachedSheet)
    XCTAssertFalse(environment.showsProblemReport, "the request outlived the report")
  }

  // MARK: - A currency the bank does not publish

  /// «…сообщить, если какой-то валюты нет»: the main window names the enabled currency the
  /// daily table of the bank lacked at the first launch, once — after the offer of a report
  /// is answered, never over it.
  func testTheMainWindowNamesACurrencyTheBankDoesNotPublishAfterTheOfferOfAReport() throws {
    environment.offersProblemReport = true
    environment.currenciesMissingAtBank = [CurrencyCode("GEL")]
    let window = makeWindow()

    let offer = try XCTUnwrap(Self.waitForSheet(of: window), "the window asked nothing")
    let later = try XCTUnwrap(
      Self.button(
        titled: environment.language("report.offer.later", table: "Settings"), in: offer),
      "the currencies were named over the offer of a report")
    Self.press(later)

    Self.wait {
      window.attachedSheet.map { Self.texts(in: $0).contains { $0.contains("GEL") } } == true
    }
    let notice = try XCTUnwrap(window.attachedSheet, "the missing currency was never named")
    XCTAssertTrue(
      Self.texts(in: notice).contains { $0.contains("GEL") }, "the notice does not name GEL")
    let ok = try XCTUnwrap(
      Self.button(titled: environment.language("action.ok"), in: notice), "no way out")
    Self.press(ok)
    Self.wait { window.attachedSheet == nil }

    XCTAssertNil(window.attachedSheet, "the notice did not go")
    XCTAssertEqual(environment.currenciesMissingAtBank, [], "«OK» did not spend the notice")
  }

  /// What the text fields of a sheet say: an alert of SwiftUI is AppKit's `NSAlert`.
  private static func texts(in sheet: NSWindow) -> [String] {
    guard let root = sheet.contentView else { return [] }
    var fields: [NSTextField] = []
    allSubviews(of: root, into: &fields)
    return fields.map(\.stringValue)
  }

  private static func wait(timeout: TimeInterval = 5, until done: () -> Bool) {
    let deadline = Date().addingTimeInterval(timeout)
    while !done(), Date() < deadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
  }

  private static func waitForSheet(of window: NSWindow) -> NSWindow? {
    wait { window.attachedSheet != nil }
    return window.attachedSheet
  }

  /// A button of a sheet by its title, found the way VoiceOver finds it: the buttons of an
  /// alert are AppKit's, but a sheet of SwiftUI draws its own, and only accessibility sees
  /// them.
  private static func button(titled title: String, in sheet: NSWindow) -> AnyObject? {
    guard let root = sheet.contentView else { return nil }
    return accessibilityElement(in: root) { node in
      node.accessibilityRole?() == .button
        && (node.accessibilityLabel?() == title || node.accessibilityTitle?() == title)
    }
  }

  private static func accessibilityElement(
    in node: AnyObject, depth: Int = 0, where matches: (AnyObject) -> Bool
  ) -> AnyObject? {
    if matches(node) { return node }
    guard depth < 40 else { return nil }
    for child in node.accessibilityChildren?() ?? [] {
      if let found = accessibilityElement(in: child as AnyObject, depth: depth + 1, where: matches)
      {
        return found
      }
    }
    return nil
  }

  private static func press(_ button: AnyObject) {
    _ = button.accessibilityPerformPress?()
  }
}
