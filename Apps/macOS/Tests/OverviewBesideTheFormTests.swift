import AppCore
import AppDatabase
import AppKit
import SwiftUI
import XCTest

@testable import OhMyMoney

/// Overview in the main window with the form of a new operation at the right: the grid of tiles
/// stays between the sidebar and the form — no column cut off at the left, none slid under the
/// form — whether the window opened at that width or was wide first and narrowed.
///
/// The page once counted its columns from a width it measured of itself: three columns of tiles
/// that asked for more than the room kept the page wide, the wide page kept three columns, and
/// the grid hung out on both sides of the detail column.
@MainActor
final class OverviewBesideTheFormTests: XCTestCase {
  private var environment: AppEnvironment!
  private var store: TransactionsStore!
  private var compute: ComputeStore!
  private var directory: URL!
  private var suiteName: String!
  private var defaults: UserDefaults!
  private var windows: [NSWindow] = []
  private var missingReadersBefore: Set<String> = []
  private var dataDirectoryBefore: String?
  private var layoutBefore: OverviewLayout?
  private var languageBefore: AppLanguage.Choice?

  private struct GridNotFound: Error {}

  override func setUp() async throws {
    OverviewFiguresStore.shared.reset()
    missingReadersBefore = AppDependencies.missingReaders
    AppDependencies.missingReaders = []
    dataDirectoryBefore = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-overview-form-\(UUID().uuidString)", isDirectory: true)
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
    suiteName = "ohmymoney-overview-form-\(UUID().uuidString)"
    defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    loadSnapshot(longNames: false)
    layoutBefore = environment.overviewLayout
    var layout = OverviewLayout.standard
    for tile in OverviewTile.allCases { layout = layout.showing(tile) ?? layout }
    // The owner's layout has pairs of compact tiles; the suggested pairs stand for them.
    for pair in OverviewCatalog.suggestedPairs {
      if let (a, b) = pair.tiles, let paired = layout.pairing(a, with: b) { layout = paired }
    }
    environment.overviewLayout = layout
    environment.entryStyle = .form
    languageBefore = environment.language.choice
    environment.language.choice = .russian
  }

