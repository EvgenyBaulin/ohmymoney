import AppCore
import AppDatabase
import AppKit
import SwiftUI
import XCTest

@testable import OhMyMoney

/// The entry bar in a window of its own over an in-memory database, the way the main window
/// shows it: for the tests of what Return, Tab and Enter do in the line and in the ↓ panel.
@MainActor
final class EntryHost {
  let environment: AppEnvironment
  let store: TransactionsStore
  let window: NSWindow
  private let directory: URL

  /// `prepare` writes what the book holds before the bar appears.
  init(
    opensDetails: Bool = true, width: CGFloat = 900, style: EntryStyle = .line,
    prepare: (AppEnvironment) throws -> Void = { _ in }
  ) async throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("entry-host-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    setenv("OHMYMONEY_DATA_DIR", directory.path, 1)
    environment = AppEnvironment()
    await environment.start(preparing: {
      try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    })
    try prepare(environment)
    store = TransactionsStore()
    store.attach(
      try XCTUnwrap(environment.transactions), references: try XCTUnwrap(environment.references),
      planning: try XCTUnwrap(environment.planning))
    let deps = AppDependencies(
      environment: environment, store: store, compute: ComputeStore(calendar: .system))
    window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: width, height: 900), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(
      rootView: EntryBar(
        windowWidth: width, detailWidth: width, style: style, opensDetails: opensDetails
      ) {
        EmptyView()
      }
      .appDependencies(deps))
    window.makeKeyAndOrderFront(nil)
    settle()
  }

  func close() {
    window.contentView = nil
    window.close()
    unsetenv("OHMYMONEY_DATA_DIR")
    try? FileManager.default.removeItem(at: directory)
  }

  var transactions: TransactionRepository { environment.transactions! }
  var references: ReferenceRepository { environment.references! }
  var planning: PlanningRepository { environment.planning! }

  func settle(_ seconds: TimeInterval = 0.3) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
  }

  /// Settles until the condition holds, up to `timeout` seconds: a slow Mac (a runner of CI) opens
  /// the panel later than a fixed pause.
  @discardableResult
  func settle(until condition: () -> Bool, timeout: TimeInterval = 10) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline { settle(0.05) }
    return condition()
  }

  /// Whether the ↓ panel is open: its amount field is on screen.
  var panelIsOpen: Bool { textFields().contains { $0.placeholderString == "0" } }

  func textFields(in view: NSView? = nil) -> [NSTextField] {
    guard let view = view ?? window.contentView else { return [] }
    return view.subviews.flatMap { subview -> [NSTextField] in
      ((subview as? NSTextField).map { [$0] } ?? []) + textFields(in: subview)
    }
  }

  func views<V: NSView>(of type: V.Type, in view: NSView? = nil) -> [V] {
    guard let view = view ?? window.contentView else { return [] }
    return view.subviews.flatMap { subview -> [V] in
      ((subview as? V).map { [$0] } ?? []) + views(of: type, in: subview)
    }
  }

  /// The line, told by its prompt.
  func line() throws -> NSTextField {
    let prompt = environment.language("entry.placeholder", table: "Entry")
    return try XCTUnwrap(textFields().first { $0.placeholderString == prompt }, "the line")
  }

  /// A field of the panel, told by its prompt: «0» is the amount.
  func field(prompt: String) throws -> NSTextField {
    try XCTUnwrap(textFields().first { $0.placeholderString == prompt }, "the field «\(prompt)»")
  }

  /// Types into a field as the keyboard would, leaving it the first responder.
  @discardableResult
  func type(_ text: String, into field: NSTextField) throws -> NSTextView {
    XCTAssertTrue(window.makeFirstResponder(field))
    let editor = try XCTUnwrap(window.firstResponder as? NSTextView, "the field editor")
    editor.insertText(text, replacementRange: editor.selectedRange())
    settle(0.1)
    return editor
  }

  /// Return pressed where the focus is: the first responder's own keystroke.
  func pressReturn() {
    if let editor = window.firstResponder as? NSTextView {
      editor.insertNewline(nil)
    } else {
      _ = window.performKeyEquivalent(with: Self.key("\r", code: 36))
    }
    settle()
  }

  /// Return as the window's key equivalent: what reaches the default button.
  func returnAsKeyEquivalent() -> Bool {
    window.performKeyEquivalent(with: Self.key("\r", code: 36))
  }

  /// A key as the window hands a key press to the line: the line's own handler of keys
  /// (`onKeyPress`) is reached this way, not through the field editor's `keyDown`. The focus is
  /// put on the line first.
  func pressKey(
    _ characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags = []
  ) throws {
    XCTAssertTrue(window.makeFirstResponder(try line()))
    window.sendEvent(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
        windowNumber: window.windowNumber, context: nil, characters: characters,
        charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!)
    settle()
  }

  /// ↓ in the line.
  func pressDown() throws {
    try pressKey(
      String(UnicodeScalar(NSDownArrowFunctionKey)!), code: 125,
      modifiers: [.function, .numericPad])
  }

  static func key(
    _ characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags = []
  )
    -> NSEvent
  {
    NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0,
      context: nil, characters: characters, charactersIgnoringModifiers: characters,
      isARepeat: false, keyCode: code)!
  }

  /// A category, and one operation described `words` filed in it: history files the next line
  /// of those words there at once, and Enter does not stop to ask for a category.
  @discardableResult
  static func history(_ words: String, in environment: AppEnvironment) throws -> CoreKit.Category {
    let category = CoreKit.Category(kind: .expense, name: "Cafe", quality: .neutral)
    try environment.references!.save(category)
    var earlier = TransactionDraft(amount: AmountE4(whole: 100), note: words)
    earlier.normalizeSinglePart()
    earlier.parts[0].categoryId = category.id
    try environment.transactions!.save(try earlier.materialize())
    return category
  }
}

