import AppCore
import AppDatabase
import AppKit
import SwiftUI
import XCTest

@testable import OhMyMoney

/// Overview edits its own layout («Изменить» … «Готово») and opens «Почему так» for a tile it is
/// clicked on — never while editing. The groups lay out at every width of the window in both
/// languages, editing or not, without the layout rocking.
@MainActor
final class OverviewEditingTests: XCTestCase {
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
      .appendingPathComponent("ohmymoney-overview-edit-\(UUID().uuidString)", isDirectory: true)
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
    compute.applyLight(
      DataSnapshot.build(
        dataset: Dataset(entries: [], categories: []), calendar: .system,
        today: environment.today, context: SnapshotContext(), version: DataVersion(load: 0)))
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

  // MARK: - The state of the screen

  /// A click opens «Почему так» outside editing; «Изменить» closes it and keeps it shut while
  /// editing; «Готово» opens the way again.
  func testAClickOpensWhySoOnlyOutsideEditing() {
    let screen = OverviewScreen()
    XCTAssertFalse(screen.isEditing)
    XCTAssertNil(screen.why)
    XCTAssertTrue(screen.open(.limits))
    XCTAssertEqual(screen.why, .limits)

    screen.edit()
    XCTAssertTrue(screen.isEditing)
    XCTAssertNil(screen.why, "editing closes the sheet")
    XCTAssertFalse(screen.open(.capital))
    XCTAssertNil(screen.why, "nothing opens while editing")

    screen.done()
    XCTAssertFalse(screen.isEditing)
    XCTAssertTrue(screen.open(.capital))
    XCTAssertEqual(screen.why, .capital)
  }

  /// Outside editing a group with no tile shown is left out and a collapsed group shows only its
  /// name; while editing every group is there, open, to drop a tile into.
  func testTheGroupsTheScreenShows() throws {
    var layout = OverviewLayout.standard.showingOnly([.monthToDate, .topCategories])
    XCTAssertEqual(OverviewScreen.groups(of: layout, editing: false), [.money, .analysis])
    XCTAssertEqual(OverviewScreen.groups(of: layout, editing: true), [.money, .plan, .analysis])
    layout = try XCTUnwrap(layout.movingGroup(.analysis, by: -1))
    XCTAssertEqual(OverviewScreen.groups(of: layout, editing: false), [.money, .analysis])

    XCTAssertFalse(OverviewScreen.showsTiles(of: .money, collapsed: [.money], editing: false))
    XCTAssertTrue(OverviewScreen.showsTiles(of: .plan, collapsed: [.money], editing: false))
    XCTAssertTrue(OverviewScreen.showsTiles(of: .money, collapsed: [.money], editing: true))
  }

  /// Editing as Overview does it: «−» hides a tile — not the last one shown —, «Добавить плитку»
  /// offers the hidden ones and shows one back at its place, a tile dropped onto a tile of another
  /// group goes there, a group dropped onto another takes its place, and VoiceOver steps skip the
  /// hidden tiles nobody sees.
  func testEditingOnOverviewChangesTheLayout() {
    environment.overviewLayout = .standard
    // Only the tiles that wait to be added are hidden at first: the two of the credits and the
    // self-employment, and the tiles of 2.0, which no layout of an earlier build names.
    XCTAssertEqual(hiddenBefore2(), [.installments, .selfEmployment])
    XCTAssertTrue(OverviewTilesActions.hide(environment, .canSave))
    XCTAssertTrue(OverviewTilesActions.hide(environment, .worthALook))
    XCTAssertEqual(hiddenBefore2(), [.canSave, .installments, .selfEmployment, .worthALook])
    XCTAssertEqual(OverviewTilesActions.moves(environment, .monthToDate, amongShown: true), [1])
    XCTAssertTrue(OverviewTilesActions.move(environment, .monthToDate, by: 1, amongShown: true))
    XCTAssertEqual(
      Array(environment.overviewLayout.shownTiles(in: .money).prefix(2)), [.owedToMe, .monthToDate])
    XCTAssertTrue(OverviewTilesActions.show(environment, .canSave))
    XCTAssertEqual(hiddenBefore2(), [.installments, .selfEmployment, .worthALook])

    XCTAssertTrue(OverviewTilesActions.drop(environment, .capital, onto: .limits))
    XCTAssertEqual(environment.overviewLayout.shownTiles(in: .plan).first, .capital)
    XCTAssertTrue(
      OverviewTilesActions.drop(
        environment, OverviewTilesActions.payload(of: OverviewTileGroup.plan), onto: .money))
    XCTAssertEqual(environment.overviewLayout.groups, [.plan, .money, .analysis])

    environment.overviewTiles = [.event]
    XCTAssertFalse(OverviewTilesActions.hide(environment, .event), "the last tile shown stays")
    XCTAssertEqual(environment.overviewTiles, [.event])
  }

  /// The hidden tiles of the first 24, which every build knows.
  private func hiddenBefore2() -> [OverviewTile] {
    environment.overviewLayout.hiddenInOrder.filter {
      (OverviewCatalog.item(of: $0)?.number ?? 99) <= 24
    }
  }

  // MARK: - The window

