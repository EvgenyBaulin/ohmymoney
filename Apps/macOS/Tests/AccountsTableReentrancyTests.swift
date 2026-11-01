import AppCore
import AppDatabase
import SwiftUI
import XCTest

@testable import OhMyMoney

// Synthetic data only.

/// The list of «Настройки → Счета» is filled without being changed from inside its own delegate.
/// A SwiftUI list on macOS is an `NSTableView`; made with its sections and rows, SwiftUI expands
/// them while it builds the table, AppKit measures the rows from inside that expansion and says
/// «reentrant operation in its NSTableView delegate» — and promises an assert for it. Counted from
/// before the window exists, so a message logged on the first frame is caught too.
@MainActor
final class AccountsTableReentrancyTests: XCTestCase {
  private var environment: AppEnvironment!
  private var store: TransactionsStore!
  private var directory: URL!
  private var dataDirectoryBefore: String?
  private var windows: [NSWindow] = []

  override func setUp() async throws {
    dataDirectoryBefore = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-accounts-table-\(UUID().uuidString)", isDirectory: true)
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

  private var messages: [String] {
    [
      LogProbe.Message.reentrantTable, LogProbe.Message.layoutLoop,
      LogProbe.Message.stateDuringUpdate,
    ]
  }

  private func seed() {
    let bank = Bank(name: "Т-Банк")
    let group = AccountGroup(name: "Казахстан")
    let main = PaymentMethod(name: "Сбер", kind: .card, currency: .rub, isDefault: true)
    var tBank = PaymentMethod(name: "Т-Банк Black", kind: .card, currency: .rub)
    tBank.bankId = bank.id
    let black = PaymentCard(accountId: tBank.id, name: "Black")
    XCTAssertTrue(
      store.apply(
        PlanningChange(
          upsert: PlanningRows(
            accountGroups: [group], paymentMethods: [main, tBank], cards: [black],
            banks: [bank]))))
  }

  private func open() -> NSWindow {
    let deps = AppDependencies(
      environment: environment, store: store, compute: ComputeStore(calendar: .system))
    // dependencies: handed to the view right here
    let window = NSWindow(
      contentViewController: NSHostingController(
        rootView: AccountsSettingsView().appDependencies(deps)))
    window.setContentSize(CGSize(width: 680, height: 560))
    window.isReleasedWhenClosed = false
    window.orderFront(nil)
    windows.append(window)
    return window
  }

  /// Waits until the list has rows: the accounts were read and drawn.
  private func waitForRows(_ window: NSWindow, seconds: TimeInterval = 10) -> Int {
    func tables(in view: NSView) -> [NSTableView] {
      (view as? NSTableView).map { [$0] } ?? view.subviews.flatMap(tables)
    }
    let deadline = Date().addingTimeInterval(seconds)
    var rows = 0
    repeat {
      RunLoop.main.run(until: Date().addingTimeInterval(0.05))
      rows = (window.contentView.map(tables) ?? []).map(\.numberOfRows).max() ?? 0
    } while rows < 4 && Date() < deadline
    // A few more turns, so whatever the first update sets off has happened.
    for _ in 0..<10 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    return rows
  }

  func testOpeningTheAccountsTouchesNoTableFromItsOwnDelegate() {
    seed()
    let probe = LogProbe()
    let before = probe.counts(of: messages)
    let window = open()
    let rows = waitForRows(window)
    XCTAssertGreaterThanOrEqual(rows, 4, "the list never filled")
    probe.assertQuiet(about: messages, comparedWith: before, "opening «Настройки → Счета»")
  }

  /// Every row made at once — as VoiceOver asks for them — in both languages, the language
  /// switched while the list is on screen: the way the list was said to complain before.
  func testMakingEveryRowInBothLanguagesTouchesNoTableFromItsOwnDelegate() {
    seed()
    let before = environment.language.choice
    defer { environment.language.choice = before }
    let probe = LogProbe()
    let counted = probe.counts(of: messages)
    for choice in [AppLanguage.Choice.russian, .english] {
      environment.language.choice = choice
      let window = open()
      _ = waitForRows(window)
      for table in Self.tables(in: window.contentView!) {
        for row in 0..<table.numberOfRows { _ = table.rowView(atRow: row, makeIfNecessary: true) }
      }
      environment.language.choice = choice == .russian ? .english : .russian
      for _ in 0..<10 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
      window.close()
    }
    probe.assertQuiet(about: messages, comparedWith: counted, "every row in both languages")
  }

  private static func tables(in view: NSView) -> [NSTableView] {
    (view as? NSTableView).map { [$0] } ?? view.subviews.flatMap(tables)
  }

  /// The tab opened a second time — the settings window closed and opened again — makes the list
  /// again, and fills it the same way.
  func testOpeningTheAccountsAgainTouchesNoTableFromItsOwnDelegate() {
    seed()
    let window = open()
    _ = waitForRows(window)
    let probe = LogProbe()
    let before = probe.counts(of: messages)
    window.close()
    let again = open()
    _ = waitForRows(again)
    probe.assertQuiet(about: messages, comparedWith: before, "opening «Настройки → Счета» again")
  }
}