/// Return in the open ↓ panel saves wherever the focus is, and one keystroke is one save:
/// AppKit may hand one Return to a text field's action and to the default button both, and a
/// held Return repeats.
@MainActor
final class EntryReturnTests: XCTestCase {
  private var host: EntryHost?

  override func tearDown() async throws {
    host?.close()
    host = nil
  }

  // MARK: The gate

  func testTheSameKeystrokeTwiceSavesOnce() {
    var gate = EntrySaving.ReturnGate()
    XCTAssertTrue(gate.admits(now: 10.000, isRepeat: false))
    XCTAssertFalse(gate.admits(now: 10.020, isRepeat: false))
  }

  func testAHeldReturnDoesNotSaveAgain() {
    var gate = EntrySaving.ReturnGate()
    XCTAssertTrue(gate.admits(now: 10, isRepeat: false))
    XCTAssertFalse(gate.admits(now: 11, isRepeat: true))
  }

  func testTwoKeystrokesSaveTwice() {
    var gate = EntrySaving.ReturnGate()
    XCTAssertTrue(gate.admits(now: 10.000, isRepeat: false))
    XCTAssertTrue(gate.admits(now: 10.400, isRepeat: false))
  }

  /// A click on «Save» and a save asked by code are no repeat: they pass, the first as any.
  func testAClickIsAdmitted() {
    var gate = EntrySaving.ReturnGate()
    XCTAssertTrue(gate.admits(now: 5, isRepeat: false))
    XCTAssertFalse(gate.admits(now: 6, isRepeat: true))
    XCTAssertTrue(gate.admits(now: 7, isRepeat: false))
  }

  // MARK: In the window

