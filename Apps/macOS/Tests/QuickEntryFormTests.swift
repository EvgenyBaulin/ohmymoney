import AppCore
import AppDatabase
import AppKit
import XCTest

@testable import OhMyMoney

/// The quick line of the form at the side of the main window, in a window: ⌘N puts the keyboard
/// in it, the first Return shows «Будет записано» and writes nothing, the second writes through
/// the usual save with its questions, «Изменить» leaves what was read in the fields, Esc throws
/// the line away, and the templates under it put their line in it.
@MainActor
final class QuickEntryFormTests: XCTestCase {
  private var host: EntryHost?
  private let cafe = CoreKit.Category(kind: .expense, name: "Cafe", quality: .neutral)

  override func tearDown() async throws {
    host?.close()
    host = nil
  }

  private func openForm(
    prepare: @escaping (AppEnvironment) throws -> Void = { _ in }
  )
    async throws -> EntryHost
  {
    let cafe = cafe
    let host = try await EntryHost(opensDetails: false, style: .form) { environment in
      try environment.references!.save(cafe)
      try prepare(environment)
    }
    self.host = host
    return host
  }

  private func quickLine(of host: EntryHost) throws -> NSTextField {
    try host.field(prompt: host.environment.language("entry.quick.prompt", table: "Entry"))
  }

  /// Return in the quick line, as the keyboard gives it to the line's editor.
  private func returnInTheQuickLine(of host: EntryHost) throws {
    let line = try quickLine(of: host)
    if ((host.window.firstResponder as? NSTextView)?.delegate as? NSTextField) !== line {
      XCTAssertTrue(host.window.makeFirstResponder(line))
      host.settle(0.1)
    }
    try XCTUnwrap(host.window.firstResponder as? NSTextView, "the quick line's editor")
      .insertNewline(nil)
    host.settle()
  }

  private func summary(of host: EntryHost) -> String? {
    WindowAccessibility.element(identified: "entry.quick.summary", in: host.window)
      .map(WindowAccessibility.text(of:))
  }

  // MARK: Without an assistive client

  /// ⌘N in the form puts the keyboard in the quick line.
  func testANewOperationPutsTheKeyboardInTheQuickLine() async throws {
    let host = try await openForm()
    let line = try quickLine(of: host)
    // A line read into the fields, and the keyboard in one of them.
    try host.type("кофе 300", into: line)
    try returnInTheQuickLine(of: host)
    XCTAssertTrue(host.window.makeFirstResponder(try host.field(prompt: "0")))
    NotificationCenter.default.post(name: .focusEntryLine, object: nil)
    // SwiftUI moves the keyboard from a task of the main actor (`DetailsPanel`'s focus request):
    // waited for by suspending, up to two seconds. A run loop spun inside this test alone never
    // lets that task run — the test holds the main actor — and the focus seemed not to land.
    var focused: NSTextField?
    let deadline = Date().addingTimeInterval(2)
    repeat {
      try await Task.sleep(for: .milliseconds(50))
      host.settle(0.05)
      focused = (host.window.firstResponder as? NSTextView)?.delegate as? NSTextField
    } while focused !== line && Date() < deadline
    XCTAssertTrue(focused === line, "⌘N went to «\(focused?.placeholderString ?? "?")»")
  }

  /// The first Return writes nothing: what the line says stands in the fields below for the card
  /// to show.
  func testTheFirstReturnWritesNothingAndFillsTheFields() async throws {
    let host = try await openForm()
    try host.type("кофе 300", into: try quickLine(of: host))
    try returnInTheQuickLine(of: host)
    XCTAssertEqual(try host.transactions.count(), 0, "the first Return only shows")
    XCTAssertEqual(try quickLine(of: host).stringValue, "кофе 300", "the line stays")
    XCTAssertTrue(try host.field(prompt: "0").stringValue.hasPrefix("300"))
    let note = host.environment.language("entry.note", table: "Entry")
    XCTAssertEqual(try host.field(prompt: note).stringValue, "кофе")
  }

  /// The quick line reads as the entry line does: an operation written before with the same
  /// words brings its category, so the card says where the money goes.
  func testTheQuickLineTakesTheCategoryFromHistory() async throws {
    let cafe = cafe
    let host = try await openForm { environment in
      var draft = TransactionDraft(
        kind: .expense, occurredAt: Date().addingTimeInterval(-86_400),
        amount: AmountE4(whole: 250), note: "кофе")
      draft.normalizeSinglePart()
      draft.parts[0].categoryId = cafe.id
      _ = try environment.transactions!.save(try draft.materialize())
    }
    try host.type("кофе 300", into: try quickLine(of: host))
    try returnInTheQuickLine(of: host)
    try returnInTheQuickLine(of: host)
    let saved = try host.transactions.recentEntries(limit: 5)
    XCTAssertEqual(saved.count, 2, "the second Return wrote, the category came from history")
    XCTAssertEqual(
      saved.first { $0.transaction.amountE4 == AmountE4(whole: 300) }?.parts.first?.categoryId,
      cafe.id)
  }

  /// A line with words the app does not know: the second Return is the usual save, and the usual
  /// save does not write an operation without a category.
  func testALineWithoutACategoryIsNotWrittenByTheSecondReturn() async throws {
    let host = try await openForm()
    try host.type("абв 250", into: try quickLine(of: host))
    try returnInTheQuickLine(of: host)
    try returnInTheQuickLine(of: host)
    XCTAssertEqual(try host.transactions.count(), 0, "no category, nothing written")
    try returnInTheQuickLine(of: host)
    XCTAssertEqual(try host.transactions.count(), 0, "asked until one is chosen")
  }

