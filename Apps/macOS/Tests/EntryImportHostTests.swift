import AppKit
import XCTest

@testable import OhMyMoney

/// Exercise the receiver installed on the real entry field, with an isolated clipboard.
@MainActor
final class EntryImportHostTests: XCTestCase {
  private var host: EntryHost?

  override func tearDown() async throws {
    host?.close()
    host = nil
  }

  func testCommandVImportsAnImageAndKeepsTheTypedDraft() async throws {
    let host = try await EntryHost(opensDetails: false)
    self.host = host
    try host.type("coffee 250", into: host.line())
    let receiver = try XCTUnwrap(host.views(of: EntryImportPaste.Receiver.self).first)
    XCTAssertTrue(host.settle(until: { receiver.focused }))
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    let bytes = Data([1, 2, 3])
    pasteboard.setData(bytes, forType: .png)
    XCTAssertTrue(receiver.receive(try pasteEvent(in: host.window), pasteboard: pasteboard))
    XCTAssertEqual(host.environment.entryImports.active?.file?.data, bytes)
    XCTAssertEqual(try host.line().stringValue, "coffee 250")
    XCTAssertEqual(try host.transactions.count(), 0)
  }

  func testCommandVWithSMSAndAnUnfocusedLineStaysWithTheTextEditor() async throws {
    let host = try await EntryHost(opensDetails: false)
    self.host = host
    try host.type("", into: host.line())
    let receiver = try XCTUnwrap(host.views(of: EntryImportPaste.Receiver.self).first)
    XCTAssertTrue(host.settle(until: { receiver.focused }))
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    pasteboard.setString(
      "MIR-3230 12:45 Покупка 1250р PYATEROCHKA Баланс: 52340.11р", forType: .string)
    XCTAssertFalse(receiver.receive(try pasteEvent(in: host.window), pasteboard: pasteboard))
    XCTAssertNil(host.environment.entryImports.active)
    pasteboard.clearContents()
    pasteboard.setData(Data([1]), forType: .png)
    receiver.focused = false
    XCTAssertFalse(receiver.receive(try pasteEvent(in: host.window), pasteboard: pasteboard))
    XCTAssertNil(host.environment.entryImports.active)
  }

  private func pasteEvent(in window: NSWindow) throws -> NSEvent {
    try XCTUnwrap(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
        windowNumber: window.windowNumber, context: nil, characters: "v",
        charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9))
  }
}
