import AppCore
import AppDatabase
import AppKit
import SwiftUI
import XCTest

@testable import OhMyMoney

/// The selection bar over «Операции» of the main window, on synthetic data, with the editor open
/// beside the table: three operations selected bring the bar up — in the entry line's glass — and
/// the window stays as it was; scrolled to the end, the last row stands above the bar and the
/// line, not under them; Esc in the table takes the selection away and the bar with it.
@MainActor
final class TransactionsSelectionBarTests: XCTestCase {
  private var environment: AppEnvironment!
  private var store: TransactionsStore!
  private var compute: ComputeStore!
  private var actions: OperationActions!
  private var directory: URL!
  private var suiteName: String!
  private var defaults: UserDefaults!
  private var windows: [NSWindow] = []
  private var dataDirectoryBefore: String?
  private var entryStyleBefore: EntryStyle?
  private var missingReadersBefore: Set<String> = []
  private var rows: [TransactionEntry] = []
  private let food = CoreKit.Category(kind: .expense, name: "Food")

  /// The bar's capsule and its gap above the bottom of the window: the last row must stand
  /// higher than this to be read in full.
  private let barTop: CGFloat = 36 + 18

  override func setUp() async throws {
    missingReadersBefore = AppDependencies.missingReaders
    AppDependencies.missingReaders = []
    dataDirectoryBefore = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-selection-bar-\(UUID().uuidString)", isDirectory: true)
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
    suiteName = "ohmymoney-selection-bar-\(UUID().uuidString)"
    defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    entryStyleBefore = environment.entryStyle
    environment.entryStyle = .line
    seed()
  }

  override func tearDown() async throws {
    for window in windows {
      window.contentViewController = nil
      window.close()
    }
    windows = []
    defaults?.removePersistentDomain(forName: suiteName)
    if let entryStyleBefore { environment?.entryStyle = entryStyleBefore }
    if let environment { await environment.close() }
    if let dataDirectoryBefore {
      setenv("OHMYMONEY_DATA_DIR", dataDirectoryBefore, 1)
    } else {
      unsetenv("OHMYMONEY_DATA_DIR")
    }
    AppDependencies.missingReaders = missingReadersBefore
    if let directory { try? FileManager.default.removeItem(at: directory) }
  }

  /// Forty operations of this month — more than the window shows at once — so the table
  /// scrolls and the window opens on all of them.
  private func seed() {
    let calendar = CalendarContext.system
    let today = calendar.day(of: Date())
    let days = max(1, min(today.day, 6))
    rows = (0..<40).map { index in
      let day = calendar.adding(days: -(index % days), to: today)
      let when = calendar.startOfDay(day).addingTimeInterval(TimeInterval(60 * (index + 1)))
      let id = UUID()
      return TransactionEntry(
        transaction: Transaction(
          id: id, kind: .expense, occurredAt: when, amountE4: AmountE4(whole: Int64(100 + index)),
          note: "Row \(index)", createdAt: when, updatedAt: when),
        parts: [
          TransactionPart(
            transactionId: id, categoryId: food.id, quality: .neutral, qualitySource: .category,
            amountE4: AmountE4(whole: Int64(100 + index)))
        ])
    }
    compute.applyLight(
      DataSnapshot.build(
        dataset: Dataset(entries: rows, categories: [food]), calendar: calendar,
        today: environment.today, context: SnapshotContext(), version: DataVersion(load: 0)))
  }

