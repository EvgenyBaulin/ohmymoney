import AppCore
import AppKit
import SwiftUI
import XCTest

@testable import OhMyMoney

/// ↓ in the entry line walks the list of operations from the newest row: the list selects it and
/// takes the keyboard; ↑ on that row, and Esc, give the keyboard back to the line.
@MainActor
final class OperationsWalkTests: XCTestCase {
  private func entry(_ note: String) throws -> TransactionEntry {
    var draft = TransactionDraft(amount: AmountE4(whole: 10), note: note)
    draft.normalizeSinglePart()
    return try draft.materialize()
  }

  private func transfer() -> Transfer {
    Transfer(
      occurredAt: Date(), fromAccountId: UUID(), fromCurrency: .rub,
      fromAmountE4: AmountE4(whole: 5), toAccountId: UUID(), toCurrency: .rub,
      toAmountE4: AmountE4(whole: 5))
  }

  func testTheWalkStartsOnTheNewestRow() throws {
    let newest = try entry("newest")
    let days: [[DayItem]] = [
      [.operation(newest), .operation(try entry("older"))], [.operation(try entry("oldest"))],
    ]
    XCTAssertEqual(OperationsWalk.firstRow(of: days), newest.id)
  }

  func testATransferMayBeTheNewestRow() throws {
    let moved = transfer()
    XCTAssertEqual(OperationsWalk.firstRow(of: [[.transfer(moved)]]), moved.id)
  }

  func testADayWithoutRowsIsSkippedAndAnEmptyListHasNone() throws {
    let first = try entry("first")
    XCTAssertEqual(OperationsWalk.firstRow(of: [[], [.operation(first)]]), first.id)
    XCTAssertNil(OperationsWalk.firstRow(of: []))
    XCTAssertNil(OperationsWalk.firstRow(of: [[]]))
  }

  /// ↑ goes back to the line only from the newest row alone: from any other row it is the
  /// list's own arrow, and with several rows selected it is not a walk.
  func testUpGoesBackToTheLineOnlyFromTheNewestRow() {
    let first = UUID()
    let second = UUID()
    XCTAssertTrue(OperationsWalk.returnsToTheLine(selection: [first], firstRow: first))
    XCTAssertFalse(OperationsWalk.returnsToTheLine(selection: [second], firstRow: first))
    XCTAssertFalse(OperationsWalk.returnsToTheLine(selection: [first, second], firstRow: first))
    XCTAssertFalse(OperationsWalk.returnsToTheLine(selection: [], firstRow: first))
    XCTAssertFalse(OperationsWalk.returnsToTheLine(selection: [first], firstRow: nil))
  }

  private final class Chosen: @unchecked Sendable {
    var selection: Set<UUID> = []
  }

  private struct Probe: View {
    let rows: [UUID]
    let chosen: Chosen
    @State private var selection: Set<UUID> = []

    var body: some View {
      List(rows, id: \.self, selection: $selection) { Text(verbatim: $0.uuidString) }
        .walkedFromTheEntryLine(firstRow: rows.first, selection: $selection)
        .onChange(of: selection) { _, new in chosen.selection = new }
    }
  }

  /// The list that wears the modifier answers the walk by selecting its newest row.
  func testTheListAnswersTheWalkBySelectingItsNewestRow() throws {
    let rows = [UUID(), UUID(), UUID()]
    let chosen = Chosen()
    let window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    // dependencies: none — the list under test reads nothing of the environment.
    window.contentView = NSHostingView(rootView: Probe(rows: rows, chosen: chosen))
    window.makeKeyAndOrderFront(nil)
    defer {
      window.contentView = nil
      window.close()
    }
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    NotificationCenter.default.post(name: .walkOperationsList, object: nil)
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    XCTAssertEqual(chosen.selection, [rows[0]])
  }

  /// A list with no rows has nothing to land on: the walk changes nothing.
  func testAnEmptyListIgnoresTheWalk() throws {
    let chosen = Chosen()
    let window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    // dependencies: none — the list under test reads nothing of the environment.
    window.contentView = NSHostingView(rootView: Probe(rows: [], chosen: chosen))
    window.makeKeyAndOrderFront(nil)
    defer {
      window.contentView = nil
      window.close()
    }
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    NotificationCenter.default.post(name: .walkOperationsList, object: nil)
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    XCTAssertTrue(chosen.selection.isEmpty)
  }
}

