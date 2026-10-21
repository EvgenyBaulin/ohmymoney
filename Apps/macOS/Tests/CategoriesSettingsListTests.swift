import AppCore
import AppDatabase
import AppKit
import SwiftUI
import XCTest

@testable import OhMyMoney

/// Settings → Категории, laid out for real. The list was made of sections, each category the
/// header of its own: AppKit draws a header of a section as a group row, which floats — «Продукты»
/// stuck to the top of the list with a background of its own while its subcategories scrolled
/// under it. The list is flat now: no row of it is a group row.
@MainActor
final class CategoriesSettingsListTests: XCTestCase {
  private var environment: AppEnvironment!
  private var directory: URL!
  private var dataDirectoryBefore: String?

  override func setUp() async throws {
    dataDirectoryBefore = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-category-list-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    setenv("OHMYMONEY_DATA_DIR", directory.path, 1)
    environment = AppEnvironment()
    await environment.start(preparing: {
      try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    })
  }

  override func tearDown() async throws {
    if let environment { await environment.close() }
    if let dataDirectoryBefore {
      setenv("OHMYMONEY_DATA_DIR", dataDirectoryBefore, 1)
    } else {
      unsetenv("OHMYMONEY_DATA_DIR")
    }
    if let directory { try? FileManager.default.removeItem(at: directory) }
  }

  /// A window with `view` in it, laid out and drawn once. The callers hand the dependencies to
  /// the view: the list of categories reads them, the bare list of the probe needs none.
  private func show(_ view: some View) -> NSWindow {
    // dependencies: handed in by the caller, where the view is made
    let window = NSWindow(contentViewController: NSHostingController(rootView: view))
    window.isReleasedWhenClosed = false
    window.orderFront(nil)
    RunLoop.main.run(until: Date().addingTimeInterval(0.8))
    return window
  }

  private static func tables(in view: NSView) -> [NSTableView] {
    (view as? NSTableView).map { [$0] } ?? view.subviews.flatMap(tables)
  }

  /// The rows AppKit draws as group rows — the ones that float over the rows under them.
  private static func groupRows(of table: NSTableView) -> [Int] {
    (0..<table.numberOfRows).filter { row in
      table.delegate?.tableView?(table, isGroupRow: row) == true
        || table.rowView(atRow: row, makeIfNecessary: true)?.isGroupRowStyle == true
    }
  }

  /// The probe itself: a list made of a section with a header has a group row, so a list of
  /// categories that finds none has none, rather than being a list the probe cannot see into.
  func testAHeaderOfASectionIsAGroupRow() throws {
    let window = show(
      List {
        Section {
          Text(verbatim: "Groceries")
          Text(verbatim: "Cafés")
        } header: {
          Text(verbatim: "Food")
        }
      }
      .frame(width: 400, height: 300))
    defer { window.close() }

    let tables = Self.tables(in: try XCTUnwrap(window.contentView))
    XCTAssertFalse(tables.isEmpty, "a SwiftUI list is no longer a table")
    XCTAssertFalse(
      tables.flatMap(Self.groupRows).isEmpty, "the probe found no header in a list of sections")
  }

  /// Settings → Категории with «Сверка» remembered by the reconciliation: the rows of «Сверка»
  /// and of what is under it have no limit field; «Food» keeps its own.
  func testTheReconciliationRowsHaveNoLimitField() throws {
    let references = try XCTUnwrap(environment.references)
    let settings = try XCTUnwrap(environment.settings)
    // First in the list: the list is lazy, and a row below the window has no field to find.
    let food = CoreKit.Category(kind: .expense, name: "Food", sort: -3, quality: .neutral)
    let reconcile = CoreKit.Category(
      kind: .expense, name: "Сверка", sort: -2, quality: .neutral)
    let small = CoreKit.Category(
      parentId: reconcile.id, kind: .expense, name: "Мелочи", sort: -1)
    for category in [food, reconcile, small] { try references.save(category) }
    let deps = AppDependencies.forTests(environment)
    let placeholder = environment.language("categories.limit.placeholder", table: "Settings")

    func limitFields() throws -> Int {
      let window = show(
        CategoriesSettingsView().frame(width: 700, height: 520).appDependencies(deps))
      defer { window.close() }
      return Self.textFields(in: try XCTUnwrap(window.contentView))
        .filter { $0.placeholderString == placeholder }.count
    }

    let everyRow = try limitFields()
    XCTAssertGreaterThanOrEqual(everyRow, 3, "the probe finds no limit field")
    try settings.set(PlanningSettings.reconcileExpenseCategoryKey, to: reconcile.id.uuidString)
    XCTAssertEqual(LimitWrites.limitless(environment, nil), [reconcile.id])
    XCTAssertEqual(
      everyRow - (try limitFields()), 2, "«Сверка» or «Мелочи» still offers a limit")
  }

  private static func textFields(in view: NSView) -> [NSTextField] {
    ((view as? NSTextField).map { [$0] } ?? []) + view.subviews.flatMap(textFields)
  }

  func testTheListOfCategoriesHasNoHeaderThatSticks() throws {
    // A category with a subcategory under it: the header the list used to stick to the top.
    let references = try XCTUnwrap(environment.references)
    let food = CoreKit.Category(kind: .expense, name: "Food", sort: 1_000, quality: .neutral)
    try references.save(food)
    try references.save(
      CoreKit.Category(parentId: food.id, kind: .expense, name: "Groceries", sort: 1_001))
    let deps = AppDependencies.forTests(environment)
    let window = show(CategoriesSettingsView().frame(width: 700, height: 520).appDependencies(deps))
    defer { window.close() }
    XCTAssertEqual(AppDependencies.missingReaders, [])

    let tables = Self.tables(in: try XCTUnwrap(window.contentView))
    let rows = tables.map(\.numberOfRows).reduce(0, +)
    XCTAssertGreaterThan(rows, 1, "the list of categories is empty")
    XCTAssertEqual(tables.flatMap(Self.groupRows), [], "a row of the list is a floating header")
  }
}
