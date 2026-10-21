import AppCore
import AppDatabase
import AppKit
import SwiftUI
import XCTest

@testable import OhMyMoney

/// The main window with the form at the side (`EntryStyle.form`): an operation selected in a list
/// is edited in the form — «Правка операции», «Отмена», «Сохранить» — through the save of the
/// edit sheet; and in «Операции» the arrows move the selection, the form following it.
@MainActor
final class EntryFormEditingTests: XCTestCase {
  private var environment: AppEnvironment!
  private var store: TransactionsStore!
  private var compute: ComputeStore!
  private var windows: [NSWindow] = []
  private var directory: URL!
  private var dataDirectoryBefore: String?
  private let shop = CoreKit.Category(kind: .expense, name: "Продукты", quality: .neutral)

  override func setUp() async throws {
    dataDirectoryBefore = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-form-edit-\(UUID().uuidString)", isDirectory: true)
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
    try environment.references!.save(shop)
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
    if let directory { try? FileManager.default.removeItem(at: directory) }
  }

  // MARK: Helpers

  private func wait(_ seconds: Double = 0.4) async throws {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
      try await Task.sleep(for: .milliseconds(50))
      spin()
    }
  }

  private func spin() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }

  /// Operations written to the book, newest first, and shown by the window's data.
  @discardableResult
  private func book(_ notes: [String]) throws -> [TransactionEntry] {
    let calendar = CalendarContext.system
    var written: [TransactionEntry] = []
    for (index, note) in notes.enumerated() {
      var draft = TransactionDraft(
        occurredAt: Date().addingTimeInterval(-Double(index + 1) * 3600),
        amount: AmountE4(whole: Int64(100 * (index + 1))), note: note)
      draft.normalizeSinglePart()
      draft.parts[0].categoryId = shop.id
      let entry = try draft.materialize()
      try environment.transactions!.save(entry)
      written.append(entry)
    }
    let snapshot = DataSnapshot.build(
      dataset: Dataset(entries: written, categories: [shop]), calendar: calendar,
      today: environment.today, context: SnapshotContext(), version: DataVersion(load: 0))
    compute.applyLight(snapshot)
    store.show(snapshot.ledger)
    return written
  }

  private func mainWindow(
    actions: OperationActions, on section: SidebarItem = .section(.operations),
    style: EntryStyle = .form
  ) async throws -> NSWindow {
    environment.entryStyle = style
    let deps = AppDependencies(environment: environment, store: store, compute: compute)
    let root = AppScenes.root(deps, window: .main, launches: false) { deps in
      MainWindow(deps: deps, actions: actions, opensDetails: false, selection: section)
    }
    .environment(\.windowWidth, 1000)
    let controller = NSHostingController(rootView: root)
    let window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: 1000, height: 700),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentViewController = controller
    window.makeKeyAndOrderFront(nil)
    windows.append(window)
    try await wait(1)
    return window
  }

  private func element(_ identifier: String, in window: NSWindow) -> NSObject? {
    WindowAccessibility.element(identified: identifier, in: window)
  }

  private func textFields(in view: NSView?) -> [NSTextField] {
    guard let view else { return [] }
    return view.subviews.flatMap { subview -> [NSTextField] in
      ((subview as? NSTextField).map { [$0] } ?? []) + textFields(in: subview)
    }
  }

  private func tables(in view: NSView?) -> [NSTableView] {
    guard let view else { return [] }
    return view.subviews.flatMap { subview -> [NSTableView] in
      ((subview as? NSTableView).map { [$0] } ?? []) + tables(in: subview)
    }
  }

  // MARK: Editing in the form

  /// One operation selected: the form edits it — its description in the field —, «Сохранить»
  /// writes the change over it, and the form goes back to a new operation.
  func testASelectedOperationIsEditedInTheForm() async throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    let written = try book(["хлеб", "молоко"])
    let actions = OperationActions()
    let window = try await mainWindow(actions: actions)
    XCTAssertNil(element("entry.form.editTitle", in: window), "a new operation at first")

    actions.selection = [written[1].id]
    try await wait()
    XCTAssertNotNil(element("entry.form.editTitle", in: window), "«Правка операции»")
    let noteTitle = environment.language("entry.note", table: "Entry")
    let note = try XCTUnwrap(
      textFields(in: window.contentView).first {
        $0.placeholderString == noteTitle && $0.stringValue == "молоко"
      }, "the description of the selected operation")
    XCTAssertTrue(window.makeFirstResponder(note))
    let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
    editor.selectAll(nil)
    editor.insertText("кефир", replacementRange: editor.selectedRange())
    try await wait(0.2)

    WindowAccessibility.press(try XCTUnwrap(element("entry.form.saveEdit", in: window)))
    try await wait()
    let saved = try XCTUnwrap(
      try environment.transactions!.recentEntries(limit: 10).first { $0.id == written[1].id })
    XCTAssertEqual(saved.transaction.note, "кефир", "the edit was written over the operation")
    XCTAssertEqual(try environment.transactions!.count(), 2, "and nothing new")
    XCTAssertTrue(store.canUndo, "one step of ⌘Z")
    XCTAssertNil(element("entry.form.editTitle", in: window), "back to a new operation")
    XCTAssertEqual(actions.selection, [])
  }

  /// «Отмена»: nothing is written, the form goes back to a new operation.
  func testCancelLeavesTheOperationAsItWas() async throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    let written = try book(["хлеб"])
    let actions = OperationActions()
    let window = try await mainWindow(actions: actions)
    actions.selection = [written[0].id]
    try await wait()
    XCTAssertNotNil(element("entry.form.editTitle", in: window))
    WindowAccessibility.press(try XCTUnwrap(element("entry.form.cancelEdit", in: window)))
    try await wait()
    XCTAssertNil(element("entry.form.editTitle", in: window))
    XCTAssertEqual(actions.selection, [])
    XCTAssertFalse(store.canUndo, "nothing was written")
  }

  /// Two rows selected: the form makes a new operation, as with none.
  func testSeveralRowsSelectedLeaveTheFormForANewOperation() async throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    let written = try book(["хлеб", "молоко"])
    let actions = OperationActions()
    let window = try await mainWindow(actions: actions)
    actions.selection = [written[0].id]
    try await wait()
    XCTAssertNotNil(element("entry.form.editTitle", in: window))
    actions.selection = Set(written.map(\.id))
    try await wait()
    XCTAssertNil(element("entry.form.editTitle", in: window))
  }

  /// The rule of the selection, without a window.
  func testOnlyOneSelectedOperationIsEdited() throws {
    let entry = try book(["хлеб"])[0]
    let find: (UUID) -> TransactionEntry? = { $0 == entry.id ? entry : nil }
    XCTAssertEqual(EntryFormSelection.operation([entry.id], find: find)?.id, entry.id)
    XCTAssertNil(EntryFormSelection.operation([], find: find))
    XCTAssertNil(EntryFormSelection.operation([entry.id, UUID()], find: find))
    XCTAssertNil(EntryFormSelection.operation([UUID()], find: find), "a transfer, not an operation")
  }

  // MARK: The arrows in «Операции»

  /// The rule of the arrows, without a window.
  func testTheArrowsStepThroughTheRowsInTheirOrder() {
    let rows = [UUID(), UUID(), UUID()]
    XCTAssertEqual(OperationsArrows.next(from: [rows[0]], rows: rows, down: true), rows[1])
    XCTAssertEqual(OperationsArrows.next(from: [rows[1]], rows: rows, down: false), rows[0])
    XCTAssertEqual(OperationsArrows.next(from: [rows[2]], rows: rows, down: true), rows[2])
    XCTAssertEqual(OperationsArrows.next(from: [], rows: rows, down: true), rows[0])
    XCTAssertNil(OperationsArrows.next(from: [], rows: rows, down: false))
    XCTAssertNil(OperationsArrows.next(from: [rows[0], rows[1]], rows: rows, down: true))
    XCTAssertNil(OperationsArrows.next(from: [rows[0]], rows: [], down: true))
  }

  /// A row of «Операции» selected with the keyboard in the table: ↓ selects the next row, ↑ the one
  /// before.
  func testTheArrowsMoveTheSelectionInOperations() async throws {
    try await arrowsMoveTheSelection(style: .form)
  }

  func testTheArrowsMoveTheSelectionInOperationsUnderTheLine() async throws {
    try await arrowsMoveTheSelection(style: .line)
  }

  /// A row selected by the window — ↓ from the entry line, a click on another screen — and then
  /// the keyboard in the list: ↓ goes on from that row.
  func testTheArrowsGoOnFromASelectionMadeByTheWindow() async throws {
    let written = try book(["хлеб", "молоко", "сыр"])
    let actions = OperationActions()
    let window = try await mainWindow(actions: actions, style: .line)
    let table = try XCTUnwrap(
      tables(in: window.contentView).first { $0.tableColumns.count > 1 && $0.numberOfRows >= 3 },
      "the table of «Операции»")
    XCTAssertTrue(window.makeFirstResponder(table))
    actions.selection = [written[1].id]
    try await wait(1.5)
    arrow(125, NSDownArrowFunctionKey, in: window)
    try await wait()
    XCTAssertEqual(actions.selection, [written[2].id], "↓ goes on from the row selected")
  }

  private func arrow(_ code: UInt16, _ scalar: Int, in window: NSWindow) {
    let characters = String(UnicodeScalar(UInt16(scalar))!)
    window.sendEvent(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [.function, .numericPad],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, characters: characters, charactersIgnoringModifiers: characters,
        isARepeat: false, keyCode: code)!)
  }

  private func arrowsMoveTheSelection(style: EntryStyle) async throws {
    let written = try book(["хлеб", "молоко", "сыр"])
    let actions = OperationActions()
    let window = try await mainWindow(actions: actions, style: style)
    let table = try XCTUnwrap(
      tables(in: window.contentView).first { $0.tableColumns.count > 1 && $0.numberOfRows >= 3 },
      "the table of «Операции»")
    XCTAssertTrue(window.makeFirstResponder(table))
    // The first row the table selects an operation on: the header of the day stands above it,
    // and the table's delegate does not say which rows are headers.
    for row in 0..<table.numberOfRows where actions.selection.isEmpty {
      table.selectRowIndexes([row], byExtendingSelection: false)
      try await wait()
    }
    XCTAssertEqual(actions.selection, [written[0].id], "the newest row is the first one")
    func arrow(_ code: UInt16, _ scalar: Int) {
      let characters = String(UnicodeScalar(UInt16(scalar))!)
      window.sendEvent(
        NSEvent.keyEvent(
          with: .keyDown, location: .zero, modifierFlags: [.function, .numericPad],
          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
          context: nil, characters: characters, charactersIgnoringModifiers: characters,
          isARepeat: false, keyCode: code)!)
    }
    arrow(125, NSDownArrowFunctionKey)
    try await wait()
    XCTAssertEqual(actions.selection, [written[1].id], "↓ selects the next row")
    arrow(126, NSUpArrowFunctionKey)
    try await wait()
    XCTAssertEqual(actions.selection, [written[0].id], "↑ the one before")
  }
}
