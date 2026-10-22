import AppCore
import AppDatabase
import AppKit
import SwiftUI
import XCTest

@testable import OhMyMoney

/// The window-level listener of the palette, the question sheet and the saved views, over an
/// in-memory database: what a notification does, and what the editor writes.
@MainActor
final class QuestionsHostTests: XCTestCase {
  private var window: NSWindow?
  private var directory: URL?
  private var environment: AppEnvironment!
  private var store: TransactionsStore!
  private var deps: AppDependencies!
  private var operations: OperationsScreenState!

  override func setUp() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("questions-host-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    self.directory = directory
    setenv("OHMYMONEY_DATA_DIR", directory.path, 1)
    environment = AppEnvironment()
    await environment.start(preparing: {
      try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    })
    store = TransactionsStore()
    store.attach(
      try XCTUnwrap(environment.transactions), references: try XCTUnwrap(environment.references),
      planning: try XCTUnwrap(environment.planning), savedViews: environment.savedViews)
    deps = AppDependencies(
      environment: environment, store: store, compute: ComputeStore(calendar: .system))
    operations = OperationsScreenState()
  }

  override func tearDown() async throws {
    window?.contentView = nil
    window?.close()
    window = nil
    unsetenv("OHMYMONEY_DATA_DIR")
    if let directory { try? FileManager.default.removeItem(at: directory) }
  }

  private func show() {
    let window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(
      rootView: Color.clear.questionsHost(deps: deps, operations: operations)
        .appDependencies(deps))
    window.makeKeyAndOrderFront(nil)
    self.window = window
    settle()
  }

