import AppCore
import AppDatabase
import AppKit
import SwiftUI
import XCTest

@testable import OhMyMoney

/// Planning in the main window at the sizes of its frames in the design — the master at
/// 1440 × 900 and the narrower frames at 1280 and 1024 —, over a book with every feature: the page
/// is measured against the frames' numbers — 28 from the sidebar, 14 between the parts, the
/// columns of the blocks and their widths, the free sum in six columns or in four metrics,
/// «+ Добавить ▾» at the right edge of the header — and a picture of the window is kept with the
/// result, to lay beside the frame.
@MainActor
final class PlanningFigmaWindowTests: XCTestCase {
  private var environment: AppEnvironment!
  private var store: TransactionsStore!
  private var compute: ComputeStore!
  private var directory: URL!
  private var suiteName: String!
  private var defaults: UserDefaults!
  private var windows: [NSWindow] = []
  private var dataDirectoryBefore: String?
  private var languageBefore: AppLanguage.Choice?
  private var entryStyleBefore: EntryStyle?

  private struct NotFound: Error {}

  override func setUp() async throws {
    dataDirectoryBefore = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-planning-figma-\(UUID().uuidString)", isDirectory: true)
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
    suiteName = "ohmymoney-planning-figma-\(UUID().uuidString)"
    defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    compute.applyLight(Self.snapshot(today: environment.today))
    entryStyleBefore = environment.entryStyle
    environment.entryStyle = .line
    languageBefore = environment.language.choice
    environment.language.choice = .russian
  }

  /// Six months of a book with every feature — bills, subscriptions, an expected salary, limits,
  /// goals, events, a cushion —, so every card of the frame has its rows.
  static func snapshot(today: DateOnly) -> DataSnapshot {
    let set = SampleDataGenerator(seed: 20_261_110).generate(
      months: 6, endingOn: today, calendar: .system, language: "ru"
    ).withEveryFeature(seed: 20_261_110, calendar: .system, language: "ru")
    let dataset = Dataset(
      entries: set.entries, links: set.links, categories: set.categories, people: set.people,
      places: set.places, events: set.events, paymentMethods: set.paymentMethods,
      debts: set.debts, goals: set.goals, planning: set.planningBook,
      settings: AnalyticsSettings(cashbackCategoryId: set.cashbackCategoryId),
      transfers: set.transfers, accountGroups: set.accountGroups,
      accountSettings: AccountSettings(storedValues: set.settings), cards: set.cards,
      cashbackRules: set.cashbackRules, banks: set.banks, assets: set.assets,
      assetValuations: set.assetValuations,
      capitalSettings: CapitalSettings(storedValues: set.settings))
    return DataSnapshot.build(
      dataset: dataset, calendar: .system, today: today,
      context: SnapshotContext(rubPerUnit: [.usd: 95, .eur: 103]),
      version: DataVersion(load: 0))
  }

  override func tearDown() async throws {
    for window in windows {
      window.contentViewController = nil
      window.close()
    }
    windows = []
    if let languageBefore { environment?.language.choice = languageBefore }
    if let entryStyleBefore { environment?.entryStyle = entryStyleBefore }
    if let environment { await environment.close() }
    defaults?.removePersistentDomain(forName: suiteName)
    if let dataDirectoryBefore {
      setenv("OHMYMONEY_DATA_DIR", dataDirectoryBefore, 1)
    } else {
      unsetenv("OHMYMONEY_DATA_DIR")
    }
    if let directory { try? FileManager.default.removeItem(at: directory) }
  }

