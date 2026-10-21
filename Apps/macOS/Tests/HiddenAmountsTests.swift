import AppCore
import AppDatabase
import AppKit
import SwiftUI
import XCTest

@testable import OhMyMoney

/// «Скрыть суммы» hides the figures of the interface only: the CSV of the export and the CSV of
/// a report written while the amounts are hidden carry the real amounts. The eye on the toolbar
/// of the main window is the same switch as ⌃⌘H, and says what a click will do.
@MainActor
final class HiddenAmountsTests: XCTestCase {
  private var environment: AppEnvironment!
  private var store: TransactionsStore!
  private var compute: ComputeStore!
  private var windows: [NSWindow] = []
  private var directory: URL!
  private var dataDirectoryBefore: String?
  private var suiteName = ""
  private let food = CoreKit.Category(kind: .expense, name: "Food")

  override func setUp() async throws {
    dataDirectoryBefore = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-hidden-\(UUID().uuidString)", isDirectory: true)
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
    try environment.references!.save(food)
    var draft = TransactionDraft(amount: AmountE4(raw: 12_345_000), note: "Dinner")
    draft.normalizeSinglePart()
    draft.parts[0].categoryId = food.id
    try environment.transactions!.save(try draft.materialize())
    suiteName = "ohmymoney-hidden-\(UUID().uuidString)"
  }

  override func tearDown() async throws {
    for window in windows {
      window.contentViewController = nil
      window.close()
    }
    windows = []
    UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
    if let environment { await environment.close() }
    if let dataDirectoryBefore {
      setenv("OHMYMONEY_DATA_DIR", dataDirectoryBefore, 1)
    } else {
      unsetenv("OHMYMONEY_DATA_DIR")
    }
    if let directory { try? FileManager.default.removeItem(at: directory) }
  }

  // MARK: Files

  /// The export of the database, written while every figure on screen is «•••».
  func testTheExportWritesTheRealAmountsWhileTheyAreHidden() throws {
    environment.amounts.hidesAmounts = true
    XCTAssertEqual(environment.money.exact(AmountE4(raw: 12_345_000)), MoneyFormatter.mask)
    let writer = try XCTUnwrap(environment.stack).writer
    let target = directory.appendingPathComponent("export")
    let written = try CSVExportService(repository: ExportRepository(writer: writer))
      .export(to: target)
    XCTAssertFalse(written.isEmpty)
    for url in written {
      let text = try String(contentsOf: url, encoding: .utf8)
      XCTAssertFalse(text.contains(MoneyFormatter.mask), url.lastPathComponent)
    }
    let rows = try CSVReader.rows(
      from: try Data(contentsOf: target.appendingPathComponent("transactions.csv")))
    let amount = try XCTUnwrap(rows.first?.firstIndex(of: "amount"))
    XCTAssertEqual(rows.dropFirst().map { $0[amount] }, ["1234.5"], "the real amount")
  }

  /// The CSV of a report, written while the amounts are hidden, is the CSV written while shown.
  func testTheCSVOfAReportWritesTheRealAmountsWhileTheyAreHidden() throws {
    let month = environment.today.monthKey
    let dataset = Dataset(
      entries: try environment.transactions!.recentEntries(limit: 10), categories: [food])
    let model = ReportsBuilder.model(
      ReportsRequest(
        kind: .expensesByCategory, period: .month(month), grouping: .category,
        today: environment.today),
      ledger: Ledger(dataset: dataset, calendar: .system))
    func csv() -> String {
      String(
        decoding: ReportExport.data(
          model.table, names: ReportsText.csvNames(for: model, environment)),
        as: UTF8.self)
    }
    let shown = csv()
    environment.amounts.hidesAmounts = true
    let hidden = csv()
    XCTAssertEqual(hidden, shown)
    XCTAssertFalse(hidden.contains(MoneyFormatter.mask))
    XCTAssertTrue(hidden.contains("1235") || hidden.contains("1234"), hidden)
  }

  // MARK: The eye on the toolbar

