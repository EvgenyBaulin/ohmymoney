import AppCore
import AppDatabase
import AppKit
import SwiftUI
import XCTest

@testable import OhMyMoney

/// Return saves the editor of a saved operation, as it saves a new one: in a text field of the
/// panel, and — in the sheet, which has a default button — anywhere in it, a date or a menu.
@MainActor
final class EditorReturnTests: XCTestCase {
  private var environment: AppEnvironment!
  private var store: TransactionsStore!
  private var window: NSWindow!
  private var directory: URL!
  private var closed = 0

  override func setUp() async throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("editor-return-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    setenv("OHMYMONEY_DATA_DIR", directory.path, 1)
    environment = AppEnvironment()
    await environment.start(preparing: {
      try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    })
    store = TransactionsStore()
    store.attach(
      try XCTUnwrap(environment.transactions), references: try XCTUnwrap(environment.references),
      planning: try XCTUnwrap(environment.planning))
  }

  override func tearDown() async throws {
    window?.contentView = nil
    window?.close()
    window = nil
    if let environment { await environment.close() }
    unsetenv("OHMYMONEY_DATA_DIR")
    if let directory { try? FileManager.default.removeItem(at: directory) }
  }

  private func settle(_ seconds: TimeInterval = 0.3) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
  }

  private func textFields(in view: NSView) -> [NSTextField] {
    view.subviews.flatMap { subview -> [NSTextField] in
      ((subview as? NSTextField).map { [$0] } ?? []) + textFields(in: subview)
    }
  }

  private func views<V: NSView>(of type: V.Type, in view: NSView) -> [V] {
    view.subviews.flatMap { subview -> [V] in
      ((subview as? V).map { [$0] } ?? []) + views(of: type, in: subview)
    }
  }

  /// The editor of one saved operation, shown in a window the way the main window shows it.
  private func open(style: TransactionEditor.Style) throws -> TransactionEntry {
    var draft = TransactionDraft(amount: AmountE4(whole: 300), note: "Dinner")
    draft.normalizeSinglePart()
    let dinner = try draft.materialize()
    try XCTUnwrap(environment.transactions).save(dinner)
    let editor = TransactionEditorModel(entry: dinner, environment: environment)
    let deps = AppDependencies(
      environment: environment, store: store, compute: ComputeStore(calendar: .system))
    window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: 760, height: 900), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(
      rootView: TransactionEditor(editor: editor, style: style) { [self] in closed += 1 }
        .appDependencies(deps))
    window.makeKeyAndOrderFront(nil)
    settle(0.5)
    return dinner
  }

  private func note(of entry: TransactionEntry) throws -> String? {
    try XCTUnwrap(environment.transactions).entry(id: entry.id)?.transaction.note
  }

  /// Return in the field of the note saves what was typed, and the editor closes.
  func testReturnInAFieldOfTheEditorSaves() throws {
    let dinner = try open(style: .sheet)
    let field = try XCTUnwrap(
      textFields(in: window.contentView!).first { $0.stringValue == "Dinner" }, "the note")
    XCTAssertTrue(window.makeFirstResponder(field))
    let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
    editor.setSelectedRange(NSRange(location: editor.string.count, length: 0))
    editor.insertText(" out", replacementRange: editor.selectedRange())
    settle(0.1)
    editor.insertNewline(nil)
    settle()
    XCTAssertEqual(try note(of: dinner), "Dinner out")
    XCTAssertEqual(closed, 1)
  }

  /// In the sheet Return saves from the date too — the default button answers.
  func testReturnOnTheDateOfTheSheetSaves() throws {
    let dinner = try open(style: .sheet)
    let field = try XCTUnwrap(
      textFields(in: window.contentView!).first { $0.stringValue == "Dinner" }, "the note")
    XCTAssertTrue(window.makeFirstResponder(field))
    let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
    editor.setSelectedRange(NSRange(location: editor.string.count, length: 0))
    editor.insertText(" late", replacementRange: editor.selectedRange())
    settle(0.1)
    let picker = try XCTUnwrap(views(of: NSDatePicker.self, in: window.contentView!).first)
    XCTAssertTrue(window.makeFirstResponder(picker))
    settle(0.1)
    XCTAssertTrue(
      window.performKeyEquivalent(with: EntryHost.key("\r", code: 36)), "Return reached «Save»")
    settle()
    XCTAssertEqual(try note(of: dinner), "Dinner late")
    XCTAssertEqual(closed, 1)
  }

  /// A Return the editor cannot save — a total of zero — saves nothing and does not close it.
  func testReturnOverAnAmountThatCannotBeSavedWritesNothing() throws {
    let dinner = try open(style: .sheet)
    let amount = try XCTUnwrap(
      textFields(in: window.contentView!).first { $0.placeholderString == "0" }, "the amount")
    XCTAssertTrue(window.makeFirstResponder(amount))
    let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
    editor.selectAll(nil)
    editor.insertText("0", replacementRange: editor.selectedRange())
    settle(0.1)
    editor.insertNewline(nil)
    settle()
    XCTAssertEqual(closed, 0)
    XCTAssertEqual(try note(of: dinner), "Dinner")
    XCTAssertEqual(
      try XCTUnwrap(environment.transactions).entry(id: dinner.id)?.transaction.amountE4,
      AmountE4(whole: 300))
  }
}
