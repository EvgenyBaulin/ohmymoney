import AppCore
import AppDatabase
import AppKit
import XCTest

@testable import OhMyMoney

/// An impossible «ДД.ММ» does not save: the line says why — «31.09 — такой даты нет»,
/// «29 февраля 2026 года нет» — and nothing is written; the line stays as typed.
@MainActor
final class EntryDateProblemTests: XCTestCase {
  private var host: EntryHost?

  override func tearDown() async throws {
    host?.close()
    host = nil
  }

  /// What the line says, in both languages: the word as typed, the year as digits.
  func testTheReasonReadsInBothLanguages() {
    let environment = AppEnvironment()
    let noDay = EntryLineMessage.date(.noSuchDate(written: "31.09"))
    let noLeap = EntryLineMessage.date(.notInYear(day: 29, month: 2, year: 2026))
    environment.language.choice = .russian
    XCTAssertEqual(noDay.text(environment), "31.09 — такой даты нет")
    XCTAssertEqual(noLeap.text(environment), "29 февраля 2026 года нет")
    environment.language.choice = .english
    XCTAssertEqual(noDay.text(environment), "31.09 — there is no such date")
    XCTAssertEqual(noLeap.text(environment), "There is no 29 February 2026")
    XCTAssertTrue(noDay.isError)
    XCTAssertFalse(EntryLineMessage.gap(.category).isError)
  }

  func testAnImpossibleDaySaysWhyAndSavesNothing() async throws {
    let host = try await EntryHost(opensDetails: false) { try EntryHost.history("кофе", in: $0) }
    self.host = host
    let before = try host.transactions.count()
    let editor = try host.type("кофе 31.09 250", into: try host.line())
    editor.insertNewline(nil)
    host.settle()

    XCTAssertEqual(try host.transactions.count(), before, "nothing is saved")
    XCTAssertEqual(try host.line().stringValue, "кофе 31.09 250", "the line stays as typed")
    // The same line with a day the calendar has saves.
    host.settle(0.3)
    let fixed = try host.line()
    XCTAssertTrue(host.window.makeFirstResponder(fixed))
    let again = try XCTUnwrap(host.window.firstResponder as? NSTextView)
    again.selectAll(nil)
    again.insertText("кофе 30.09 250", replacementRange: again.selectedRange())
    host.settle(0.1)
    again.insertNewline(nil)
    host.settle()
    XCTAssertEqual(try host.transactions.count(), before + 1)
  }
}
