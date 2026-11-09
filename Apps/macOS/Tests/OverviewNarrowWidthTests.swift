import AppCore
import AppDatabase
import AppKit
import SwiftUI
import XCTest

@testable import OhMyMoney

/// Overview in the room the window leaves it when the form of a new operation stands at its
/// right: the grid of tiles is never wider than what is visible — no column is cut off at the
/// left or slides under the form — at every font size, and also after the window was wide first.
@MainActor
final class OverviewNarrowWidthTests: XCTestCase {
  private var environment: AppEnvironment!
  private var store: TransactionsStore!
  private var compute: ComputeStore!
  private var directory: URL!
  private var windows: [NSWindow] = []
  private var missingReadersBefore: Set<String> = []
  private var dataDirectoryBefore: String?

  override func setUp() async throws {
    OverviewFiguresStore.shared.reset()
    missingReadersBefore = AppDependencies.missingReaders
    AppDependencies.missingReaders = []
    dataDirectoryBefore = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-overview-narrow-\(UUID().uuidString)", isDirectory: true)
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
    let today = environment.today
    let set = SampleDataGenerator(seed: 20_261_102).generate(
      months: 6, endingOn: today, calendar: .system, language: "ru"
    ).withEveryFeature(seed: 20_261_102, calendar: .system, language: "ru")
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
    if let environment { await environment.close() }
    if let dataDirectoryBefore {
      setenv("OHMYMONEY_DATA_DIR", dataDirectoryBefore, 1)
    } else {
      unsetenv("OHMYMONEY_DATA_DIR")
    }
    AppDependencies.missingReaders = missingReadersBefore
    if let directory { try? FileManager.default.removeItem(at: directory) }
  }

  /// The detail column with the form beside it: Overview takes what is left, the form a fixed
  /// width at the right, as the main window lays them out.
  private func window(width: CGFloat, size: AppFontSize) -> NSWindow {
    let deps = AppDependencies(environment: environment, store: store, compute: compute)
    let root = HStack(spacing: 0) {
      OverviewView(actions: OperationActions())
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      Divider()
      Color.clear.frame(width: MainWindow.entryFormWidth)
    }
    .environment(\.appFontSize, size)
    .appDependencies(deps)
    let window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: width, height: 760),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentViewController = NSHostingController(rootView: root)
    window.setContentSize(CGSize(width: width, height: 760))
    window.orderFront(nil)
    windows.append(window)
    return window
  }

  private func settle(_ window: NSWindow) {
    for _ in 0..<15 {
      window.updateConstraintsIfNeeded()
      window.layoutIfNeeded()
      window.displayIfNeeded()
      RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
  }

  private static func allViews(of view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap(allViews)
  }

  private func everyTile() -> OverviewLayout {
    var layout = OverviewLayout.standard
    for tile in OverviewTile.allCases { layout = layout.showing(tile) ?? layout }
    return layout
  }

  /// The count of columns follows the size of the text: a larger text needs wider tiles, so the
  /// steps grow with the body size and the room beside the form keeps one column.
  func testColumnsFollowTheSizeOfTheText() {
    XCTAssertEqual(OverviewCard.columns(forWidth: 1_150), 4)
    XCTAssertEqual(OverviewCard.columns(forWidth: 1_150, fontSize: .regular), 4)
    XCTAssertEqual(OverviewCard.columns(forWidth: 1_150, fontSize: .small), 4)
    XCTAssertEqual(OverviewCard.columns(forWidth: 1_150, fontSize: .large), 3)
    XCTAssertEqual(OverviewCard.columns(forWidth: 1_150, fontSize: .xlarge), 3)
    XCTAssertEqual(OverviewCard.columns(forWidth: 1_100, fontSize: .xlarge), 2)
    XCTAssertEqual(OverviewCard.columns(forWidth: 600, fontSize: .xlarge), 1)
    XCTAssertEqual(OverviewCard.columns(forWidth: 600, fontSize: .large), 1)
    XCTAssertEqual(OverviewCard.columns(forWidth: 600, fontSize: .regular), 2)
  }

  /// Every tile, every font size, beside the form; and wide first, then narrow (the form appears,
  /// the window shrinks): the window keeps the width it was given and the page settles.
  func testEveryTileLaysOutBesideTheFormAtEveryFontSize() throws {
    self.executionTimeAllowance = 240
    let before = environment.overviewLayout
    environment.overviewLayout = everyTile()
    defer { environment.overviewLayout = before }
    for size in AppFontSize.allCases {
      let window = window(width: 1_500, size: size)
      settle(window)
      for width in [CGFloat(1_000), 880] {
        window.setContentSize(CGSize(width: width, height: 760))
        settle(window)
        XCTAssertEqual(
          window.frame.width, width, accuracy: 8, "\(size.rawValue) \(Int(width)): the window grew")
      }
      window.contentViewController = nil
      window.close()
    }
    XCTAssertEqual(AppDependencies.missingReaders, [])
  }
}
