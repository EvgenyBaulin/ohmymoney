import AppCore
import AppKit
import XCTest

@testable import OhMyMoney

/// The entry line in its question mode, in a window: the button switches the mode, Enter asks,
/// and not one operation is ever written by a question.
@MainActor
final class QuestionsEntryBarTests: XCTestCase {
  private var host: EntryHost?

  override func tearDown() async throws {
    host?.close()
    host = nil
  }

  private func attribute(_ object: NSObject, _ name: String) -> Any? {
    guard object.responds(to: NSSelectorFromString(name)) else { return nil }
    return object.value(forKey: name)
  }

  private func element(identified identifier: String, in window: NSWindow) -> NSObject? {
    var found: NSObject?
    func walk(_ element: Any) {
      guard found == nil, let object = element as? NSObject else { return }
      if attribute(object, "accessibilityIdentifier") as? String == identifier {
        found = object
        return
      }
      for child in attribute(object, "accessibilityChildren") as? [Any] ?? [] { walk(child) }
    }
    if let root = window.contentView { walk(root) }
    return found
  }

  private func press(_ identifier: String, in host: EntryHost) throws {
    let target = try XCTUnwrap(element(identified: identifier, in: host.window), identifier)
    _ = target.perform(NSSelectorFromString("accessibilityPerformPress"))
    host.settle(0.4)
  }

  private func questionLine(in host: EntryHost) throws -> NSTextField {
    let prompt = QuestionsText.t("questions.prompt", host.environment)
    return try XCTUnwrap(
      host.textFields().first { $0.placeholderString == prompt }, "the line in question mode")
  }

  func testTheButtonSwitchesTheLineToQuestionsAndBack() async throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    let host = try await EntryHost(opensDetails: false)
    self.host = host
    XCTAssertNotNil(try? host.line(), "the entry line first")
    XCTAssertNil(element(identified: "question.panel", in: host.window))
    try press("entry.question.toggle", in: host)
    XCTAssertNotNil(try? questionLine(in: host), "the prompt asks for a question")
    XCTAssertNotNil(
      element(identified: "question.panel", in: host.window), "the panel stands over the line")
    try press("entry.question.toggle", in: host)
    XCTAssertNotNil(try? host.line())
    XCTAssertNil(element(identified: "question.panel", in: host.window))
  }

  func testEnterInTheQuestionModeWritesNothing() async throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    let host = try await EntryHost(opensDetails: false)
    self.host = host
    // History files «кофе» in a category, so in the entry mode «кофе 250» is written at once.
    try EntryHost.history("кофе", in: host.environment)
    let before = try host.transactions.count()
    try press("entry.question.toggle", in: host)
    for text in ["сколько кофе 250", " кофе 250", " сколько на такси в сентябре", " абракадабра"] {
      let line = try questionLine(in: host)
      try host.type(text, into: line)
      host.pressReturn()
      host.settle(0.3)
      XCTAssertEqual(
        try host.transactions.count(), before, "«\(text)» asked and wrote nothing")
      XCTAssertNotNil(
        element(identified: "question.panel", in: host.window), "the answer area stays")
    }
  }

  /// The control of the test above: the same words in the entry mode are an expense.
  func testTheSameWordsInTheEntryModeAreWritten() async throws {
    let host = try await EntryHost(opensDetails: false)
    self.host = host
    try EntryHost.history("кофе", in: host.environment)
    let before = try host.transactions.count()
    try host.type("кофе 250", into: try host.line())
    host.pressReturn()
    XCTAssertTrue(
      host.settle(until: { (try? host.transactions.count()) == before + 1 }),
      "the entry line writes it")
  }

  func testALineThatReadsLikeAQuestionOnlyOffersTheMode() async throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    let host = try await EntryHost(opensDetails: false)
    self.host = host
    try host.type("сколько кофе 250", into: try host.line())
    host.settle(0.3)
    XCTAssertNotNil(
      element(identified: "entry.question.nudge", in: host.window), "the offer is there")
    XCTAssertNil(
      element(identified: "question.panel", in: host.window), "but the line is still the entry line"
    )
    XCTAssertEqual(try host.transactions.count(), 0, "typing is not saving")
  }
}