  private func makeWindow(editing: TransactionEditorModel?) -> NSWindow {
    let deps = AppDependencies(environment: environment, store: store, compute: compute)
    let actions = OperationActions()
    self.actions = actions
    let root =
      AppScenes.root(deps, window: .main, launches: false) { deps in
        MainWindow(
          deps: deps, actions: actions, selection: .section(.operations),
          operations: OperationsScreenState(editing: editing))
      }
      .environment(\.windowWidth, 1_120)
      .defaultAppStorage(defaults)
    let controller = NSHostingController(rootView: root)
    controller.sceneBridgingOptions = [.toolbars]
    let window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: 1_120, height: 560),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentViewController = controller
    window.setContentSize(CGSize(width: 1_120, height: 560))
    window.toolbarStyle = .unified
    window.orderFront(nil)
    windows.append(window)
    return window
  }

  private func settle(_ window: NSWindow, _ seconds: TimeInterval = 0.5) {
    let deadline = Date().addingTimeInterval(seconds)
    repeat {
      window.updateConstraintsIfNeeded()
      window.layoutIfNeeded()
      window.displayIfNeeded()
      RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    } while Date() < deadline
  }

  /// The table of «Операции»: of the tables of the window — the sidebar is one too — the one
  /// with columns.
  private func table(in window: NSWindow) -> NSTableView? {
    guard let root = window.contentView else { return nil }
    var tables: [NSTableView] = []
    Self.all(of: root, into: &tables)
    return tables.first { $0.tableColumns.count > 1 }
  }

  private static func all<V: NSView>(of view: NSView, into found: inout [V]) {
    if let match = view as? V { found.append(match) }
    for subview in view.subviews { all(of: subview, into: &found) }
  }

  private func waitForRows(_ window: NSWindow) throws -> NSTableView {
    let deadline = Date().addingTimeInterval(5)
    repeat {
      settle(window, 0.05)
      if let table = table(in: window), table.numberOfRows >= rows.count { return table }
    } while Date() < deadline
    XCTFail("the table never filled: rows \(table(in: window)?.numberOfRows ?? -1)")
    throw XCTSkip("no table")
  }

  /// Scrolls the table to its very end, as the owner's wheel does: as far as the clip view lets.
  private func scrollToTheEnd(_ table: NSTableView) throws {
    let scroll = try XCTUnwrap(table.enclosingScrollView)
    var bounds = scroll.contentView.bounds
    bounds.origin.y = table.frame.height + 10_000
    let end = scroll.contentView.constrainBoundsRect(bounds).origin
    scroll.contentView.scroll(to: end)
    scroll.reflectScrolledClipView(scroll.contentView)
  }

  /// Where the bottom of the last row is, above the bottom of the window.
  private func lastRowBottom(_ table: NSTableView) -> CGFloat {
    table.convert(table.rect(ofRow: table.numberOfRows - 1), to: nil).minY
  }

  func testThreeSelectedBesideTheInspectorKeepTheLastRowAboveTheBarAndEscClearsThem() throws {
    try TestEnvironment.requireScreen(width: 1_120)
    let editing = TransactionEditorModel(entry: rows[0], environment: environment)
    let window = makeWindow(editing: editing)
    let table = try waitForRows(window)
    settle(window)
    let frame = window.frame

    let three: Set<UUID> = [rows[0].id, rows[3].id, rows[7].id]
    actions.selection = three
    settle(window, 1)
    XCTAssertEqual(actions.selection, three)
    XCTAssertNotEqual(
      SelectionBar.form(selection: actions.selection, writing: store.isWritingInBackground),
      .hidden, "the bar is up")
    XCTAssertEqual(window.frame, frame, "the window moved or changed its size")

    try scrollToTheEnd(table)
    settle(window)
    XCTAssertGreaterThanOrEqual(
      lastRowBottom(table), barTop - 0.5,
      "scrolled to the end, the last row is still under the bar")

    // Esc in the table takes the selection away: the key the window hands its first responder.
    XCTAssertTrue(window.makeFirstResponder(table))
    // The table takes the focus of the window on the next turn of the loop, as after a click.
    settle(window, 0.2)
    table.keyDown(with: EntryHost.key("\u{1b}", code: 53))
    settle(window)
    XCTAssertEqual(actions.selection, [], "Esc left the selection")
    XCTAssertEqual(
      SelectionBar.form(selection: actions.selection, writing: store.isWritingInBackground),
      .hidden, "the bar went away")
    XCTAssertEqual(window.frame, frame)
  }

  /// With earlier months behind «Показать раньше», the row of that button sits between the table
  /// and the bar: the last row is above the bar all the same.
  func testWithEarlierMonthsHiddenTheLastRowIsAboveTheBarToo() throws {
    try TestEnvironment.requireScreen(width: 1_120)
    let calendar = CalendarContext.system
    let older = (0..<30).map { index -> TransactionEntry in
      let day = calendar.adding(days: -(70 + index * 9), to: calendar.day(of: Date()))
      let when = calendar.startOfDay(day).addingTimeInterval(9 * 3_600)
      let id = UUID()
      return TransactionEntry(
        transaction: Transaction(
          id: id, kind: .expense, occurredAt: when, amountE4: AmountE4(whole: 50),
          note: "Old \(index)", createdAt: when, updatedAt: when),
        parts: [
          TransactionPart(
            transactionId: id, categoryId: food.id, quality: .neutral, qualitySource: .category,
            amountE4: AmountE4(whole: 50))
        ])
    }
    compute.applyLight(
      DataSnapshot.build(
        dataset: Dataset(entries: rows + older, categories: [food]), calendar: calendar,
        today: environment.today, context: SnapshotContext(), version: DataVersion(load: 1)))
    let window = makeWindow(editing: nil)
    let table = try waitForRows(window)
    settle(window)
    XCTAssertLessThan(
      table.numberOfRows, rows.count + older.count, "the earlier months are behind the button")

    actions.selection = [rows[0].id]
    settle(window, 1)
    try scrollToTheEnd(table)
    settle(window)
    XCTAssertGreaterThanOrEqual(
      lastRowBottom(table), barTop - 0.5,
      "scrolled to the end, the last row is under the bar")
  }
}