  private func loadSnapshot(longNames: Bool) {
    let today = environment.today
    var set = SampleDataGenerator(seed: 20_261_102).generate(
      months: 6, endingOn: today, calendar: .system, language: "ru"
    ).withEveryFeature(seed: 20_261_102, calendar: .system, language: "ru")
    if longNames {
      // Names that ask for room: a long payment name, a category with a very long word.
      set.categories = set.categories.map { category in
        var category = category
        category.name += " " + String(repeating: "Ж", count: 24)
        return category
      }
    }
    // Figures in the millions: an amount is never wrapped or scaled down, so a tile with them
    // asks for more width than the three columns of a wide window leave beside the form.
    var planningBook = set.planningBook
    if longNames {
      planningBook.scheduled = planningBook.scheduled.map { payment in
        var payment = payment
        payment.name += " — a new planned payment with a long name that asks for room"
        return payment
      }
    }
    let entries = set.entries.map { entry -> TransactionEntry in
      var entry = entry
      let factor: Int64 = 1_000
      entry.transaction.amountE4 = AmountE4(raw: entry.transaction.amountE4.raw * factor)
      entry.transaction.amountRubE4 = AmountE4(raw: entry.transaction.amountRubE4.raw * factor)
      entry.parts = entry.parts.map { part in
        var part = part
        part.amountE4 = AmountE4(raw: part.amountE4.raw * factor)
        part.amountRubE4 = AmountE4(raw: part.amountRubE4.raw * factor)
        return part
      }
      return entry
    }
    let dataset = Dataset(
      entries: entries, links: set.links, categories: set.categories, people: set.people,
      places: set.places, events: set.events, paymentMethods: set.paymentMethods,
      debts: set.debts, goals: set.goals, planning: planningBook,
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
    environment?.entryStyle = .line
    if let languageBefore { environment?.language.choice = languageBefore }
    if let environment { await environment.close() }
    defaults?.removePersistentDomain(forName: suiteName)
    if let dataDirectoryBefore {
      setenv("OHMYMONEY_DATA_DIR", dataDirectoryBefore, 1)
    } else {
      unsetenv("OHMYMONEY_DATA_DIR")
    }
    AppDependencies.missingReaders = missingReadersBefore
    if let directory { try? FileManager.default.removeItem(at: directory) }
  }

  private func makeWindow(width: CGFloat, height: CGFloat = 760) -> NSWindow {
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

  /// The grid of tiles, in the window's coordinates, found through accessibility by its
  /// identifier: SwiftUI draws the page into its hosting layer, with no view of its own.
  private func gridFrame(in window: NSWindow) throws -> CGRect {
    let deadline = Date().addingTimeInterval(5)
    repeat {
      if let root = window.contentView,
        let grid = Self.element(
          in: root,
          where: {
            $0.accessibilityIdentifier?() == "overview.grid"
          }),
        let onScreen = grid.accessibilityFrame?(), onScreen.width > 0
      {
        return window.convertFromScreen(onScreen)
      }
      settle(window, passes: 5)
    } while Date() < deadline
    XCTFail("the grid of Overview was not found")
    throw GridNotFound()
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

  private func assertGridFits(_ window: NSWindow, _ what: String) throws {
    let grid = try gridFrame(in: window)
    let content = try XCTUnwrap(window.contentView).bounds.width
    let formEdge = content - MainWindow.entryFormWidth - 1
    let sidebar = try sidebarEdge(in: window)
    XCTAssertLessThanOrEqual(
      grid.maxX, formEdge + 0.5, "\(what): the grid slides under the form (\(grid))")
    XCTAssertGreaterThanOrEqual(
      grid.minX, sidebar - 0.5, "\(what): the grid is cut off at the left (\(grid))")
  }

  func testTheGridStaysBetweenTheSidebarAndTheFormAt1200() throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    try TestEnvironment.requireScreen(width: 1_200)
    let window = makeWindow(width: 1_200)
    settle(window)
    try assertGridFits(window, "1200")
    XCTAssertEqual(window.frame.width, 1_200, accuracy: 8, "the window grew")
    XCTAssertEqual(AppDependencies.missingReaders, [])
  }

  func testTheGridStaysBetweenTheSidebarAndTheFormAt980() throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    let window = makeWindow(width: 980)
    settle(window)
    try assertGridFits(window, "980")
    XCTAssertEqual(window.frame.width, 980, accuracy: 8, "the window grew")
  }

  /// The form appears in a window already open on Overview with the line, three columns wide
  /// at 1200: the count follows the room the form leaves, at once.
  func testTheGridMakesRoomWhenTheFormAppears() throws {
    self.executionTimeAllowance = 240
    try TestEnvironment.requireSwiftUIAccessibility()
    try TestEnvironment.requireScreen(width: 1_200)
    let sizeBefore = environment.theme.fontSize
    defer { environment.theme.fontSize = sizeBefore }
    for size in AppFontSize.allCases {
      environment.theme.fontSize = size
      for width in [CGFloat(1_200), 980] {
        environment.entryStyle = .line
        let window = makeWindow(width: width)
        settle(window)
        _ = try gridFrame(in: window)
        environment.entryStyle = .form
        settle(window)
        try assertGridFits(window, "\(size.rawValue): the form appeared at \(Int(width))")
        window.contentViewController = nil
        window.close()
      }
    }
  }

  /// A new planned payment with a long name and categories with long words: the grid still
  /// stays between the sidebar and the form.
  func testTheGridFitsWithLongNamesBesideTheForm() throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    try TestEnvironment.requireScreen(width: 1_200)
    loadSnapshot(longNames: true)
    for width in [CGFloat(1_200), 980] {
      let window = makeWindow(width: width)
      settle(window)
      try assertGridFits(window, "long names at \(Int(width))")
      window.contentViewController = nil
      window.close()
    }
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
