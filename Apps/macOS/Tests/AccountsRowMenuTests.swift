import AppCore
import AppDatabase
import SwiftUI
import XCTest

@testable import OhMyMoney

/// What VoiceOver hears for the «…» of a row in Settings → Счета: the row it acts on named —
/// «Действия с «Т-Банк»» for an account, a group and each card inside its account's row —, in
/// both languages. Read from the accessibility tree the window builds; a runner without an
/// assistive client builds none and skips.
@MainActor
final class AccountsRowMenuTests: XCTestCase {
  private var environment: AppEnvironment!
  private var store: TransactionsStore!
  private var directory: URL!
  private var dataDirectoryBefore: String?
  private var windows: [NSWindow] = []

  override func setUp() async throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    dataDirectoryBefore = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-accounts-row-menu-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    setenv("OHMYMONEY_DATA_DIR", directory.path, 1)
    environment = AppEnvironment()
    await environment.start(preparing: {
      try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    })
    store = TransactionsStore()
    store.attach(
      try XCTUnwrap(environment.transactions), references: environment.references,
      planning: environment.planning)
  }

  override func tearDown() async throws {
    for window in windows { window.close() }
    windows = []
    if let environment { await environment.close() }
    if let dataDirectoryBefore {
      setenv("OHMYMONEY_DATA_DIR", dataDirectoryBefore, 1)
    } else {
      unsetenv("OHMYMONEY_DATA_DIR")
    }
    if let directory { try? FileManager.default.removeItem(at: directory) }
  }

  func testAccountGroupAndCardRowMenusNameTheirRow() throws {
    self.executionTimeAllowance = 240
    let group = AccountGroup(name: "Казахстан")
    let main = PaymentMethod(name: "Сбер", kind: .card, currency: .rub, isDefault: true)
    let tBank = PaymentMethod(name: "Т-Банк", kind: .card, currency: .rub)
    let black = PaymentCard(accountId: tBank.id, name: "Black")
    XCTAssertTrue(
      store.apply(
        PlanningChange(
          upsert: PlanningRows(
            accountGroups: [group], paymentMethods: [main, tBank], cards: [black]))))
    let before = environment.language.choice
    defer { environment.language.choice = before }
    for choice in [AppLanguage.Choice.russian, .english] {
      environment.language.choice = choice
      let deps = AppDependencies(
        environment: environment, store: store, compute: ComputeStore(calendar: .system))
      let window = show(
        AccountsSettingsView().appDependencies(deps), size: CGSize(width: 680, height: 560))
      let wanted = ["Т-Банк", "Казахстан", "Black"].map { SettingsRowMenu.label($0, environment) }
      XCTAssertFalse(wanted.contains("references.rowMenu"), "\(choice.rawValue)")
      var heard: [String] = []
      waitFor {
        heard = Self.elements(inRowsOf: window).map(Self.spoken)
        return wanted.allSatisfy { label in heard.contains { $0.contains(label) } }
      }
      for label in wanted {
        XCTAssertTrue(
          heard.contains { $0.contains(label) }, "\(choice.rawValue): no «\(label)»: \(heard)")
      }
      window.close()
    }
  }

  // MARK: Helpers

  private func show<Content: View>(_ view: Content, size: CGSize) -> NSWindow {
    // dependencies: every caller hands them to the view it gives here
    let window = NSWindow(contentViewController: NSHostingController(rootView: view))
    window.setContentSize(size)
    window.isReleasedWhenClosed = false
    window.orderFront(nil)
    windows.append(window)
    settle(0.5)
    return window
  }

  private func settle(_ seconds: TimeInterval = 0.2) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
  }

  private func waitFor(_ condition: () -> Bool, seconds: TimeInterval = 5) {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition(), Date() < deadline { settle(0.05) }
  }

  private static func attribute(_ object: NSObject, _ name: String) -> Any? {
    guard object.responds(to: NSSelectorFromString(name)) else { return nil }
    return object.value(forKey: name)
  }

  private static func spoken(_ object: NSObject) -> String {
    ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"]
      .compactMap { attribute(object, $0) as? String }
      .filter { !$0.isEmpty }
      .joined(separator: " ")
  }

  /// Every element in the rows of the lists of the window. A SwiftUI list is a table of AppKit,
  /// and its rows are reached through the table rather than through the tree above.
  private static func elements(inRowsOf window: NSWindow) -> [NSObject] {
    func tables(in view: NSView) -> [NSTableView] {
      (view as? NSTableView).map { [$0] } ?? view.subviews.flatMap(tables)
    }
    var found: [NSObject] = []
    func walk(_ element: Any, depth: Int) {
      guard depth < 40, let object = element as? NSObject else { return }
      found.append(object)
      for child in attribute(object, "accessibilityChildren") as? [Any] ?? [] {
        walk(child, depth: depth + 1)
      }
    }
    for table in window.contentView.map(tables) ?? [] {
      for row in 0..<table.numberOfRows {
        if let view = table.rowView(atRow: row, makeIfNecessary: true) { walk(view, depth: 0) }
      }
    }
    return found
  }
}