  private func mainWindow() -> NSWindow {
    let deps = AppDependencies(environment: environment, store: store, compute: compute)
    let root = AppScenes.root(deps, window: .main, launches: false) { deps in
      MainWindow(
        deps: deps, actions: OperationActions(), opensDetails: false,
        selection: .section(.overview))
    }
    .environment(\.windowWidth, 1120)
    .defaultAppStorage(UserDefaults(suiteName: suiteName)!)
    let controller = NSHostingController(rootView: root)
    controller.sceneBridgingOptions = [.toolbars]
    let window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: 1120, height: 760),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentViewController = controller
    window.toolbarStyle = .unified
    window.orderFront(nil)
    windows.append(window)
    wait { !(window.toolbar?.items.isEmpty ?? true) }
    return window
  }

  private func wait(timeout: TimeInterval = 20, until done: () -> Bool) {
    let deadline = Date().addingTimeInterval(timeout)
    while !done(), Date() < deadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
  }

  /// Every item of the toolbar, the items of a group included.
  private static func items(of items: [NSToolbarItem]) -> [NSToolbarItem] {
    items.flatMap { item -> [NSToolbarItem] in
      [item] + ((item as? NSToolbarItemGroup)?.subitems ?? [])
    }
  }

  private func eye(in window: NSWindow, titled title: String) -> NSToolbarItem? {
    Self.items(of: window.toolbar?.items ?? []).first {
      $0.label == title || $0.paletteLabel == title || $0.toolTip == title
    }
  }

  /// A click on a toolbar item: its action, a button it holds, or a press as VoiceOver gives it.
  private func click(_ item: NSToolbarItem) -> Bool {
    if let action = item.action, NSApp.sendAction(action, to: item.target, from: item) {
      return true
    }
    guard let view = item.view else { return false }
    if let button = Self.subviews(of: view).compactMap({ $0 as? NSButton }).first {
      button.performClick(nil)
      return true
    }
    func pressable(_ element: Any, depth: Int) -> NSObject? {
      guard depth < 12, let object = element as? NSObject else { return nil }
      if object.responds(to: #selector(NSAccessibilityProtocol.accessibilityPerformPress)),
        WindowAccessibility.attribute(object, "accessibilityRole") as? String == "AXButton"
      {
        return object
      }
      let children = WindowAccessibility.attribute(object, "accessibilityChildren") as? [Any]
      return (children ?? []).lazy.compactMap { pressable($0, depth: depth + 1) }.first
    }
    guard let button = pressable(view, depth: 0) else {
      print("toolbar eye: \(type(of: view)) \(Self.subviews(of: view).map { type(of: $0) })")
      return false
    }
    WindowAccessibility.press(button)
    return true
  }

  private static func subviews(of view: NSView) -> [NSView] {
    view.subviews.flatMap { [$0] + subviews(of: $0) }
  }

  func testTheEyeOnTheToolbarSwitchesTheAmounts() throws {
    try TestEnvironment.requireScreen(width: 1120)
    let window = mainWindow()
    let hide = environment.language("privacy.hideAmounts")
    let show = environment.language("privacy.showAmounts")
    XCTAssertFalse(environment.amounts.hidesAmounts)
    let item = try XCTUnwrap(
      eye(in: window, titled: hide),
      "the toolbar has no «\(hide)»: \(Self.items(of: window.toolbar?.items ?? []).map(\.label))")
    // The button of SwiftUI on the toolbar is reached the way VoiceOver reaches it.
    try TestEnvironment.requireSwiftUIAccessibility()
    XCTAssertTrue(click(item), "the eye could not be clicked")
    wait { self.environment.amounts.hidesAmounts }
    XCTAssertTrue(environment.amounts.hidesAmounts, "the eye did not hide the amounts")
    wait { self.eye(in: window, titled: show) != nil }
    let again = try XCTUnwrap(eye(in: window, titled: show), "the eye now offers «\(show)»")
    XCTAssertTrue(click(again))
    wait { !self.environment.amounts.hidesAmounts }
    XCTAssertFalse(environment.amounts.hidesAmounts, "the eye did not show them again")
  }
}
