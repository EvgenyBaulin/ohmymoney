import AppCore
import AppDatabase
import SwiftUI
import XCTest

@testable import OhMyMoney

/// The forms of Settings → Accounts as they are typed into: a name reads from the left, so a space
/// typed last — «Сбер. » — is on screen at once; the amount stays on the right; the account form
/// fits under the settings window that opens it; ending an edit leaves the form where it was.
@MainActor
final class AccountEditorScrollTests: XCTestCase {
  private var environment: AppEnvironment!
  private var directory: URL!
  private var dataDirectoryBefore: String?
  private var windows: [NSWindow] = []

  override func setUp() async throws {
    dataDirectoryBefore = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-account-forms-\(UUID().uuidString)", isDirectory: true)
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

  /// The name of the account, of its new bank and another name read from the left; «Остаток
  /// сейчас» and the sums of «Условия банка» stay on the right. A text on the right hides a space typed last.
  func testTheNamesOfAnAccountReadFromTheLeftAndTheBalanceFromTheRight() throws {
    let window = try show(
      AccountEditor(previous: nil, defaultCurrency: CurrencyCode("RUB"), finish: { _ in }))
    // The name, the name of the new bank, the balance once the books are read, another name.
    waitFor { self.fields(in: window).count >= 4 }
    let fields = fields(in: window)
    XCTAssertGreaterThanOrEqual(fields.count, 4, "the fields of a new account")
    // The sums of «Условия банка» read from the right like the balance; the balance is the one
    // sum that has no «—» in it.
    XCTAssertEqual(
      fields.filter { $0.alignment == .right && !isAmount($0) }.count, 1,
      "only the balance reads from the right among the other fields")
    for field in fields where field.alignment != .right {
      XCTAssertTrue(
        [.left, .natural].contains(field.alignment), "a name field aligned \(field.alignment)")
    }
  }

  func testTheNamesOfABankACardAndAGroupReadFromTheLeft() throws {
    let editors: [(String, AnyView)] = [
      ("bank", AnyView(BankEditor(previous: nil, finish: { _ in }))),
      ("card", AnyView(CardEditor(previous: nil, accountId: UUID(), finish: { _ in }))),
      ("group", AnyView(AccountGroupEditor(previous: nil, finish: { _ in }))),
    ]
    for (name, editor) in editors {
      let window = try show(editor)
      let fields = fields(in: window)
      XCTAssertFalse(fields.isEmpty, "no field in the \(name) form")
      for field in fields where !isAmount(field) {
        XCTAssertTrue(
          [.left, .natural].contains(field.alignment),
          "a name field of the \(name) form aligned \(field.alignment)")
      }
    }
  }

  /// A space typed last is in the field at once, read from the left.
  func testASpaceTypedLastIsKept() throws {
    let window = try show(BankEditor(previous: nil, finish: { _ in }))
    let field = try XCTUnwrap(fields(in: window).first)
    XCTAssertTrue(window.makeFirstResponder(field))
    let editor = try XCTUnwrap(window.firstResponder as? NSTextView, "the field editor")
    editor.insertText("Сбер. ", replacementRange: editor.selectedRange())
    settle()
    XCTAssertEqual(editor.string, "Сбер. ")
    XCTAssertTrue([.left, .natural].contains(editor.alignment))
  }

  /// The account form opens no taller than the settings window it hangs from: taller, it went
  /// past the bottom of the window — and of a smaller screen — with the part of the form below.
  func testTheAccountFormFitsUnderTheSettingsWindow() throws {
    let window = try show(
      AccountEditor(previous: nil, defaultCurrency: CurrencyCode("RUB"), finish: { _ in }))
    let height = try XCTUnwrap(window.contentView).frame.height
    XCTAssertLessThanOrEqual(height, SettingsView.idealSize.height)
  }

  /// Leaving a field — the name, the balance — keeps the form where it was scrolled to.
  func testEndingAnEditKeepsTheFormWhereItWas() throws {
    let window = try show(
      AccountEditor(previous: nil, defaultCurrency: CurrencyCode("RUB"), finish: { _ in }))
    waitFor { self.fields(in: window).count >= 4 }
    let scroll = try XCTUnwrap(scrollViews(in: try XCTUnwrap(window.contentView)).first)
    for field in fields(in: window) {
      XCTAssertTrue(window.makeFirstResponder(field))
      settle(0.3)
      let editor = try XCTUnwrap(window.firstResponder as? NSTextView, "the field editor")
      editor.insertText("1", replacementRange: editor.selectedRange())
      settle()
      let before = scroll.contentView.bounds.origin.y
      XCTAssertTrue(window.makeFirstResponder(nil))
      settle(0.4)
      XCTAssertEqual(scroll.contentView.bounds.origin.y, before, "the form moved when left")
    }
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

  /// A sum of «Условия банка»: it says «—» while empty and reads from the right.
  private func isAmount(_ field: NSTextField) -> Bool {
    field.placeholderString == "—" && field.alignment == .right
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