  private func settle(_ seconds: TimeInterval = 0.3) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
  }

  private func attribute(_ object: NSObject, _ name: String) -> Any? {
    guard object.responds(to: NSSelectorFromString(name)) else { return nil }
    return object.value(forKey: name)
  }

  private func element(identified identifier: String, in root: NSView?) -> NSObject? {
    var found: NSObject?
    func walk(_ element: Any) {
      guard found == nil, let object = element as? NSObject else { return }
      if attribute(object, "accessibilityIdentifier") as? String == identifier {
        found = object
        return
      }
      for child in attribute(object, "accessibilityChildren") as? [Any] ?? [] { walk(child) }
    }
    if let root { walk(root) }
    return found
  }

  private func identifiers(in root: NSView?) -> [String] {
    var found: [String] = []
    func walk(_ element: Any) {
      guard let object = element as? NSObject else { return }
      if let id = attribute(object, "accessibilityIdentifier") as? String, !id.isEmpty {
        found.append(id)
      }
      for child in attribute(object, "accessibilityChildren") as? [Any] ?? [] { walk(child) }
    }
    if let root { walk(root) }
    return found
  }

  // MARK: Filters

  func testAFilterAskedForSetsOperationsAndComesToThatScreen() throws {
    show()
    final class Arrival: @unchecked Sendable { var item: SidebarItem? }
    let arrival = Arrival()
    let token = NotificationCenter.default.addObserver(
      forName: .openSidebarItem, object: nil, queue: .main
    ) { note in arrival.item = note.object as? SidebarItem }
    defer { NotificationCenter.default.removeObserver(token) }
    let category = UUID()
    let period = Period.month(MonthKey(year: 2020, month: 3))
    QuestionOpening.showOperations(
      OperationsFilterRequest(
        filter: EntryFilter(period: period, categoryId: category, text: "утро"),
        columns: OperationColumnLayout.storage(showing: ["amount", "time"])))
    settle()
    XCTAssertEqual(operations.filters.categoryId, category)
    XCTAssertEqual(operations.filters.search, "утро")
    XCTAssertEqual(operations.filters.period, .custom)
    XCTAssertEqual(operations.filters.customStart, DateOnly(year: 2020, month: 3, day: 1))
    XCTAssertEqual(arrival.item, .section(.operations))
    let columns = OperationColumnLayout(
      storage: UserDefaults.standard.string(forKey: OperationColumnLayout.storageKey))
    XCTAssertEqual(columns.visible.first, .amount)
    UserDefaults.standard.removeObject(forKey: OperationColumnLayout.storageKey)
  }

  // MARK: The palette

  private func textField(placeholder: String, in sheet: NSWindow) -> NSTextField? {
    func walk(_ view: NSView) -> NSTextField? {
      if let field = view as? NSTextField, field.placeholderString == placeholder { return field }
      for subview in view.subviews { if let found = walk(subview) { return found } }
      return nil
    }
    return sheet.contentView.flatMap(walk)
  }

  func testTheNotificationOpensThePaletteWhichNarrowsAsItIsTypedIn() throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    show()
    XCTAssertNil(window?.attachedSheet)
    NotificationCenter.default.post(name: .showCommandPalette, object: nil)
    settle(0.8)
    let sheet = try XCTUnwrap(window?.attachedSheet, "⌘K opens the palette")
    let field = try XCTUnwrap(
      textField(placeholder: QuestionsText.t("questions.palette.prompt", environment), in: sheet),
      "with its field")
    XCTAssertNotNil(
      element(identified: "palette.row.command.newDebt", in: sheet.contentView),
      "and the commands under it")
    XCTAssertNotNil(element(identified: "palette.row.screen.overview", in: sheet.contentView))
    XCTAssertTrue(sheet.makeFirstResponder(field))
    let editor = try XCTUnwrap(sheet.firstResponder as? NSTextView)
    editor.insertText("долг", replacementRange: editor.selectedRange())
    settle(0.5)
    XCTAssertNotNil(element(identified: "palette.row.command.newDebt", in: sheet.contentView))
    XCTAssertNil(
      element(identified: "palette.row.screen.overview", in: sheet.contentView),
      "what does not match goes")
  }

  func testTheQuestionSheetOpensFromItsNotification() throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    show()
    NotificationCenter.default.post(name: .showQuestionSheet, object: nil)
    settle(0.8)
    let sheet = try XCTUnwrap(window?.attachedSheet)
    XCTAssertNotNil(
      textField(placeholder: QuestionsText.t("questions.prompt", environment), in: sheet),
      "its field asks for a question")
    XCTAssertNotNil(element(identified: "question.panel", in: sheet.contentView))
  }

  // MARK: The saved views

  func testSavedViewsAreAddedRenamedMovedAndDeletedInOneStepEach() throws {
    let editor = SavedViewsEditor(environment: environment, store: store, compute: deps.compute)
    let today = DateOnly(year: 2026, month: 10, day: 15)
    var filters = TransactionFilters(today: today)
    filters.period = .lastMonth
    let first = filters.saved(named: "Кафе за квартал", today: today)
    let second = filters.saved(named: "Такси", today: today)
    XCTAssertTrue(editor.edit { $0.add(first) })
    XCTAssertTrue(editor.edit { $0.add(second) })
    XCTAssertEqual(editor.book.filters.map(\.name), ["Кафе за квартал", "Такси"])
    XCTAssertTrue(editor.edit { $0.rename(second.id, to: "кафе за квартал") })
    XCTAssertEqual(
      editor.book.filters.map(\.name), ["Кафе за квартал", "кафе за квартал 2"],
      "a second name the same (the case not counting) gets a number")
    XCTAssertTrue(editor.edit { $0.moveFilter(from: 1, to: 0) })
    XCTAssertEqual(editor.book.filters.map(\.id), [second.id, first.id])
    XCTAssertTrue(editor.edit { $0.remove(first.id) })
    XCTAssertEqual(editor.book.filters.map(\.id), [second.id])
    store.undo()
    XCTAssertEqual(editor.book.filters.map(\.id), [second.id, first.id], "⌘Z brings it back")
    let reloaded = try XCTUnwrap(environment.savedViews).book()
    XCTAssertEqual(reloaded.filters.first?.period, .floating(.lastMonth), "kept as words")
  }

  func testAReportIsKeptWithItsTableGroupingAndPeriod() throws {
    let editor = SavedViewsEditor(environment: environment, store: store, compute: deps.compute)
    let report = SavedReport(
      name: "По местам", kind: .expensesByCategoryAndSubcategory, grouping: .place,
      period: .floating(.thisYear))
    XCTAssertTrue(editor.edit { $0.add(report) })
    XCTAssertEqual(editor.book.reports, [report])
    XCTAssertTrue(editor.edit { $0.remove(report.id) })
    XCTAssertTrue(editor.book.reports.isEmpty)
  }
}
