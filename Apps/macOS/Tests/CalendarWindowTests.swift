import AppCore
import AppDatabase
import AppKit
import SwiftUI
import XCTest

@testable import OhMyMoney

/// «Календарь» in the main window: ⌘5 is its item of the menu bar, and what it posts brings the
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
    if let environment { await environment.close() }
    if let dataDirectoryBefore {
      setenv("OHMYMONEY_DATA_DIR", dataDirectoryBefore, 1)
    } else {
      unsetenv("OHMYMONEY_DATA_DIR")
    }
    if let directory { try? FileManager.default.removeItem(at: directory) }
  }

  private func settle(_ passes: Int = 10) {
    for _ in 0..<passes { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
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

  private func mainWindow(selection: SidebarItem = .section(.overview)) -> NSWindow {
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
    settle(20)
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

  /// ⌘5 is one item of the menu bar, and what it posts brings «Календарь» on screen.
  func testCommandFiveOpensTheCalendar() throws {
    func items(_ menu: NSMenu?) -> [NSMenuItem] {
      (menu?.items ?? []).flatMap { [$0] + items($0.submenu) }
    }
    let five = items(NSApp.mainMenu).filter {
      $0.keyEquivalent == "5"
        && $0.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask) == .command
    }
    XCTAssertEqual(five.count, 1, "⌘5: \(five.map(\.title))")
    XCTAssertTrue(["Календарь", "Calendar"].contains(five.first?.title ?? ""))

    compute.applyLight(try snapshot())
    _ = mainWindow()
    XCTAssertTrue(shown("overview"))
    NotificationCenter.default.post(name: .selectSection, object: 5)
    settle()
    XCTAssertTrue(shown("calendar"), "⌘5 did not bring «Календарь»")
    XCTAssertFalse(missingDependencies)
  }

  /// The month and the week are laid out with their dependencies.
  func testTheScreenIsLaidOutWithItsDependencies() throws {
    compute.applyLight(try snapshot())
    let window = mainWindow(selection: .section(.calendar))
    XCTAssertTrue(shown("calendar"))
    window.setContentSize(CGSize(width: 760, height: 600))
    settle()
    XCTAssertFalse(missingDependencies)
  }

  /// The tile on Overview, added as the owner adds it in the settings.
  func testTheTileIsLaidOutOnOverview() throws {
    compute.applyLight(try snapshot())
    let before = environment.overviewTiles
    defer { environment.overviewTiles = before }
    environment.overviewTiles = [.spendingCalendar, .monthToDate]
    _ = mainWindow()
    XCTAssertTrue(shown("overview"))
    XCTAssertFalse(missingDependencies)
  }
}