  private func makeWindow(width: CGFloat, height: CGFloat) -> NSWindow {
    let deps = AppDependencies(environment: environment, store: store, compute: compute)
    let actions = OperationActions()
    let root =
      AppScenes.root(deps, window: .main, launches: false) { deps in
        MainWindow(
          deps: deps, actions: actions, opensDetails: false, selection: .section(.planning))
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

  private func settle(_ window: NSWindow, passes: Int = 30) {
    for _ in 0..<passes {
      window.updateConstraintsIfNeeded()
      window.layoutIfNeeded()
      window.displayIfNeeded()
      RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
  }

  /// The frame of the element with `identifier`, in the window's coordinates (y up). A control
  /// may hand its identifier down to the parts of its label: the largest of them is the control.
  private func frame(of identifier: String, in window: NSWindow) throws -> CGRect {
    let deadline = Date().addingTimeInterval(5)
    repeat {
      if let root = window.contentView {
        var found: [AnyObject] = []
        Self.elements(in: root, into: &found) { $0.accessibilityIdentifier?() == identifier }
        let frames = found.compactMap { $0.accessibilityFrame?() }.filter { $0.width > 0 }
        if let largest = frames.max(by: { $0.width * $0.height < $1.width * $1.height }) {
          return window.convertFromScreen(largest)
        }
      }
      settle(window, passes: 5)
    } while Date() < deadline
    XCTFail("\(identifier) was not found")
    throw NotFound()
  }

  private func find(_ identifier: String, in window: NSWindow) -> AnyObject? {
    guard let root = window.contentView else { return nil }
    return Self.element(in: root, where: { $0.accessibilityIdentifier?() == identifier })
  }

  /// Many hosts at once lay a window out slowly: the page is measured only once two reads of its
  /// parts in a row agree.
  private func waitUntilStill(_ identifiers: [String], in window: NSWindow) throws {
    var last = try identifiers.map { try frame(of: $0, in: window) }
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline {
      settle(window, passes: 5)
      let now = try identifiers.map { try frame(of: $0, in: window) }
      if now == last { return }
      last = now
    }
    XCTFail("the page never stopped moving: \(identifiers)")
  }

  /// The right edge of the sidebar: the only table in the window while Planning is shown.
  private func sidebarEdge(in window: NSWindow) throws -> CGFloat {
    let root = try XCTUnwrap(window.contentView)
    var scrolls: [NSScrollView] = []
    Self.allSubviews(of: root, into: &scrolls)
    let sidebar = try XCTUnwrap(
      scrolls.first { scroll in
        var tables: [NSTableView] = []
        Self.allSubviews(of: scroll, into: &tables)
        return !tables.isEmpty
      }, "the sidebar was not found")
    return sidebar.convert(sidebar.bounds, to: nil).maxX
  }

  /// A picture of the window, kept with the result of the test.
  private func attachPicture(of window: NSWindow, named name: String) throws {
    let view = try XCTUnwrap(window.contentView)
    let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: rep)
    let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  /// The numbers every frame shares, and the columns and the free sum of this one.
  private func assertTheFrame(
    width: CGFloat, columns expected: Int, six: Bool, picture: String
  ) throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    try TestEnvironment.requireScreen(width: width, height: 900)
    let window = makeWindow(width: width, height: 900)
    settle(window)
    try waitUntilStill(["planning.free", "planning.card.limits"], in: window)
    try attachPicture(of: window, named: picture)

    let sidebar = try sidebarEdge(in: window)
    let free = try frame(of: "planning.free", in: window)
    XCTAssertEqual(
      free.minX - sidebar, StyleMetrics.pageSide, accuracy: 1.5,
      "the page stands 28 from the sidebar (\(free), sidebar \(sidebar))")
    let content = free.width
    XCTAssertEqual(
      content, width - sidebar - 2 * StyleMetrics.pageSide, accuracy: 2,
      "the card of the free sum spans the page")

    // The header: the title at the left, «+ Добавить ▾» at the right edge of the page, 34 tall.
    let add = try frame(of: "planning.addButton", in: window)
    XCTAssertEqual(add.maxX, free.maxX, accuracy: 1.5, "«Добавить» ends at the page's edge: \(add)")
    XCTAssertEqual(add.height, 34, accuracy: 3, "«Добавить» is 34 tall: \(add)")
    let title = try frame(of: "planning.title", in: window)
    XCTAssertEqual(title.minX, free.minX, accuracy: 1.5, "the title begins the page")

    // 14 between the tabs, the free sum, the next 14 days and the blocks (y is up).
    let tabs = try frame(of: "planning.tabs", in: window)
    XCTAssertEqual(tabs.minY - free.maxY, PlanningMetrics.stackGap, accuracy: 1.5, "tabs → free")
    let ribbon = try frame(of: "planning.ribbon", in: window)
    XCTAssertEqual(
      free.minY - ribbon.maxY, PlanningMetrics.stackGap, accuracy: 1.5, "free → ribbon")
    XCTAssertEqual(ribbon.width, content, accuracy: 1, "the next 14 days span the page")

    // The blocks: their columns and widths.
    let columns = PlanningPageLayout.blockColumns(forContent: content)
    XCTAssertEqual(columns, expected, "the columns of the frame at \(Int(width))")
    let card = PlanningPageLayout.cardWidth(forContent: content, columns: columns)
    let payments = try frame(of: "planning.card.payments", in: window)
    XCTAssertEqual(payments.width, card, accuracy: 1.5, "a card of the grid: \(payments)")
    XCTAssertEqual(payments.minX, free.minX, accuracy: 1, "the first column begins the page")
    XCTAssertEqual(
      ribbon.minY - payments.maxY, PlanningMetrics.stackGap, accuracy: 1.5, "ribbon → blocks")
    let limits = try frame(of: "planning.card.limits", in: window)
    if expected == 3 {
      XCTAssertEqual(
        limits.minX - payments.maxX, PlanningMetrics.columnGap, accuracy: 1.5,
        "the second column 14 after the first")
      XCTAssertEqual(limits.maxY, payments.maxY, accuracy: 1, "the columns begin on one line")
    } else {
      XCTAssertEqual(limits.minX, payments.minX, accuracy: 1, "one column")
      XCTAssertLessThan(limits.maxY, payments.minY, "limits under the payments")
    }

    // The free sum: six columns on the master, four metrics on the narrower frames.
    XCTAssertEqual(
      PlanningPageLayout.freeShowsColumns(forContent: content), six, "\(Int(width))")
    XCTAssertEqual(find("planning.free.columns", in: window) != nil, six, "six columns")
    XCTAssertEqual(find("planning.free.metrics", in: window) != nil, !six, "four metrics")
  }

  func testPlanningAt1440HasTheNumbersOfTheMaster() throws {
    try assertTheFrame(
      width: 1_440, columns: 3, six: true, picture: "Planning 1440 × 900 (Figma 5:35597)")
  }

  func testPlanningAt1280HasTheNumbersOfItsFrame() throws {
    try assertTheFrame(
      width: 1_280, columns: 3, six: false, picture: "Planning 1280 × 900 (Figma 483:123233)")
  }

  func testPlanningAt1024HasTheNumbersOfItsFrame() throws {
    try assertTheFrame(
      width: 1_024, columns: 1, six: false, picture: "Planning 1024 × 900 (Figma 483:123597)")
  }

  /// The card's figures are the free sum Overview shows: the same figure, «на 30 дней», the
  /// guide of the day to the ruble, and the cushion said when it is kept out.
  func testTheFreeSumIsTheOneOfOverview() throws {
    let snapshot = try XCTUnwrap(compute.snapshot)
    let figures = try XCTUnwrap(
      PlanningView.freeFigures(snapshot, picked: nil, environment), "the book is counted")
    let (free, horizon) = OverviewHeadline.configured(snapshot)
    XCTAssertEqual(horizon, .thirtyDays)
    let grey = try XCTUnwrap(free.grey)
    XCTAssertEqual(figures.main.figure, environment.money.rounded(grey))
    XCTAssertEqual(figures.title, "Сейчас свободно")
    XCTAssertTrue(figures.main.words.hasPrefix("на 30 дней"), figures.main.words)
    XCTAssertEqual(
      figures.columns.first?.figure, "\(environment.money.rubles(free.dailyRubles)) в день")
    XCTAssertEqual(figures.columns.first?.words, "без будущих доходов")
    XCTAssertEqual(figures.metrics.first?.figure, environment.money.rounded(grey))
    XCTAssertEqual(figures.metrics.first?.words, "можно за 30 дней")
    XCTAssertEqual(figures.hint, "Подсказка — не финансовая консультация.")
    if free.cushion.isZero {
      XCTAssertFalse(figures.main.words.contains("резерв"))
    } else {
      XCTAssertTrue(
        figures.main.words.contains("резерв \(environment.money.rounded(free.cushion)) исключён"),
        figures.main.words)
      XCTAssertTrue(figures.metrics.contains { $0.id == "reserve" })
    }
    // A day picked in the block of the free sum: the card counts to it.
    let picked = snapshot.today.adding(days: 10)
    let toTheDay = try XCTUnwrap(PlanningView.freeFigures(snapshot, picked: picked, environment))
    XCTAssertTrue(toTheDay.main.words.hasPrefix("до "), toTheDay.main.words)
  }

  private static func allSubviews<V: NSView>(of view: NSView, into found: inout [V]) {
    if let match = view as? V { found.append(match) }
    for subview in view.subviews { allSubviews(of: subview, into: &found) }
  }

  private static func elements(
    in node: AnyObject, depth: Int = 0, into found: inout [AnyObject],
    where matches: (AnyObject) -> Bool
  ) {
    if matches(node) { found.append(node) }
    guard depth < 40 else { return }
    for child in node.accessibilityChildren?() ?? [] {
      elements(in: child as AnyObject, depth: depth + 1, into: &found, where: matches)
    }
  }

  private static func element(
    in node: AnyObject, depth: Int = 0, where matches: (AnyObject) -> Bool
  ) -> AnyObject? {
    if matches(node) { return node }
    guard depth < 40 else { return nil }
    for child in node.accessibilityChildren?() ?? [] {
      if let found = element(in: child as AnyObject, depth: depth + 1, where: matches) {
        return found
      }
    }
    return nil
  }
}
