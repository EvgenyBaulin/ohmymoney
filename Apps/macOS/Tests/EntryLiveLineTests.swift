import AppCore
import AppDatabase
import AppKit
import XCTest

@testable import OhMyMoney

/// The open ↓ panel reads the line while it is typed: the amount and the words show in it before
/// Enter, and whatever the owner chose in the panel stays over the line.
@MainActor
final class EntryLiveLineTests: XCTestCase {
  private var host: EntryHost?

  override func tearDown() async throws {
    host?.close()
    host = nil
  }

  /// The amount and the note of the line are in the panel as they are typed.
  func testThePanelShowsTheLineBeforeEnter() async throws {
    let host = try await EntryHost()
    self.host = host
    try host.type("coffee 250", into: try host.line())
    host.settle(0.3)
    XCTAssertEqual(try host.field(prompt: "0").stringValue, "250", "the amount of the line")
    XCTAssertTrue(
      host.textFields().contains { $0.stringValue == "coffee" }, "the words of the line")
    XCTAssertEqual(try host.transactions.count(), 0, "nothing is saved without Enter")
  }

  /// A new reading follows every change of the line.
  func testThePanelFollowsTheLine() async throws {
    let host = try await EntryHost()
    self.host = host
    try host.type("coffee 250", into: try host.line())
    host.settle(0.3)
    try host.type("coffee 400", into: try host.line())
    host.settle(0.3)
    XCTAssertEqual(try host.field(prompt: "0").stringValue, "400")
  }

  /// An amount the owner corrected in the panel is theirs: the line, which still says the old
  /// one, does not write it back when more words are typed.
  func testWhatThePanelHoldsStaysOverTheLine() async throws {
    let host = try await EntryHost()
    self.host = host
    try host.type("coffee 250", into: try host.line())
    host.settle(0.3)
    try host.type("300", into: try host.field(prompt: "0"))
    host.settle(0.2)

    let line = try host.line()
    XCTAssertTrue(host.window.makeFirstResponder(line))
    let editor = try XCTUnwrap(host.window.firstResponder as? NSTextView)
    editor.setSelectedRange(NSRange(location: editor.string.count, length: 0))
    editor.insertText(" with milk", replacementRange: editor.selectedRange())
    host.settle(0.3)
    XCTAssertEqual(try host.field(prompt: "0").stringValue, "300", "the panel's amount stays")
    XCTAssertTrue(
      host.textFields().contains { $0.stringValue == "coffee with milk" }, "the words follow")
  }

  /// With the panel closed there is nothing to show: the line is read at Enter, as before.
  func testAClosedPanelIsNotWrittenTo() async throws {
    let host = try await EntryHost(opensDetails: false)
    self.host = host
    try host.type("coffee 250", into: try host.line())
    host.settle(0.3)
    XCTAssertNil(host.textFields().first { $0.placeholderString == "0" }, "no panel")
    XCTAssertEqual(try host.transactions.count(), 0)
  }
}
