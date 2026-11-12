import AppCore
import AppDatabase
import AppKit
import SwiftUI
import XCTest

@testable import OhMyMoney

/// «Календарь» in the main window: ⌘4 is its item of the menu bar, and what it posts brings the
/// calendar on screen; the screen and the Overview tile are laid out with every dependency they
/// need — no stand-in, no `dependencies.missing` in the journal.
@MainActor
final class CalendarWindowTests: XCTestCase {
  private var environment: AppEnvironment!
  private var store: TransactionsStore!
  private var compute: ComputeStore!
  private var windows: [NSWindow] = []
  private var directory: URL!
  private var logs: URL!
  private var dataDirectoryBefore: String?
  private var entryStyleBefore: EntryStyle?
  private let food = CoreKit.Category(kind: .expense, name: "Food")

  override func setUp() async throws {
    dataDirectoryBefore = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-calendar-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    setenv("OHMYMONEY_DATA_DIR", directory.path, 1)
    logs = directory.appendingPathComponent("Logs", isDirectory: true)
    Logbook.shared.open(directory: logs, threshold: .debug)
    environment = AppEnvironment()
    await environment.start(preparing: {
      try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    })
    entryStyleBefore = environment.entryStyle
    store = TransactionsStore()
    store.attach(
      try XCTUnwrap(environment.transactions), references: environment.references,
      planning: environment.planning)
    compute = ComputeStore(calendar: .system, rebuildsInline: true)
  }

  override func tearDown() async throws {
    for window in windows {
      window.contentViewController = nil
      window.close()
    }
    windows = []
    Logbook.shared.close()
    if let entryStyleBefore { environment.entryStyle = entryStyleBefore }
    if let environment { await environment.close() }
    if let dataDirectoryBefore {
      setenv("OHMYMONEY_DATA_DIR", dataDirectoryBefore, 1)
    } else {
      unsetenv("OHMYMONEY_DATA_DIR")
    }
    if let directory { try? FileManager.default.removeItem(at: directory) }
  }