  /// Esc after the card: the line is thrown away and nothing is written.
  func testEscThrowsTheLineAway() async throws {
    let host = try await openForm()
    try host.type("обед 600", into: try quickLine(of: host))
    try returnInTheQuickLine(of: host)
    let editor = try XCTUnwrap(host.window.firstResponder as? NSTextView)
    editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
    host.settle()
    XCTAssertEqual(try quickLine(of: host).stringValue, "", "the line is cleared")
    XCTAssertEqual(try host.transactions.count(), 0, "nothing written")
  }

  /// An unreadable line is refused at the first Return, without a card.
  func testALineWithoutAnAmountIsRefused() async throws {
    let host = try await openForm()
    try host.type("кофе", into: try quickLine(of: host))
    try returnInTheQuickLine(of: host)
    try returnInTheQuickLine(of: host)
    XCTAssertEqual(try host.transactions.count(), 0)
    XCTAssertEqual(try quickLine(of: host).stringValue, "кофе", "the line is kept to correct")
  }

  // MARK: With an assistive client

  /// The card says what will be written — the words, the amount, the account, the day — and,
  /// without a category, that none is chosen; once the category is chosen in the form below,
  /// Return writes the operation and the line is cleared.
  func testTheCardSaysWhatWillBeWrittenAndTheNextReturnWrites() async throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    let host = try await openForm()
    XCTAssertNil(summary(of: host), "no card before Return")
    try host.type("кофе 300", into: try quickLine(of: host))
    try returnInTheQuickLine(of: host)
    let card = try XCTUnwrap(summary(of: host), "the card «Будет записано»")
    XCTAssertTrue(card.hasPrefix("кофе, "), card)
    XCTAssertTrue(card.contains("300"), card)
    XCTAssertTrue(
      card.contains(host.environment.language("entry.quick.noCategory", table: "Entry")), card)
    XCTAssertNotNil(WindowAccessibility.element(identified: "entry.quick.write", in: host.window))
    XCTAssertEqual(try host.transactions.count(), 0)

    try WindowAccessibility.choose("Cafe", inMenu: "entry.category", of: host.window)
    host.settle()
    try returnInTheQuickLine(of: host)
    let saved = try host.transactions.recentEntries(limit: 5)
    XCTAssertEqual(saved.count, 1, "the second Return wrote")
    XCTAssertEqual(saved.first?.transaction.amountE4, AmountE4(whole: 300))
    XCTAssertEqual(saved.first?.transaction.note, "кофе")
    XCTAssertEqual(saved.first?.parts.first?.categoryId, cafe.id)
    XCTAssertEqual(try quickLine(of: host).stringValue, "", "the line is cleared")
    XCTAssertNil(summary(of: host), "and the card is gone")
  }

  /// «Записать» on the card is the second Return.
  func testWriteOnTheCardWrites() async throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    let host = try await openForm()
    // The fields open with a kind chosen.
    WindowAccessibility.press(
      try XCTUnwrap(WindowAccessibility.element(identified: "entry.kind.expense", in: host.window)))
    host.settle()
    try WindowAccessibility.choose("Cafe", inMenu: "entry.category", of: host.window)
    try host.type("кофе 300", into: try quickLine(of: host))
    try returnInTheQuickLine(of: host)
    let write = try XCTUnwrap(
      WindowAccessibility.element(identified: "entry.quick.write", in: host.window))
    WindowAccessibility.press(write)
    host.settle()
    XCTAssertEqual(try host.transactions.count(), 1)
  }

  /// «Изменить»: the card goes, nothing is written, the amount and the words stand in the fields
  /// of the form; «Очистить» empties them.
  func testChangeLeavesTheLineInTheFields() async throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    let host = try await openForm()
    try host.type("такси 450", into: try quickLine(of: host))
    try returnInTheQuickLine(of: host)
    let change = try XCTUnwrap(
      WindowAccessibility.element(identified: "entry.quick.change", in: host.window))
    WindowAccessibility.press(change)
    host.settle()
    XCTAssertNil(summary(of: host), "the card is gone")
    XCTAssertEqual(try host.transactions.count(), 0)
    let amount = try host.field(prompt: "0")
    XCTAssertTrue(amount.stringValue.hasPrefix("450"), amount.stringValue)
    let note = host.environment.language("entry.note", table: "Entry")
    XCTAssertEqual(try host.field(prompt: note).stringValue, "такси")

    let clear = try XCTUnwrap(
      WindowAccessibility.element(identified: "entry.form.clear", in: host.window))
    WindowAccessibility.press(clear)
    host.settle()
    XCTAssertNil(
      host.textFields().first { $0.placeholderString == "0" }, "back at the kinds, fields empty")
    WindowAccessibility.press(
      try XCTUnwrap(WindowAccessibility.element(identified: "entry.kind.expense", in: host.window)))
    host.settle()
    XCTAssertEqual(try host.field(prompt: "0").stringValue, "")
  }

  /// A template under the quick line puts its line in it.
  func testATemplateUnderTheLinePutsItsLineInIt() async throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    let cafe = cafe
    let host = try await openForm { environment in
      try environment.references!.save(
        Template(text: "кофе", categoryId: cafe.id, amountE4: AmountE4(whole: 250)))
    }
    let chip = try XCTUnwrap(
      WindowAccessibility.elements(in: host.window).first {
        WindowAccessibility.text(of: $0) == "кофе"
          && WindowAccessibility.attribute($0, "accessibilityRole") as? String == "AXButton"
      }, "the template under the quick line")
    WindowAccessibility.press(chip)
    host.settle()
    let line = try quickLine(of: host).stringValue
    XCTAssertTrue(line.contains("кофе") && line.contains("250"), line)
  }
}