  private func window(
    width: CGFloat, height: CGFloat = 760, screen: OverviewScreen
  ) -> NSWindow {
    let deps = AppDependencies(environment: environment, store: store, compute: compute)
    let root = OverviewView(actions: OperationActions(), screen: screen).appDependencies(deps)
    let window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: width, height: height),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentViewController = NSHostingController(rootView: root)
    window.setContentSize(CGSize(width: width, height: height))
    window.orderFront(nil)
    windows.append(window)
    return window
  }

  private func spin(_ seconds: TimeInterval = 0.3) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
  }

  private func wait(_ seconds: TimeInterval = 5, until condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition(), Date() < deadline { spin(0.05) }
  }

  /// «Почему так» opens as a sheet of the window for the tile clicked, and closes; while editing
  /// nothing opens. The sheet has the app's dependencies.
  func testWhySoOpensAsASheetForTheTile() {
    let screen = OverviewScreen()
    let window = window(width: 1_000, screen: screen)
    spin()
    XCTAssertNil(window.attachedSheet)

    XCTAssertTrue(screen.open(.limits))
    wait { window.attachedSheet != nil }
    XCTAssertNotNil(window.attachedSheet, "«Почему так» did not open")
    screen.why = nil
    wait { window.attachedSheet == nil }
    XCTAssertNil(window.attachedSheet)

    screen.edit()
    XCTAssertFalse(screen.open(.limits))
    spin()
    XCTAssertNil(window.attachedSheet, "nothing opens while editing")
    XCTAssertEqual(AppDependencies.missingReaders, [])
  }

  private struct Record: Equatable {
    var sizes: [String]
  }

  private static func allViews(of view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap(allViews)
  }

  private func record(_ window: NSWindow) -> Record {
    let scrolls = (window.contentView.map(Self.allViews) ?? []).compactMap { $0 as? NSScrollView }
    return Record(
      sizes: scrolls.map {
        let document = $0.documentView?.frame.size ?? .zero
        return String(format: "%.1f×%.1f", document.width, document.height)
      } + [String(format: "%.1f", window.frame.width)])
  }

  /// The groups lay out at 720, 900, 1,100 and 1,400 pt, in Russian and in English, editing or
  /// not, with a group collapsed — and the window settles: the same sizes pass after pass, nothing
  /// left dirty, no loop in the log, with either kind of scroll bars.
  /// The width of the widest visible frame among the screens of this Mac.
  private static var widestScreen: CGFloat {
    NSScreen.screens.map(\.visibleFrame.width).max() ?? 0
  }

  func testTheGroupsLayOutAtEveryWidthWithoutALoop() throws {
    let needles = [
      LogProbe.Message.layoutLoop, LogProbe.Message.updateConstraints,
      LogProbe.Message.invalidGeometry, LogProbe.Message.stateDuringUpdate,
    ]
    let probe = LogProbe()
    let before = probe.counts(of: needles)
    environment.overviewLayout = .standard
    environment.overviewCollapsed = [.plan]
    for style in [NSScroller.Style.legacy, .overlay] {
      ScrollerStyleOverride.with(style) {
        for choice in [AppLanguage.Choice.russian, .english] {
          environment.language.choice = choice
          // A width no screen of this Mac holds is left out: AppKit keeps the window inside the
          // screen (the runner of CI is 1024 points wide), and the test would measure the screen.
          for width in [CGFloat(720), 900, 1_100, 1_400] where width <= Self.widestScreen {
            for editing in [false, true] {
              let what =
                "\(style == .legacy ? "legacy" : "overlay") \(choice.rawValue) "
                + "\(Int(width)) \(editing ? "editing" : "shown")"
              let screen = OverviewScreen()
              if editing { screen.edit() }
              let window = window(width: width, screen: screen)
              let started = Date()
              var records: [Record] = []
              // Passes until eight in a row agree and nothing is left to lay out — counted in
              // time, not in passes: on a busy Mac one pass does less, and a layout that loops
              // still never settles within the ten seconds.
              while Date().timeIntervalSince(started) < 10 {
                window.updateConstraintsIfNeeded()
                window.layoutIfNeeded()
                window.displayIfNeeded()
                spin(0.01)
                records.append(record(window))
                if records.count >= 8, records.suffix(8).allSatisfy({ $0 == records.last }),
                  !(window.contentView?.needsLayout ?? false)
                {
                  break
                }
              }
              let tail = records.suffix(8)
              XCTAssertTrue(
                tail.count == 8 && tail.allSatisfy { $0 == tail.first },
                "never settled \(what): \(Set(tail.map { $0.sizes.joined(separator: " ") }))")
              XCTAssertFalse(window.contentView?.needsLayout ?? false, "dirty \(what)")
              XCTAssertLessThan(Date().timeIntervalSince(started), 20, "slow \(what)")
              XCTAssertEqual(window.frame.width, width, accuracy: 1, "the window grew \(what)")
              window.contentViewController = nil
              window.close()
            }
          }
        }
      }
    }
    windows = []
    probe.assertQuiet(about: needles, comparedWith: before, "laying out the groups")
    XCTAssertEqual(AppDependencies.missingReaders, [])
  }
}