/// In the window: what ↓ and Tab do in the entry line.
@MainActor
final class EntryWalkTests: XCTestCase {
  private var host: EntryHost?

  override func tearDown() async throws {
    host?.close()
    host = nil
  }

  private final class Count: @unchecked Sendable {
    var value = 0
  }

  /// ↓ opens no panel any more: it asks the list to walk, and the panel stays as it was.
  func testDownAsksTheListToWalkAndOpensNothing() async throws {
    let host = try await EntryHost(opensDetails: false)
    self.host = host
    let asked = Count()
    let token = NotificationCenter.default.addObserver(
      forName: .walkOperationsList, object: nil, queue: nil
    ) { _ in asked.value += 1 }
    defer { NotificationCenter.default.removeObserver(token) }

    try host.pressDown()
    XCTAssertEqual(asked.value, 1, "the list was asked to walk")
    XCTAssertNil(host.textFields().first { $0.placeholderString == "0" }, "no panel opened")
  }

  /// Tab opens a closed panel and goes to its first field.
  func testTabOpensTheClosedPanelOnItsFirstField() async throws {
    let host = try await EntryHost(opensDetails: false)
    self.host = host
    XCTAssertNil(host.textFields().first { $0.placeholderString == "0" }, "closed")
    try host.pressKey("\t", code: 48)
    // The panel asks for the focus in a task of the main actor, which runs while the test waits —
    // up to three seconds, since a busy machine takes longer than a fixed pause.
    func firstFieldHasTheKeyboard() -> Bool {
      ((host.window.firstResponder as? NSTextView)?.delegate as? NSTextField)?.placeholderString
        == "0"
    }
    let deadline = Date().addingTimeInterval(3)
    while !firstFieldHasTheKeyboard(), Date() < deadline {
      try await Task.sleep(for: .milliseconds(50))
      host.settle(0.05)
    }
    XCTAssertNotNil(host.textFields().first { $0.placeholderString == "0" }, "the panel opened")
    XCTAssertTrue(firstFieldHasTheKeyboard(), "Tab went to the amount")
  }

  /// Shift-Tab with the panel closed is not ours: nothing opens.
  func testShiftTabWithAClosedPanelOpensNothing() async throws {
    let host = try await EntryHost(opensDetails: false)
    self.host = host
    try host.pressKey("\u{19}", code: 48, modifiers: .shift)
    host.settle(0.3)
    XCTAssertNil(host.textFields().first { $0.placeholderString == "0" }, "no panel")
  }

  /// The keyboard comes back to the line when the list gives it back.
  func testTheLineTakesTheKeyboardBack() async throws {
    try TestEnvironment.requireActiveApp()
    let host = try await EntryHost(opensDetails: false)
    self.host = host
    // SwiftUI follows the keyboard of a window only while its app is the active one: the host of
    // the tests is not when something else of this Mac has the screen, and the keyboard then
    // stays where the test put it or comes back, as the timing falls. Nothing to check there.
    // SwiftUI moves the keyboard of a window only where it builds its accessibility tree: on
    // the runner of CI, whose screen has none, the line stayed without it with the app active and
    // its window key. And only in the active app.
    try TestEnvironment.requireSwiftUIAccessibility()
    try TestEnvironment.requireActiveApp()
    let line = try host.line()
    host.window.makeFirstResponder(nil)
    host.settle(0.1)
    NotificationCenter.default.post(name: .returnToEntryLine, object: nil)
    // The line asks for the focus in a task of the main actor: on a busy machine it takes longer
    // than a fixed pause, so the test waits for it, up to three seconds.
    func lineHasTheKeyboard() -> Bool {
      ((host.window.firstResponder as? NSTextView)?.delegate as? NSTextField) === line
    }
    // The app may have come to the front only a moment ago, while the window was still settling
    // as key; the list gives the keyboard back once more each second, up to ten seconds.
    let deadline = Date().addingTimeInterval(10)
    var asked = Date()
    while !lineHasTheKeyboard(), Date() < deadline {
      host.settle(0.05)
      if Date().timeIntervalSince(asked) > 1 {
        NotificationCenter.default.post(name: .returnToEntryLine, object: nil)
        asked = Date()
      }
    }
    XCTAssertTrue(
      lineHasTheKeyboard(),
      "the line has the keyboard (app active \(NSApp.isActive), window key \(host.window.isKeyWindow))"
    )
  }
}
