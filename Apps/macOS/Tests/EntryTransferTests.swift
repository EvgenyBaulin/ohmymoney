import AppCore
import AppDatabase
import AppKit
import XCTest

@testable import OhMyMoney

/// «Перевести…» in the ↓ panel: the fields of a transfer take the place of the operation's in
/// the panel itself — no window of its own — started with the amount the panel holds; Return
/// writes the transfer, clears the panel, and one ⌘Z takes it back.
@MainActor
final class EntryTransferTests: XCTestCase {
  private var host: EntryHost?

  override func tearDown() async throws {
    if let sheet = host?.window.attachedSheet { host?.window.endSheet(sheet) }
    host?.close()
    host = nil
  }

  private func attribute(_ object: NSObject, _ name: String) -> Any? {
    guard object.responds(to: NSSelectorFromString(name)) else { return nil }
    return object.value(forKey: name)
  }

  /// The element of the window an identifier names, found the way VoiceOver finds it: a button
  /// of SwiftUI is no `NSButton` of the view tree.
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

  func testThePanelOffersTheTransferAndItsFieldsStartWithItsAmount() async throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    let cash = PaymentMethod(name: "Наличные", currency: .rub, isDefault: true)
    let savings = PaymentMethod(name: "Копилка", currency: .rub)
    let host = try await EntryHost { environment in
      try XCTUnwrap(environment.references).save(cash)
      try XCTUnwrap(environment.references).save(savings)
    }
    self.host = host
    try host.type("250", into: try host.field(prompt: "0"))
    let button = try XCTUnwrap(
      element(identified: "entry.transfer", in: host.window), "the panel has no «Перевести…»")
    _ = button.perform(NSSelectorFromString("accessibilityPerformPress"))
    host.settle(0.5)

    XCTAssertNil(host.window.attachedSheet, "a transfer opens no window of its own")
    XCTAssertNotNil(
      element(identified: "transfer.to", in: host.window), "the fields of a transfer are not there")
    XCTAssertNil(
      element(identified: "entry.category", in: host.window), "the operation's fields stayed")
    XCTAssertTrue(
      host.textFields().contains { $0.stringValue == "250" },
      "the amount of the panel is what leaves")

    try WindowAccessibility.choose("Копилка", inMenu: "transfer.to", of: host.window)
    host.settle()
    let line = try host.line()
    XCTAssertTrue(host.window.makeFirstResponder(line))
    try XCTUnwrap(host.window.firstResponder as? NSTextView).insertNewline(nil)
    var written: [Transfer] = []
    let deadline = Date().addingTimeInterval(3)
    while written.isEmpty, Date() < deadline {
      host.settle(0.1)
      let books = await TransferActions(environment: host.environment, store: host.store).books()
      written = try XCTUnwrap(books).dataset.transfers
    }
    let transfer = try XCTUnwrap(written.first, "Return did not write the transfer")
    XCTAssertEqual(transfer.fromAccountId, cash.id, "the account of the panel is where it leaves")
    XCTAssertEqual(transfer.toAccountId, savings.id)
    XCTAssertEqual(transfer.fromAmountE4, AmountE4(whole: 250))
    XCTAssertEqual(try host.transactions.count(), 0, "a transfer is no expense")
    XCTAssertNil(
      element(identified: "transfer.to", in: host.window), "the panel kept the transfer")

    host.store.undo()
    host.settle()
    let books = await TransferActions(environment: host.environment, store: host.store).books()
    let after = try XCTUnwrap(books)
    XCTAssertTrue(after.dataset.transfers.isEmpty, "⌘Z left the transfer")
  }
}
