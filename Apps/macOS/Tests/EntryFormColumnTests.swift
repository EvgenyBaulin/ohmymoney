import AppCore
import AppDatabase
import AppKit
import XCTest

@testable import OhMyMoney

/// The form at the side of the main window, in a window: after a save every field — the date and
/// time too — starts over, and the fields wait until the kind of the next operation is chosen.
@MainActor
final class EntryFormColumnTests: XCTestCase {
  private var host: EntryHost?

  override func tearDown() async throws {
    host?.close()
    host = nil
  }

  private func openForm(
    prepare: @escaping (AppEnvironment) throws -> Void = { _ in }
  ) async throws -> EntryHost {
    let host = try await EntryHost(opensDetails: false, style: .form, prepare: prepare)
    self.host = host
    return host
  }

  private func quickLine(of host: EntryHost) throws -> NSTextField {
    try host.field(prompt: host.environment.language("entry.quick.prompt", table: "Entry"))
  }

  /// Waits by suspending, so the tasks of the main actor SwiftUI runs — a focus asked, a sheet —
  /// get their turn, as they do in the app.
  private func wait(_ seconds: Double = 0.4) async throws {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
      try await Task.sleep(for: .milliseconds(50))
      host?.settle(0.02)
    }
  }

  private func press(_ identifier: String, in host: EntryHost) async throws {
    let element = try XCTUnwrap(
      WindowAccessibility.element(identified: identifier, in: host.window), identifier)
    WindowAccessibility.press(element)
    try await wait()
  }

  /// A line the history files, read into the fields by the first Return of the quick line.
  private func readTheQuickLine(_ text: String, in host: EntryHost) async throws {
    let line = try quickLine(of: host)
    try host.type(text, into: line)
    try XCTUnwrap(host.window.firstResponder as? NSTextView).insertNewline(nil)
    try await wait()
  }

  // MARK: The date after a save

  /// A day and a time chosen in the form, the operation saved with the keyboard on the date: the
  /// operation is written on that moment, and the next one starts at now again.
  func testTheDateStartsOverAfterASaveFromTheDateField() async throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    let host = try await openForm { try EntryHost.history("кофе", in: $0) }
    try await readTheQuickLine("кофе 300", in: host)
    let picker = try XCTUnwrap(host.views(of: NSDatePicker.self).first, "the date of the form")
    XCTAssertTrue(host.window.makeFirstResponder(picker))
    let chosen = Date(
      timeIntervalSinceReferenceDate: (Date().addingTimeInterval(-2 * 86_400)
        .timeIntervalSinceReferenceDate / 60).rounded(.down)
        * 60)
    picker.dateValue = chosen
    _ = picker.sendAction(picker.action, to: picker.target)
    try await wait()

    try await press("entry.form.save", in: host)
    let saved = try host.transactions.recentEntries(limit: 5)
      .filter { $0.transaction.amountE4 == AmountE4(whole: 300) }
    XCTAssertEqual(saved.count, 1, "the operation was saved")
    XCTAssertEqual(
      saved.first?.transaction.occurredAt.timeIntervalSince1970 ?? 0,
      chosen.timeIntervalSince1970, accuracy: 1, "on the moment chosen")

    if host.views(of: NSDatePicker.self).isEmpty {
      try await press("entry.kind.expense", in: host)
    }
    let after = try XCTUnwrap(host.views(of: NSDatePicker.self).first, "the date again")
    XCTAssertEqual(
      after.dateValue.timeIntervalSinceNow, 0, accuracy: 120,
      "the next operation starts at now, not at the moment of the last one")
  }

  /// The same with Return, the keyboard on the date: Return reaches «Сохранить», the default
  /// button of the form while a field of it has the keyboard.
  func testTheDateStartsOverAfterReturnInTheDateField() async throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    let host = try await openForm { try EntryHost.history("кофе", in: $0) }
    try await readTheQuickLine("кофе 300", in: host)
    let picker = try XCTUnwrap(host.views(of: NSDatePicker.self).first, "the date of the form")
    XCTAssertTrue(host.window.makeFirstResponder(picker))
    let chosen = picker.dateValue.addingTimeInterval(-5 * 3600)
    picker.dateValue = chosen
    _ = picker.sendAction(picker.action, to: picker.target)
    try await wait()
    XCTAssertTrue(host.returnAsKeyEquivalent(), "Return reached «Сохранить»")
    try await wait()
    let saved = try host.transactions.recentEntries(limit: 5)
      .filter { $0.transaction.amountE4 == AmountE4(whole: 300) }
    XCTAssertEqual(saved.count, 1, "Return saved")
    XCTAssertEqual(
      saved.first?.transaction.occurredAt.timeIntervalSince1970 ?? 0,
      chosen.timeIntervalSince1970, accuracy: 60, "at the time chosen")
    try await wait()
    if host.views(of: NSDatePicker.self).isEmpty {
      try await press("entry.kind.expense", in: host)
    }
    let after = try XCTUnwrap(host.views(of: NSDatePicker.self).first, "the date again")
    XCTAssertEqual(
      after.dateValue.timeIntervalSinceNow, 0, accuracy: 120,
      "the next operation starts at now, not at the moment of the last one")
  }

  /// A day the quick line named, written by its second Return: the next operation starts today.
  func testTheDateStartsOverAfterTheQuickLineWrote() async throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    let host = try await openForm { try EntryHost.history("кофе", in: $0) }
    try await readTheQuickLine("кофе вчера 300", in: host)
    let picker = try XCTUnwrap(host.views(of: NSDatePicker.self).first, "the date of the form")
    XCTAssertTrue(host.window.makeFirstResponder(picker))
    picker.dateValue = picker.dateValue.addingTimeInterval(-3600)
    _ = picker.sendAction(picker.action, to: picker.target)
    try await wait()
    let line = try quickLine(of: host)
    XCTAssertTrue(host.window.makeFirstResponder(line))
    try await wait(0.2)
    try XCTUnwrap(host.window.firstResponder as? NSTextView).insertNewline(nil)
    try await wait()
    XCTAssertEqual(try host.transactions.count(), 2, "the second Return wrote")
    if host.views(of: NSDatePicker.self).isEmpty {
      try await press("entry.kind.expense", in: host)
    }
    let after = try XCTUnwrap(host.views(of: NSDatePicker.self).first, "the date again")
    XCTAssertEqual(after.dateValue.timeIntervalSinceNow, 0, accuracy: 120)
  }

  // MARK: The kinds first

  /// A fresh form shows the quick line and the kinds, and no field and no «Сохранить» until a
  /// kind is chosen; a tile brings them, lit.
  func testTheFormStartsWithTheKindsAlone() async throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    let host = try await openForm()
    XCTAssertNotNil(try? quickLine(of: host), "the quick line is there")
    XCTAssertNotNil(WindowAccessibility.element(identified: "entry.kind.expense", in: host.window))
    XCTAssertNil(host.textFields().first { $0.placeholderString == "0" }, "no amount yet")
    XCTAssertNil(
      WindowAccessibility.element(identified: "entry.form.save", in: host.window), "no «Save»")
    XCTAssertNotNil(
      WindowAccessibility.element(identified: "entry.form.chooseKind", in: host.window),
      "the form says what to do")

    try await press("entry.kind.income", in: host)
    XCTAssertNotNil(host.textFields().first { $0.placeholderString == "0" }, "the fields came")
    XCTAssertNotNil(WindowAccessibility.element(identified: "entry.form.save", in: host.window))
  }

  /// A save takes the form back to the kinds; the next tile brings fresh fields.
  func testASaveTakesTheFormBackToTheKinds() async throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    let cafe = CoreKit.Category(kind: .expense, name: "Cafe", quality: .neutral)
    let host = try await openForm { try $0.references!.save(cafe) }
    try await press("entry.kind.expense", in: host)
    try WindowAccessibility.choose("Cafe", inMenu: "entry.category", of: host.window)
    try host.type("250", into: try host.field(prompt: "0"))
    try await press("entry.form.save", in: host)
    XCTAssertEqual(try host.transactions.count(), 1)
    XCTAssertNil(host.textFields().first { $0.placeholderString == "0" }, "the fields went")
    XCTAssertNil(WindowAccessibility.element(identified: "entry.form.save", in: host.window))
    try await press("entry.kind.expense", in: host)
    XCTAssertEqual(try host.field(prompt: "0").stringValue, "", "and come back empty")
  }

  /// «Очистить» takes the form back to the kinds too.
  func testClearTakesTheFormBackToTheKinds() async throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    let host = try await openForm()
    try await press("entry.kind.expense", in: host)
    try host.type("250", into: try host.field(prompt: "0"))
    try await press("entry.form.clear", in: host)
    XCTAssertNil(host.textFields().first { $0.placeholderString == "0" })
  }

  // MARK: A place in the form

  /// The form takes nothing from history but the place: a place chosen there brings the category
  /// and the subcategory of the last operation at it.
  func testAPlaceChosenInTheFormBringsItsCategory() async throws {
    let cafe = CoreKit.Category(kind: .expense, name: "Cafe", quality: .neutral)
    let coffee = CoreKit.Category(
      parentId: cafe.id, kind: .expense, name: "Coffee", quality: .neutral)
    let shop = CoreKit.Category(kind: .expense, name: "Shop", quality: .neutral)
    let place = Place(name: "Кофейня")
    let host = try await openForm { environment in
      try environment.references!.save(cafe)
      try environment.references!.save(coffee)
      try environment.references!.save(shop)
      try environment.references!.save(place)
      var earlier = TransactionDraft(amount: AmountE4(whole: 180), note: "латте")
      earlier.placeId = place.id
      earlier.normalizeSinglePart()
      earlier.parts[0].categoryId = coffee.id
      try environment.transactions!.save(try earlier.materialize())
    }
    let model = EntryDraftModel(environment: host.environment)
    model.assisted = false
    model.reload()
    model.prepareForPanel(today: host.environment.today)
    XCTAssertNil(model.draft.parts[0].categoryId, "nothing from history before the place")

    model.setPlace(place.id, today: host.environment.today)
    XCTAssertEqual(model.draft.parts[0].categoryId, coffee.id, "the subcategory of last time")
    XCTAssertEqual(model.categoryOfPart(model.part(at: 0)), cafe.id, "under its category")

    // A category chosen by hand stays whatever place comes after it.
    model.setPlace(nil, today: host.environment.today)
    model.setCategory(shop.id, forPartAt: 0)
    model.setPlace(place.id, today: host.environment.today)
    XCTAssertEqual(model.draft.parts[0].categoryId, shop.id, "the owner's choice stays")
  }

  // MARK: A comment of several lines

  /// ⌥Return in the comment starts a new line; Return saves, the lines kept.
  func testOptionReturnInTheCommentStartsANewLine() async throws {
    let host = try await EntryHost { try EntryHost.history("coffee", in: $0) }
    self.host = host
    try host.type("coffee 250", into: try host.line())
    let noteTitle = host.environment.language("entry.note", table: "Entry")
    let note = try host.field(prompt: noteTitle)
    let editor = try host.type(" milk", into: note)
    editor.moveToEndOfDocument(nil)
    editor.insertNewlineIgnoringFieldEditor(nil)
    editor.insertText("oat", replacementRange: editor.selectedRange())
    host.settle(0.2)
    XCTAssertTrue(note.stringValue.contains("\n"), "a second line: \(note.stringValue)")
    XCTAssertEqual(try host.transactions.count(), 1, "⌥Return saves nothing")

    try XCTUnwrap(host.window.firstResponder as? NSTextView).insertNewline(nil)
    host.settle()
    let saved = try host.transactions.recentEntries(limit: 5)
      .filter { $0.transaction.amountE4 == AmountE4(whole: 250) }
    XCTAssertEqual(saved.count, 1, "Return saved")
    let written = try XCTUnwrap(saved.first?.transaction.note)
    XCTAssertEqual(written.split(separator: "\n").count, 2, "both lines kept: \(written)")
  }

  /// A row of a list reads a comment of several lines as one line.
  func testARowReadsACommentOfSeveralLinesAsOne() {
    XCTAssertEqual(
      RowTitle.resolve(note: "кофе\nс собой \n\n  латте", category: nil, kind: .expense),
      .note("кофе с собой латте"))
    XCTAssertEqual(RowTitle.resolve(note: "кофе", category: nil, kind: .expense), .note("кофе"))
  }

  /// The CSV of the operations quotes a comment of several lines, so it reads back whole.
  func testTheCSVQuotesACommentOfSeveralLines() throws {
    var writer = CSVWriter(columns: ["note"])
    writer.append(["кофе\nлатте"])
    let text = String(decoding: writer.data(), as: UTF8.self)
    XCTAssertTrue(text.contains("\"кофе\nлатте\""), text)
  }
}
