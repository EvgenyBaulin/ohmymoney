import AppCore
import AppDatabase
import AppKit
import SwiftUI
import XCTest

@testable import OhMyMoney

/// The ↓ panel lays its fields in the owner's order (Settings → «Ввод»), re-lays them the moment
/// the order changes, and Tab from the line goes to the first field of that order. The
/// order is the owner's own key in the test host's defaults: `AppDefaultsGuard` clears it before
/// every test and puts the owner's back afterwards.
@MainActor
final class EntryFieldOrderPanelTests: XCTestCase {
  private var windows: [NSWindow] = []
  private var host: EntryHost?

  override func tearDown() async throws {
    for window in windows {
      window.contentView = nil
      window.close()
    }
    windows = []
    host?.close()
    host = nil
  }

  private func settle(_ seconds: TimeInterval = 0.3) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
  }

  private func textFields(in view: NSView) -> [NSTextField] {
    view.subviews.flatMap { subview -> [NSTextField] in
      ((subview as? NSTextField).map { [$0] } ?? []) + textFields(in: subview)
    }
  }

  private var noteFirst: [EntryField] {
    EntryFieldOrder.moving(
      EntryFieldOrder.standard, from: IndexSet(integer: EntryField.allCases.firstIndex(of: .note)!),
      to: 0)
  }

  /// Where a field stands in the window, top down: the larger, the lower.
  private func top(of field: NSView, in window: NSWindow) -> CGFloat {
    let frame = field.convert(field.bounds, to: nil)
    return window.contentLayoutRect.height - frame.maxY
  }

  private func panel(_ environment: AppEnvironment) -> (NSWindow, EntryDraftModel) {
    let deps = AppDependencies(
      environment: environment, store: TransactionsStore(),
      compute: ComputeStore(calendar: .system))
    let model = EntryDraftModel(references: nil, transactions: nil, calendar: .utc)
    let window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: 760, height: 900), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(rootView: DetailsPanel(model: model).appDependencies(deps))
    window.makeKeyAndOrderFront(nil)
    windows.append(window)
    settle()
    return (window, model)
  }

  func testThePanelLaysItsFieldsInTheChosenOrder() throws {
    let environment = AppEnvironment()
    let noteTitle = environment.language("entry.note", table: "Entry")
    let (window, _) = panel(environment)
    let content = try XCTUnwrap(window.contentView)
    let amount = try XCTUnwrap(textFields(in: content).first { $0.placeholderString == "0" })
    let note = try XCTUnwrap(textFields(in: content).first { $0.placeholderString == noteTitle })
    XCTAssertLessThan(top(of: amount, in: window), top(of: note, in: window), "1.1: amount first")

    // Moved in Settings: the open panel lays itself again at once.
    environment.entryFieldOrder = noteFirst
    settle()
    let movedAmount = try XCTUnwrap(textFields(in: content).first { $0.placeholderString == "0" })
    let movedNote = try XCTUnwrap(
      textFields(in: content).first { $0.placeholderString == noteTitle })
    XCTAssertLessThan(
      top(of: movedNote, in: window), top(of: movedAmount, in: window), "the note is first now")
  }

  func testTabInTheLineGoesToTheFirstFieldOfTheOrder() async throws {
    let host = try await EntryHost()
    self.host = host
    let line = try host.line()
    // The order of 1.1: the amount first.
    XCTAssertTrue(host.window.makeFirstResponder(line))
    host.settle(0.1)
    try XCTUnwrap(host.window.firstResponder as? NSTextView).keyDown(
      with: EntryHost.key("\t", code: 48))
    host.settle()
    XCTAssertEqual(
      ((host.window.firstResponder as? NSTextView)?.delegate as? NSTextField)?.placeholderString,
      "0", "Tab went to the amount")

    // The note moved first in Settings: Tab goes there.
    host.environment.entryFieldOrder = noteFirst
    host.settle()
    let noteTitle = host.environment.language("entry.note", table: "Entry")
    let note = try host.field(prompt: noteTitle)
    XCTAssertTrue(host.window.makeFirstResponder(line))
    host.settle(0.1)
    // The key as the line's editor receives it: the window of a test host is not always made
    // key, and a key window is what hands a key press on to its first responder.
    let editor = try XCTUnwrap(host.window.firstResponder as? NSTextView, "the line's editor")
    editor.keyDown(with: EntryHost.key("\t", code: 48))
    host.settle()
    let focused = (host.window.firstResponder as? NSTextView)?.delegate as? NSTextField
    XCTAssertTrue(
      focused === note, "Tab went to «\(focused?.placeholderString ?? "?")»")

    // Shift-Tab: the last field of the order that takes the focus.
    XCTAssertTrue(host.window.makeFirstResponder(line))
    host.settle(0.1)
    let again = try XCTUnwrap(host.window.firstResponder as? NSTextView)
    again.keyDown(with: EntryHost.key("\u{19}", code: 48, modifiers: .shift))
    host.settle()
    let last = host.window.firstResponder
    XCTAssertFalse(
      ((last as? NSTextView)?.delegate as? NSTextField) === line, "Shift-Tab left the line")
  }

  /// The panel asked to focus the first field of the order puts the keyboard there: the note,
  /// when the owner moved it first.
  func testAFocusRequestPutsTheFocusOnTheFirstFieldOfTheOrder() throws {
    let environment = AppEnvironment()
    environment.entryFieldOrder = noteFirst
    let (window, model) = panel(environment)
    let noteTitle = environment.language("entry.note", table: "Entry")
    let note = try XCTUnwrap(
      textFields(in: try XCTUnwrap(window.contentView)).first { $0.placeholderString == noteTitle })
    model.focusRequest = .first
    settle()
    let focused = (window.firstResponder as? NSTextView)?.delegate as? NSTextField
    XCTAssertTrue(focused === note, "the focus is on «\(focused?.placeholderString ?? "?")»")
    XCTAssertNil(model.focusRequest, "the request is taken")

    // Asked for the amount by name, whatever the order.
    model.focusRequest = .control(.amount)
    settle()
    let amount = (window.firstResponder as? NSTextView)?.delegate as? NSTextField
    XCTAssertEqual(amount?.placeholderString, "0")
  }

  /// «Кэшбэк» moved first: the panel asked for the first field of the order puts the keyboard in
  /// its text field — the field, not the row around it with its caption and its buttons.
  func testAFocusRequestReachesTheCashbackFieldFirstInTheOrder() throws {
    let environment = AppEnvironment()
    environment.entryFieldOrder = EntryFieldOrder.moving(
      EntryFieldOrder.standard,
      from: IndexSet(integer: EntryFieldOrder.standard.firstIndex(of: .cashback)!), to: 0)
    let (window, model) = panel(environment)
    XCTAssertTrue(model.showsCashback, "a purchase shows «Кэшбэк»")
    let cashback = try XCTUnwrap(
      textFields(in: try XCTUnwrap(window.contentView)).first { $0.placeholderString == "—" },
      "the field of «Кэшбэк»")
    model.focusRequest = .first
    settle()
    let focused = (window.firstResponder as? NSTextView)?.delegate as? NSTextField
    XCTAssertTrue(
      focused === cashback, "the focus is on «\(focused?.placeholderString ?? "nothing")»")
    XCTAssertNil(model.focusRequest, "the request is taken")
  }

  /// Without «Навигация с клавиатуры» Tab stops at text fields only: the first of the order is
  /// the amount when the order starts with the category; with it on, the category menu itself.
  func testTabWithoutKeyboardNavigationSkipsToTheFirstTextField() {
    let categoryFirst = EntryFieldOrder.moving(
      EntryFieldOrder.standard, from: IndexSet(integer: 1), to: 0)
    let shown: Set<PanelFocus> = [
      .amount, .category, .subcategory, .quality, .forWhom, .forPerson, .place, .event, .account,
      .note, .date, .currency,
    ]
    XCTAssertEqual(
      PanelTabOrder.first(order: categoryFirst, shown: shown, fullKeyboardAccess: false), .amount)
    XCTAssertEqual(
      PanelTabOrder.first(order: categoryFirst, shown: shown, fullKeyboardAccess: true), .category)
    XCTAssertEqual(
      PanelTabOrder.last(order: EntryFieldOrder.standard, shown: shown, fullKeyboardAccess: false),
      .date)
    XCTAssertEqual(
      PanelTabOrder.last(order: EntryFieldOrder.standard, shown: shown, fullKeyboardAccess: true),
      .currency)
    // A control asked by name that Tab cannot reach stays unfocused: the mark shows it.
    XCTAssertNil(
      PanelTabOrder.resolve(
        .control(.category), order: categoryFirst, shown: shown, fullKeyboardAccess: false))
  }

  /// The quality, the goal and the cashback have a place in the order even when the kind has
  /// none of them: a field not shown is skipped, wherever it stands.
  func testAFieldTheKindHasNotIsSkipped() {
    let shown: Set<PanelFocus> = [.amount, .account, .note, .date, .currency]
    let stops = PanelTabOrder.stops(
      order: EntryFieldOrder.standard, shown: shown, fullKeyboardAccess: true)
    XCTAssertEqual(stops, [.amount, .account, .note, .date, .currency])
  }
}