  private func waitFor(
    _ window: NSWindow, _ description: String, until ready: () -> Bool
  ) throws {
    let deadline = Date().addingTimeInterval(5)
    var previousFrames: [CGRect] = []
    var stablePasses = 0
    while Date() < deadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
      window.contentView?.layoutSubtreeIfNeeded()
      let frames = WindowAccessibility.elements(in: window).map {
        WindowAccessibility.frame(of: $0)
      }
      stablePasses = ready() && frames == previousFrames ? stablePasses + 1 : 0
      if stablePasses >= 3 { return }
      previousFrames = frames
    }
    XCTFail("Timed out waiting for \(description) and stable layout")
    throw NSError(domain: "CalendarWindowTests", code: 1)
  }

  private func frame(_ identifier: String, in window: NSWindow) -> CGRect? {
    guard let element = WindowAccessibility.element(identified: identifier, in: window) else {
      return nil
    }
    let rect = WindowAccessibility.frame(of: element)
    return rect.width > 0 && rect.height > 0 ? rect : nil
  }

  private func snapshot() throws -> DataSnapshot {
    let calendar = CalendarContext.system
    let entries = try (0..<20).map { daysAgo -> TransactionEntry in
      let day = calendar.adding(days: -daysAgo, to: environment.today)
      var draft = TransactionDraft(
        occurredAt: calendar.startOfDay(day).addingTimeInterval(12 * 3600),
        amount: AmountE4(whole: daysAgo == 0 ? 9_000 : 500), note: "Lunch")
      draft.normalizeSinglePart()
      draft.parts[0].categoryId = food.id
      return try draft.materialize()
    }
    let rent = ScheduledPayment(
      name: "Rent", amountE4: AmountE4(whole: 30_000),
      nextDate: calendar.adding(days: 3, to: environment.today))
    return DataSnapshot.build(
      dataset: Dataset(
        entries: entries, categories: [food], planning: PlanningBook(scheduled: [rent])),
      calendar: .system, today: environment.today, context: SnapshotContext(),
      version: DataVersion(load: 0))
  }

  private func mainWindow(selection: SidebarItem = .section(.overview)) throws -> NSWindow {
    let deps = AppDependencies(environment: environment, store: store, compute: compute)
    let root = AppScenes.root(deps, window: .main, launches: false) { deps in
      MainWindow(deps: deps, actions: OperationActions(), opensDetails: false, selection: selection)
    }
    .environment(\.windowWidth, 980)
    let controller = NSHostingController(rootView: root)
    let window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: 980, height: 720),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentViewController = controller
    window.orderFront(nil)
    windows.append(window)
    try waitFor(window, "section \(selection.journalToken)") {
      self.shown(selection.journalToken)
    }
    return window
  }

  private func shown(_ section: String) -> Bool {
    Logbook.shared.lines().contains {
      $0.contains(" section.shown ") && $0.hasSuffix(" window=main section=\(section)")
    }
  }

  private var missingDependencies: Bool {
    Logbook.shared.lines().contains { $0.contains("dependencies.missing") }
  }

  /// ⌘4 is one item of the menu bar, and what it posts brings «Календарь» on screen.
  func testCommandFourOpensTheCalendar() throws {
    func items(_ menu: NSMenu?) -> [NSMenuItem] {
      (menu?.items ?? []).flatMap { [$0] + items($0.submenu) }
    }
    let four = items(NSApp.mainMenu).filter {
      $0.keyEquivalent == "4"
        && $0.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask) == .command
    }
    XCTAssertEqual(four.count, 1, "⌘4: \(four.map(\.title))")
    XCTAssertTrue(["Календарь", "Calendar"].contains(four.first?.title ?? ""))

    compute.applyLight(try snapshot())
    let window = try mainWindow()
    XCTAssertTrue(shown("overview"))
    NotificationCenter.default.post(name: .selectSection, object: 4)
    try waitFor(window, "calendar section") { self.shown("calendar") }
    XCTAssertTrue(shown("calendar"), "⌘4 did not bring «Календарь»")
    XCTAssertFalse(missingDependencies)
  }

  /// The month and the week are laid out with their dependencies.
  func testTheScreenIsLaidOutWithItsDependencies() throws {
    compute.applyLight(try snapshot())
    let window = try mainWindow(selection: .section(.calendar))
    XCTAssertTrue(shown("calendar"))
    window.setContentSize(CGSize(width: 760, height: 600))
    try waitFor(window, "resized calendar title") {
      self.frame("calendar.screenTitle", in: window) != nil
    }
    XCTAssertFalse(missingDependencies)
  }

  /// SwiftUI may extend the scroll view's frame under the dock; its safe area keeps the
  /// document's final card clear. Compare the visible content with the actual input capsule.
  func testCalendarPageScrollsAsAWholeAboveTheEntryDock() throws {
    TestEnvironment.enableAccessibilityTree()
    environment.entryStyle = .line
    compute.applyLight(try snapshot())
    let window = try mainWindow(selection: .section(.calendar))
    for size in [CGSize(width: 980, height: 600), CGSize(width: 760, height: 520)] {
      window.setContentSize(size)
      let root = try XCTUnwrap(window.contentView)
      func scrolls(_ view: NSView) -> [NSScrollView] {
        ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrolls)
      }
      func pageScroll() -> NSScrollView? {
        scrolls(root).filter {
          $0.bounds.width > 400 && ($0.documentView?.bounds.height ?? 0) > $0.bounds.height
        }.max { $0.bounds.width < $1.bounds.width }
      }
      try waitFor(window, "calendar page, last card and input capsule") {
        pageScroll() != nil && self.frame("calendar.upcoming", in: window) != nil
          && self.frame("entry.line.capsule", in: window) != nil
      }
      let page = try XCTUnwrap(pageScroll())
      let document = try XCTUnwrap(page.documentView)
      let start = document.isFlipped ? document.bounds.minY : document.bounds.maxY
      document.scroll(CGPoint(x: 0, y: start))
      try waitFor(window, "calendar document reaches its start") {
        let visible = page.contentView.documentVisibleRect
        return document.isFlipped
          ? visible.minY <= document.bounds.minY + 1
          : visible.maxY >= document.bounds.maxY - 1
      }
      let before = page.contentView.bounds.origin.y
      let end = document.isFlipped ? document.bounds.maxY : document.bounds.minY
      document.scroll(CGPoint(x: 0, y: end))
      try waitFor(window, "calendar document reaches its end") {
        let visible = page.contentView.documentVisibleRect
        return document.isFlipped
          ? visible.maxY >= document.bounds.maxY - 1
          : visible.minY <= document.bounds.minY + 1
      }
      XCTAssertNotEqual(page.contentView.bounds.origin.y, before, "the page must actually scroll")
      let card = try XCTUnwrap(frame("calendar.upcoming", in: window))
      let capsule = try XCTUnwrap(frame("entry.line.capsule", in: window))
      // Accessibility frames use screen coordinates, with Y increasing upwards.
      XCTAssertGreaterThanOrEqual(card.minY, capsule.maxY + EntryBarMetrics.contentGap - 1)
      let viewport = window.convertToScreen(root.convert(page.bounds, to: nil))
      XCTAssertLessThanOrEqual(card.maxY, viewport.maxY + 1, "the entire last card is reachable")
    }
  }

  func testTripBudgetShowsSeventyFivePercentForTheScreenshotAmounts() throws {
    TestEnvironment.enableAccessibilityTree()
    let event = Event(
      name: "Synthetic trip", kind: .trip,
      startDate: environment.today, endDate: environment.today)
    var draft = TransactionDraft(
      occurredAt: environment.calendar.startOfDay(environment.today),
      amount: AmountE4(raw: 112_992_500))
    draft.normalizeSinglePart()
    draft.parts[0].eventId = event.id
    // The event's budget is read from the same snapshot as its expenses.
    var budgetedEvent = event
    budgetedEvent.budgetE4 = AmountE4(whole: 15_000)
    budgetedEvent.budgetCurrency = .rub
    compute.applyLight(
      DataSnapshot.build(
        dataset: Dataset(entries: [try draft.materialize()], events: [budgetedEvent]),
        calendar: .system, today: environment.today, context: SnapshotContext(),
        version: DataVersion(load: 1)))
    let deps = AppDependencies(environment: environment, store: store, compute: compute)
    let controller = NSHostingController(
      rootView: TripSummaryView(eventId: event.id).appDependencies(deps))
    let window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: 520, height: 600),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    windows.append(window)
    window.contentViewController = controller
    window.orderFront(nil)
    let expected = environment.money.percent(basisPoints: 7500, fractionDigits: 0)
    try waitFor(window, "trip budget percentage") {
      WindowAccessibility.elements(in: window).contains {
        WindowAccessibility.text(of: $0) == expected
      }
    }
    var values: [String] = []
    func walk(_ element: Any) {
      guard let object = element as? NSObject else { return }
      if object.responds(to: NSSelectorFromString("accessibilityValue")),
        let value = object.value(forKey: "accessibilityValue") as? String
      {
        values.append(value)
      }
      if object.responds(to: NSSelectorFromString("accessibilityChildren")) {
        for child in object.value(forKey: "accessibilityChildren") as? [Any] ?? [] { walk(child) }
      }
    }
    walk(try XCTUnwrap(window.contentView))
    XCTAssertTrue(values.contains(environment.money.percent(basisPoints: 7500, fractionDigits: 0)))
    XCTAssertEqual(GoalProgressBar.fraction(basisPoints: 7533), 0.7533, accuracy: 0.0001)
  }

  func testDollarConversionFitsOneLineBelowTheAmountInTheInspector() throws {
    TestEnvironment.enableAccessibilityTree()
    var draft = TransactionDraft(
      occurredAt: environment.calendar.startOfDay(environment.today),
      amount: AmountE4(whole: 120))
    draft.currency = .usd
    draft.normalizeSinglePart()
    let entry = try draft.materialize()
    compute.applyLight(
      DataSnapshot.build(
        dataset: Dataset(entries: [entry]), calendar: .system, today: environment.today,
        context: SnapshotContext(rubPerUnit: [.usd: 95]), version: DataVersion(load: 0)))
    let deps = AppDependencies(environment: environment, store: store, compute: compute)
    let editor = TransactionEditorModel(entry: entry, environment: environment)
    let controller = NSHostingController(
      rootView:
        TransactionEditor(editor: editor, style: .inspector, close: {}).appDependencies(deps))
    let window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: 340, height: 800),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    windows.append(window)
    window.contentViewController = controller
    window.orderFront(nil)
    for language in [AppLanguage.Choice.russian, .english] {
      environment.language.choice = language
      let expected = "≈ " + environment.money.exact(AmountE4(whole: 11_400))
      try waitFor(window, "complete conversion text and amount in \(language)") {
        guard let hint = WindowAccessibility.element(identified: "entry.approximate", in: window)
        else { return false }
        return WindowAccessibility.text(of: hint) == expected
          && self.frame("entry.approximate", in: window) != nil
          && self.frame("entry.totalAmount", in: window) != nil
      }
      let hint = try XCTUnwrap(frame("entry.approximate", in: window))
      let amount = try XCTUnwrap(frame("entry.totalAmount", in: window))
      // Measure the same complete text unconstrained, instead of guessing a minimum width.
      let reference = NSHostingView(
        rootView:
          Text(verbatim: expected).appFont(.caption.monospacedDigit()).fixedSize()
          .appDependencies(deps))
      let natural = reference.fittingSize
      XCTAssertGreaterThan(natural.width, 0)
      XCTAssertEqual(hint.height, natural.height, accuracy: 1, "conversion must occupy one line")
      XCTAssertGreaterThanOrEqual(hint.width, natural.width - 1, "full conversion must fit")
      XCTAssertLessThanOrEqual(hint.maxY, amount.minY, "conversion belongs below the amount")
      let root = try XCTUnwrap(window.contentView)
      let bounds = window.convertToScreen(root.convert(root.bounds, to: nil))
      XCTAssertGreaterThanOrEqual(hint.minX, bounds.minX)
      XCTAssertLessThanOrEqual(hint.maxX, bounds.maxX)
    }
  }

  func testWhatIfEmptyWindowOffersInputsBeforeAnyVerdict() throws {
    TestEnvironment.enableAccessibilityTree()
    compute.applyLight(try snapshot())
    let deps = AppDependencies(environment: environment, store: store, compute: compute)
    let controller = NSHostingController(rootView: WhatIfWindow(deps: deps).appDependencies(deps))
    let window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: 760, height: 600),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    windows.append(window)
    window.contentViewController = controller
    window.orderFront(nil)
    try waitFor(window, "empty scenario prompt and input fields") {
      self.frame("whatif.emptyScenario", in: window) != nil
        && WindowAccessibility.elements(in: window).filter {
          WindowAccessibility.attribute($0, "accessibilityRole") as? String == "AXTextField"
        }.count >= 3
    }
    let root = try XCTUnwrap(window.contentView)
    func inputs(_ view: NSView) -> [NSTextField] {
      ((view as? NSTextField).map { [$0] } ?? []) + view.subviews.flatMap(inputs)
    }
    let editable = inputs(root).filter(\.isEditable)
    XCTAssertGreaterThanOrEqual(editable.count, 3)
    for input in editable {
      XCTAssertTrue(input.isBezeled, "scenario inputs need a visible border")
    }
    var labels: [String] = []
    var fields: [CGRect] = []
    func walk(_ element: Any) {
      guard let object = element as? NSObject else { return }
      if object.responds(to: NSSelectorFromString("accessibilityValue")),
        let text = object.value(forKey: "accessibilityValue") as? String
      {
        labels.append(text)
      }
      if object.responds(to: NSSelectorFromString("accessibilityRole")),
        object.value(forKey: "accessibilityRole") as? String == "AXTextField",
        let frame = (object.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue
      {
        fields.append(frame)
      }
      if object.responds(to: NSSelectorFromString("accessibilityChildren")) {
        for child in object.value(forKey: "accessibilityChildren") as? [Any] ?? [] { walk(child) }
      }
    }
    walk(try XCTUnwrap(window.contentView))
    XCTAssertGreaterThanOrEqual(fields.count, 3)
    for field in fields { XCTAssertGreaterThan(field.width, 60) }
    XCTAssertTrue(labels.contains(environment.language("whatif.enterScenario", table: "WhatIf")))
    XCTAssertFalse(labels.contains(environment.language("whatif.enough", table: "WhatIf")))
  }

  /// The tile on Overview, added as the owner adds it in the settings.
  func testTheTileIsLaidOutOnOverview() throws {
    compute.applyLight(try snapshot())
    let before = environment.overviewTiles
    defer { environment.overviewTiles = before }
    environment.overviewTiles = [.spendingCalendar, .monthToDate]
    _ = try mainWindow()
    XCTAssertTrue(shown("overview"))
    XCTAssertFalse(missingDependencies)
  }
}
