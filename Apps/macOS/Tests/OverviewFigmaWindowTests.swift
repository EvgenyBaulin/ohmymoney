import AppCore
import AppDatabase
import AppKit
import SwiftUI
import XCTest

@testable import OhMyMoney

/// Overview in the main window at the size of the design's master frame (1440 × 900), with the
/// tiles of the frame: the page is measured against the frame's numbers — the margin from the
/// sidebar, the main card across the page, the card of the sum and «Что сделать сейчас» side by
/// side, each two tiles wide — and a picture of the window is kept with the result, to lay beside
/// the frame.
@MainActor
final class OverviewFigmaWindowTests: XCTestCase {
  private var environment: AppEnvironment!
  private var store: TransactionsStore!
  private var compute: ComputeStore!
  private var directory: URL!
  private var suiteName: String!
  private var defaults: UserDefaults!
  private var windows: [NSWindow] = []
  private var dataDirectoryBefore: String?
  private var layoutBefore: OverviewLayout?
  private var languageBefore: AppLanguage.Choice?

  private struct NotFound: Error {}

  /// The tiles of the master frame, in its order.
  static let frameTiles: [OverviewTile] = [
    .monthToDate, .freeMoney, .canSave, .owedToMe, .iOwe, .upcoming, .limits, .monthRest,
  ]

  override func setUp() async throws {
    OverviewFiguresStore.shared.reset()
    dataDirectoryBefore = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-overview-figma-\(UUID().uuidString)", isDirectory: true)
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
    suiteName = "ohmymoney-overview-figma-\(UUID().uuidString)"
    defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    loadSnapshot()
    layoutBefore = environment.overviewLayout
    var layout = OverviewLayout.standard.showingOnly(Self.frameTiles)
    if let paired = layout.pairing(.iOwe, with: .owedToMe) { layout = paired }
    environment.overviewLayout = layout
    environment.entryStyle = .line
    languageBefore = environment.language.choice
    environment.language.choice = .russian
  }

  private func loadSnapshot() {
    let today = environment.today
    let set = SampleDataGenerator(seed: 20_261_110).generate(
      months: 6, endingOn: today, calendar: .system, language: "ru"
    ).withEveryFeature(seed: 20_261_110, calendar: .system, language: "ru")
    // Three operations of this week without a category: «Что сделать сейчас» has «Разобрать»,
    // so the row of the frame — the card of the sum beside it — is always there to measure.
    var waiting = 0
    let week = today.adding(days: -(DoNowSources.reviewDays - 1))
    let entries = set.entries.map { entry -> TransactionEntry in
      let day = CalendarContext.system.day(of: entry.transaction.occurredAt)
      guard waiting < 3, entry.transaction.deletedAt == nil, day >= week, day <= today,
        !entry.parts.isEmpty
      else { return entry }
      waiting += 1
      var entry = entry
      entry.parts = entry.parts.map { part in
        var part = part
        part.categoryId = nil
        return part
      }
      return entry
    }
    let dataset = Dataset(
      entries: entries, links: set.links, categories: set.categories, people: set.people,
      places: set.places, events: set.events, paymentMethods: set.paymentMethods,
      debts: set.debts, goals: set.goals, planning: set.planningBook,
      settings: AnalyticsSettings(cashbackCategoryId: set.cashbackCategoryId),
      transfers: set.transfers, accountGroups: set.accountGroups,
      accountSettings: AccountSettings(storedValues: set.settings), cards: set.cards,
      cashbackRules: set.cashbackRules, banks: set.banks, assets: set.assets,
      assetValuations: set.assetValuations,
      capitalSettings: CapitalSettings(storedValues: set.settings))
    compute.applyLight(
      DataSnapshot.build(
        dataset: dataset, calendar: .system, today: today,
        context: SnapshotContext(rubPerUnit: [.usd: 95, .eur: 103]),
        version: DataVersion(load: 0)))
  }

  override func tearDown() async throws {
    for window in windows {
      window.contentViewController = nil
      window.close()
    }
    windows = []
    if let layoutBefore { environment?.overviewLayout = layoutBefore }
    if let languageBefore { environment?.language.choice = languageBefore }
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
          deps: deps, actions: actions, opensDetails: false, selection: .section(.overview))
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

  /// The frame of the element with `identifier`, in the window's coordinates (y up).
  private func frame(of identifier: String, in window: NSWindow) throws -> CGRect {
    let deadline = Date().addingTimeInterval(5)
    repeat {
      if let root = window.contentView,
        let found = Self.element(in: root, where: { $0.accessibilityIdentifier?() == identifier }),
        let onScreen = found.accessibilityFrame?(), onScreen.width > 0
      {
        return window.convertFromScreen(onScreen)
      }
      settle(window, passes: 5)
    } while Date() < deadline
    XCTFail("\(identifier) was not found")
    throw NotFound()
  }

  /// The right edge of the sidebar: the only table in the window while Overview is shown.
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

  /// The master frame's numbers in a window of its size: the page 28 from the sidebar, the main
  /// card across it, the card of the sum and «Что сделать сейчас» on one row, each two tiles and
  /// a gap wide, 14 apart.
  func testOverviewAtTheSizeOfTheMasterFrameHasItsNumbers() throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    try TestEnvironment.requireScreen(width: 1_440, height: 900)
    let window = makeWindow(width: 1_440, height: 900)
    settle(window)
    try attachPicture(of: window, named: "Overview 1440 × 900 (Figma 5:35222)")

    let grid = try frame(of: "overview.grid", in: window)
    let sidebar = try sidebarEdge(in: window)
    XCTAssertEqual(
      grid.minX - sidebar, StyleMetrics.pageSide, accuracy: 1.5,
      "the page stands 28 from the sidebar (\(grid), sidebar \(sidebar))")

    let hero = try frame(of: "screen.hero", in: window)
    XCTAssertEqual(hero.width, grid.width, accuracy: 1, "the main card spans the page")

    let columns = OverviewCard.columns(forWidth: grid.width)
    let tile = OverviewCard.tileWidth(in: grid.width, columns: columns)
    let double = columns >= OverviewCard.maxColumns ? 2 * tile + StyleMetrics.columnGap : tile
    let parts = try frame(of: "overview.parts", in: window)
    XCTAssertEqual(parts.width, double, accuracy: 1.5, "the card of the sum: \(parts)")
    XCTAssertEqual(parts.minX, grid.minX, accuracy: 1, "the card of the sum begins its row")
    let doNow = try frame(of: "overview.doNow", in: window)
    XCTAssertEqual(doNow.width, double, accuracy: 1.5, "«Что сделать сейчас»: \(doNow)")
    XCTAssertEqual(columns, OverviewCard.maxColumns, "the frame's width holds four tiles")
    XCTAssertEqual(parts.maxY, doNow.maxY, accuracy: 1, "the two cards share a row")
    XCTAssertEqual(
      doNow.minX - parts.maxX, StyleMetrics.columnGap, accuracy: 1, "14 between the cards")
  }

  private static func allSubviews<V: NSView>(of view: NSView, into found: inout [V]) {
    if let match = view as? V { found.append(match) }
    for subview in view.subviews { allSubviews(of: subview, into: &found) }
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