  /// The panel alone: an amount typed, the focus on the date, Return — the operation is saved
  /// (after the stop for the category the panel does not have yet, and the choice of one).
  func testReturnOnTheDatePickerSavesThePanel() async throws {
    let host = try await EntryHost()
    self.host = host
    try host.type("250", into: try host.field(prompt: "0"))
    let picker = try XCTUnwrap(host.views(of: NSDatePicker.self).first, "the date of the panel")
    XCTAssertTrue(host.window.makeFirstResponder(picker))
    host.settle(0.1)

    XCTAssertTrue(host.returnAsKeyEquivalent(), "Return reached «Save»")
    host.settle()
    XCTAssertEqual(try host.transactions.count(), 0, "the first Return asks for the category")
    host.settle(0.3)
    try host.pressDown()
    if !(host.window.firstResponder is NSDatePicker) {
      XCTAssertTrue(host.window.makeFirstResponder(picker))
    }
    XCTAssertTrue(host.returnAsKeyEquivalent(), "Return reached «Save»")
    host.settle()
    XCTAssertEqual(try host.transactions.count(), 1, "the next Return saved the panel")
  }

  /// One Return handed to the line's own action and to the default button at once saves one
  /// operation, one step of ⌘Z.
  func testOneReturnInTheLineSavesOnce() async throws {
    let host = try await EntryHost { try EntryHost.history("coffee", in: $0) }
    self.host = host
    let editor = try host.type("coffee 250", into: try host.line())
    editor.insertNewline(nil)
    _ = host.returnAsKeyEquivalent()
    host.settle()

    let saved = try host.transactions.recentEntries(limit: 10)
      .filter { $0.transaction.amountE4 == AmountE4(whole: 250) }
    XCTAssertEqual(saved.count, 1)
    XCTAssertTrue(host.store.canUndo)
    host.store.undo()
    host.settle()
    XCTAssertEqual(
      try host.transactions.recentEntries(limit: 10)
        .filter { $0.transaction.amountE4 == AmountE4(whole: 250) }.count, 0)
    XCTAssertFalse(host.store.canUndo, "one step, and nothing after it")
  }

  /// A line that does not tell its category stops to ask for it. One Return handed to the
  /// line's own action and to the default button at once is that one stop, not the stop and
  /// then a save; once the category is chosen the next keystroke saves.
  func testOneReturnOnALineThatStopsForItsCategoryDoesNotSaveAtOnce() async throws {
    let host = try await EntryHost()
    self.host = host
    let editor = try host.type("coffee 250", into: try host.line())
    editor.insertNewline(nil)
    _ = host.returnAsKeyEquivalent()
    host.settle()
    XCTAssertEqual(try host.transactions.count(), 0, "the stop for the category holds")

    host.settle(0.3)
    try host.pressDown()
    try XCTUnwrap(host.window.firstResponder as? NSTextView).insertNewline(nil)
    host.settle()
    XCTAssertEqual(try host.transactions.count(), 1, "the next Return saves")
  }

  /// The amount typed in the open panel, the words in the line: Return in the line saves the
  /// amount the panel shows instead of asking for one.
  func testALineOfWordsSavesWithTheAmountOfThePanel() async throws {
    let host = try await EntryHost { try EntryHost.history("coffee", in: $0) }
    self.host = host
    try host.type("250", into: try host.field(prompt: "0"))
    let editor = try host.type("coffee", into: try host.line())
    editor.insertNewline(nil)
    host.settle()
    let saved = try host.transactions.recentEntries(limit: 5)
      .filter { $0.transaction.note == "coffee" && $0.transaction.amountE4 != AmountE4(whole: 100) }
    XCTAssertEqual(saved.count, 1, "the line saved the amount of the panel")
    XCTAssertEqual(saved.first?.transaction.amountE4, AmountE4(whole: 250))
  }

  /// A number in the line that does not read is still refused: the panel's amount does not
  /// stand in for it.
  func testALineWithANumberThatDoesNotReadIsRefusedWhateverThePanelHolds() async throws {
    let host = try await EntryHost { try EntryHost.history("coffee", in: $0) }
    self.host = host
    try host.type("250", into: try host.field(prompt: "0"))
    let editor = try host.type("coffee 3000÷0", into: try host.line())
    editor.insertNewline(nil)
    host.settle()
    XCTAssertEqual(try host.transactions.count(), 1, "only the operation of the history")
  }
}
