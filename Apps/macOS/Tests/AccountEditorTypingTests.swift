import AppCore
import AppDatabase
import SwiftUI
import XCTest

@testable import OhMyMoney

/// The account form of Settings → Accounts as the owner types into it: «. » typed at the end of
/// the account's name is on screen at once with the caret after the space, the field reads from
/// the left, and a click beside the fields — the name or «Остаток сейчас» left — moves neither
/// the form nor its window. «Отменить» (Esc) writes nothing.
@MainActor
final class AccountEditorTypingTests: XCTestCase {
  private var environment: AppEnvironment!
  private var directory: URL!
  private var dataDirectoryBefore: String?
  private var windows: [NSWindow] = []

  override func setUp() async throws {
    dataDirectoryBefore = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-account-typing-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    setenv("OHMYMONEY_DATA_DIR", directory.path, 1)
    environment = AppEnvironment()
    await environment.start(preparing: {
      try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    })
  }

  override func tearDown() async throws {
    for window in windows {
      window.contentViewController = nil
      window.close()
    }
    windows = []
    if let environment { await environment.close() }
    if let dataDirectoryBefore {
      setenv("OHMYMONEY_DATA_DIR", dataDirectoryBefore, 1)
    } else {
      unsetenv("OHMYMONEY_DATA_DIR")
    }
    if let directory { try? FileManager.default.removeItem(at: directory) }
  }

  /// An account opened for editing: «. » typed after its name stays at the end with the caret
  /// after the space, read from the left; leaving the field for an empty spot of the form leaves
  /// the form and the window where they were. The same for «Остаток сейчас».
  func testADotAndASpaceAfterTheNameStayAndAClickBesideMovesNothing() throws {
    let account = PaymentMethod(name: "Сбер", kind: .card, currency: .rub, isDefault: true)
    try XCTUnwrap(environment.references).save(account)
    let window = try show(
      AccountEditor(previous: account, defaultCurrency: CurrencyCode("RUB"), finish: { _ in }))
    waitFor { self.fields(in: window).contains { $0.stringValue == "Сбер" } }
    let name = try XCTUnwrap(fields(in: window).first { $0.stringValue == "Сбер" }, "the name")
    let scroll = try XCTUnwrap(scrollViews(in: try XCTUnwrap(window.contentView)).first)
    let frame = window.frame

    XCTAssertTrue(window.makeFirstResponder(name))
    settle(0.3)
    let editor = try XCTUnwrap(window.firstResponder as? NSTextView, "the field editor")
    editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
    editor.insertText(". ", replacementRange: editor.selectedRange())
    settle()
    XCTAssertEqual(editor.string, "Сбер. ", "the space typed last is in the field")
    XCTAssertEqual(
      editor.selectedRange(), NSRange(location: ("Сбер. " as NSString).length, length: 0),
      "the caret stands after the space")
    XCTAssertTrue([.left, .natural].contains(editor.alignment), "\(editor.alignment)")
    XCTAssertTrue([.left, .natural].contains(name.alignment), "\(name.alignment)")

    let scrolled = scroll.contentView.bounds.origin.y
    XCTAssertTrue(window.makeFirstResponder(nil), "a click beside the fields ends the edit")
    settle(0.4)
    XCTAssertEqual(scroll.contentView.bounds.origin.y, scrolled, "the form moved up")
    XCTAssertEqual(window.frame, frame, "the window moved")
    XCTAssertEqual(name.stringValue, "Сбер. ", "the name kept its space")

    let balance = try XCTUnwrap(
      fields(in: window).first { $0.alignment == .right }, "«Остаток сейчас»")
    XCTAssertTrue(window.makeFirstResponder(balance))
    settle(0.3)
    let amount = try XCTUnwrap(window.firstResponder as? NSTextView, "the field editor")
    amount.insertText("12500", replacementRange: amount.selectedRange())
    settle()
    let before = scroll.contentView.bounds.origin.y
    XCTAssertTrue(window.makeFirstResponder(nil))
    settle(0.4)
    XCTAssertEqual(scroll.contentView.bounds.origin.y, before, "the form moved up")
    XCTAssertEqual(window.frame, frame, "the window moved")
  }

  /// «Отменить» — Esc — closes the form with nothing written: the account keeps its name.
  func testCancelWritesNothing() throws {
    let account = PaymentMethod(name: "Сбер", kind: .card, currency: .rub, isDefault: true)
    let references = try XCTUnwrap(environment.references)
    try references.save(account)
    var finished: [UUID?] = []
    let window = try show(
      AccountEditor(
        previous: account, defaultCurrency: CurrencyCode("RUB"), finish: { finished.append($0) }))
    waitFor { self.fields(in: window).contains { $0.stringValue == "Сбер" } }
    let name = try XCTUnwrap(fields(in: window).first { $0.stringValue == "Сбер" })
    XCTAssertTrue(window.makeFirstResponder(name))
    settle(0.3)
    let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
    editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
    editor.insertText(". ", replacementRange: editor.selectedRange())
    settle()
    XCTAssertTrue(window.makeFirstResponder(nil))
    settle(0.2)

    XCTAssertTrue(
      window.performKeyEquivalent(with: EntryHost.key("\u{1b}", code: 53)), "Esc reached «Отменить»"
    )
    settle()
    XCTAssertEqual(finished, [nil], "the form closed saying nothing was saved")
    let stored = try references.paymentMethods(includeArchived: true)
    XCTAssertEqual(stored.map(\.name), ["Сбер"], "nothing was written")
  }

  // MARK: Helpers

  private func show<Content: View>(_ view: Content) throws -> NSWindow {
    let store = TransactionsStore()
    store.attach(
      try XCTUnwrap(environment.transactions), references: environment.references,
      planning: environment.planning)
    let deps = AppDependencies(
      environment: environment, store: store, compute: ComputeStore(calendar: .system))
    let window = NSWindow(
      contentViewController: NSHostingController(rootView: view.appDependencies(deps)))
    window.isReleasedWhenClosed = false
    window.makeKeyAndOrderFront(nil)
    windows.append(window)
    settle(0.8)
    return window
  }

  private func fields(in window: NSWindow) -> [NSTextField] {
    guard let root = window.contentView else { return [] }
    return textFields(in: root).filter(\.isEditable)
  }

  private func settle(_ seconds: TimeInterval = 0.2) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
  }

  private func waitFor(_ condition: () -> Bool, seconds: TimeInterval = 5) {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition(), Date() < deadline { settle(0.05) }
  }

  private func textFields(in view: NSView) -> [NSTextField] {
    ((view as? NSTextField).map { [$0] } ?? []) + view.subviews.flatMap(textFields)
  }

  private func scrollViews(in view: NSView) -> [NSScrollView] {
    ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrollViews)
  }
}
