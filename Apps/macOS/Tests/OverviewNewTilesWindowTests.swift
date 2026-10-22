import AppCore
import AppDatabase
import AppKit
import SwiftUI
import XCTest

@testable import OhMyMoney

/// Overview with every tile of 2.0 shown, a pair among them and the charts and lists across the
/// whole width, on the data of the sample: the window lays out at every width in both languages,
/// editing or not, and settles — the same sizes pass after pass, no loop — as the groups do
/// with the tiles of the first versions (`OverviewEditingTests`).
@MainActor
final class OverviewNewTilesWindowTests: XCTestCase {
  private var environment: AppEnvironment!
  private var store: TransactionsStore!
  private var compute: ComputeStore!
  private var directory: URL!
  private var windows: [NSWindow] = []
  private var missingReadersBefore: Set<String> = []
  private var dataDirectoryBefore: String?

  override func setUp() async throws {
    missingReadersBefore = AppDependencies.missingReaders
    AppDependencies.missingReaders = []
    dataDirectoryBefore = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-overview-new-\(UUID().uuidString)", isDirectory: true)
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
    let set = SampleDataGenerator(seed: 20_261_015).generate(
      months: 6, endingOn: today, calendar: .system, language: "en"
    ).withEveryFeature(seed: 20_261_015, calendar: .system, language: "en")
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

  private func window(width: CGFloat, screen: OverviewScreen) -> NSWindow {
    let deps = AppDependencies(environment: environment, store: store, compute: compute)
    let root = OverviewView(actions: OperationActions(), screen: screen).appDependencies(deps)
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

  private func spin(_ seconds: TimeInterval = 0.01) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
  }

  private static func allViews(of view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap(allViews)
  }

  private func sizes(_ window: NSWindow) -> [String] {
    let scrolls = (window.contentView.map(Self.allViews) ?? []).compactMap { $0 as? NSScrollView }
    return scrolls.map {
      let document = $0.documentView?.frame.size ?? .zero
      return String(format: "%.1f×%.1f", document.width, document.height)
    } + [String(format: "%.1f", window.frame.width)]
  }

  /// Every tile shown, a pair of compact tiles among them, at four widths in both languages,
  /// editing or not: the window keeps the width it was given and settles.
  func testEveryTileOfTheCatalogLaysOutWithoutALoop() throws {
    var layout = OverviewLayout.standard
    for tile in OverviewTile.allCases { layout = layout.showing(tile) ?? layout }
    layout = try XCTUnwrap(layout.pairing(.spendToday, with: .averageDaily))
    layout = try XCTUnwrap(layout.pairing(.backups, with: .integrity))
    layout = try XCTUnwrap(layout.pairing(.iOwe, with: .owedToMe))
    let before = environment.overviewLayout
    environment.overviewLayout = layout
    defer { environment.overviewLayout = before }
    let widest = NSScreen.screens.map(\.visibleFrame.width).max() ?? 0
    for choice in [AppLanguage.Choice.russian, .english] {
      environment.language.choice = choice
      for width in [CGFloat(720), 900, 1_100, 1_400] where width <= widest {
        for editing in [false, true] {
          let what = "\(choice.rawValue) \(Int(width)) \(editing ? "editing" : "shown")"
          let screen = OverviewScreen()
          if editing { screen.edit() }
          let window = window(width: width, screen: screen)
          let started = Date()
          var records: [[String]] = []
          while Date().timeIntervalSince(started) < 10 {
            window.updateConstraintsIfNeeded()
            window.layoutIfNeeded()
            window.displayIfNeeded()
            spin()
            records.append(sizes(window))
            if records.count >= 8, records.suffix(8).allSatisfy({ $0 == records.last }),
              !(window.contentView?.needsLayout ?? false)
            {
              break
            }
          }
          let tail = records.suffix(8)
          XCTAssertTrue(
            tail.count == 8 && tail.allSatisfy { $0 == tail.first },
            "never settled \(what): \(Set(tail.map { $0.joined(separator: " ") }))")
          XCTAssertEqual(window.frame.width, width, accuracy: 1, "the window grew \(what)")
          window.contentViewController = nil
          window.close()
        }
      }
    }
    XCTAssertEqual(AppDependencies.missingReaders, [])
  }
}
