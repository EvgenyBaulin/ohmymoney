import AppCore
import AppDatabase
import AppKit
import XCTest

@testable import OhMyMoney

/// The form at the side of the main window, in a window: after «Сохранить» and after «Очистить»
/// the keyboard is back in the quick line, so the next operation is typed at once.
@MainActor
final class EntryFormFocusTests: XCTestCase {
  private var host: EntryHost?
  private let cafe = CoreKit.Category(kind: .expense, name: "Cafe", quality: .neutral)

  override func tearDown() async throws {
    host?.close()
    host = nil
  }

  private func openForm() async throws -> EntryHost {
    let cafe = cafe
    let host = try await EntryHost(opensDetails: false, style: .form) {
      try $0.references!.save(cafe)
    }
    self.host = host
    return host
  }

  private func quickLine(of host: EntryHost) throws -> NSTextField {
    try host.field(prompt: host.environment.language("entry.quick.prompt", table: "Entry"))
  }

  /// The field whose editor has the keyboard.
  private func focused(in host: EntryHost) -> NSTextField? {
    (host.window.firstResponder as? NSTextView)?.delegate as? NSTextField
  }

  /// SwiftUI moves the keyboard from a task of the main actor: waited for by suspending, up to
  /// two seconds, until the quick line has it.
  private func waitForTheQuickLine(in host: EntryHost) async throws -> NSTextField? {
    let line = try quickLine(of: host)
    let deadline = Date().addingTimeInterval(2)
    repeat {
      try await Task.sleep(for: .milliseconds(50))
      host.settle(0.05)
    } while focused(in: host) !== line && Date() < deadline
    return focused(in: host)
  }

  private func press(_ identifier: String, in host: EntryHost) async throws {
    let element = try XCTUnwrap(
      WindowAccessibility.element(identified: identifier, in: host.window), identifier)
    WindowAccessibility.press(element)
    try await Task.sleep(for: .milliseconds(100))
    host.settle(0.2)
  }

  /// An expense typed in the fields, the keyboard left in the amount.
  private func fillAnExpense(in host: EntryHost) async throws {
    try await press("entry.kind.expense", in: host)
    try WindowAccessibility.choose("Cafe", inMenu: "entry.category", of: host.window)
    try host.type("250", into: try host.field(prompt: "0"))
    XCTAssertTrue(focused(in: host) === (try host.field(prompt: "0")), "typing in the amount")
  }

  func testASaveGivesTheKeyboardBackToTheQuickLine() async throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    let host = try await openForm()
    try await fillAnExpense(in: host)
    try await press("entry.form.save", in: host)
    XCTAssertEqual(try host.transactions.count(), 1, "saved")
    let after = try await waitForTheQuickLine(in: host)
    XCTAssertTrue(
      after === (try quickLine(of: host)),
      "after a save the keyboard went to «\(after?.placeholderString ?? "nothing")»")
  }

  func testClearGivesTheKeyboardBackToTheQuickLine() async throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    let host = try await openForm()
    try await fillAnExpense(in: host)
    try await press("entry.form.clear", in: host)
    XCTAssertEqual(try host.transactions.count(), 0, "«Очистить» writes nothing")
    let after = try await waitForTheQuickLine(in: host)
    XCTAssertTrue(
      after === (try quickLine(of: host)),
      "after «Очистить» the keyboard went to «\(after?.placeholderString ?? "nothing")»")
  }
}
