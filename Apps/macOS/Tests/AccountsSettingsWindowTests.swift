import AppCore
import AppDatabase
import AppKit
import SwiftUI
import XCTest

@testable import OhMyMoney

/// «Настройки → Счета» in the settings window at the size of its frame in the design (Mac
/// 68:18658, 1000 × 680), over the book the frame draws: «Деньги» with Сбер and Т-Банк and
/// «Наличные», «Накопления» left out of the summary, «Кредитки». The window is measured against
/// the frame's numbers — the sidebar 240, the tree 28 from it and 416 wide with 7 inside its
/// outline, rows 30 tall, the panel 276 beside it, 12 apart — and a picture of the window is kept
/// with the result, to lay beside the frame.
@MainActor
final class AccountsSettingsWindowTests: XCTestCase {
  private var environment: AppEnvironment!
  private var store: TransactionsStore!
  private var compute: ComputeStore!
  private var directory: URL!
  private var dataDirectoryBefore: String?
  private var languageBefore: AppLanguage.Choice?
  private var windows: [NSWindow] = []

  override func setUp() async throws {
    dataDirectoryBefore = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-settings-accounts-\(UUID().uuidString)", isDirectory: true)
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
    compute = ComputeStore(calendar: .system, rebuildsInline: true)
    languageBefore = environment.language.choice
    environment.language.choice = .russian
  }

  override func tearDown() async throws {
    for window in windows {
      window.contentViewController = nil
      window.close()
    }
    windows = []
    if let languageBefore { environment.language.choice = languageBefore }
    SettingsNavigation.shared.section = .general
    if let environment { await environment.close() }
    if let dataDirectoryBefore {
      setenv("OHMYMONEY_DATA_DIR", dataDirectoryBefore, 1)
    } else {
      unsetenv("OHMYMONEY_DATA_DIR")
    }
    if let directory { try? FileManager.default.removeItem(at: directory) }
  }

  /// The book of the frame, counted today, and the calculation over it.
  private func seed() async throws {
    let money = AccountGroup(name: "Деньги", sort: 1)
    let savings = AccountGroup(name: "Накопления", inSummary: false, sort: 2)
    let credit = AccountGroup(name: "Кредитки", sort: 3)
    let sber = Bank(name: "Сбер")
    let tBank = Bank(name: "Т-Банк")
    let cashBank = Bank(name: "Наличные")
    let debit = PaymentMethod(
      name: "Дебетовый", kind: .card, currency: .rub, isDefault: true, groupId: money.id,
      sort: 1, bankId: sber.id)
    let debit2 = PaymentMethod(
      name: "Дебетовая", kind: .card, currency: .rub, groupId: money.id, sort: 2,
      bankId: tBank.id, accent: "03")
    let cash = PaymentMethod(
      name: "Наличные", kind: .cash, currency: .rub, groupId: money.id, sort: 3,
      bankId: cashBank.id)
    let saving = PaymentMethod(
      name: "Накопительный", kind: .account, currency: .rub, groupId: savings.id, sort: 4,
      bankId: sber.id)
    let creditCard = PaymentMethod(
      name: "Кредитка ··3310", kind: .card, currency: .rub, groupId: credit.id, sort: 5,
      bankId: tBank.id)
    let cards = [
      PaymentCard(accountId: debit.id, name: "Карта ··4821"),
      PaymentCard(accountId: debit2.id, name: "Карта ··7710"),
      PaymentCard(accountId: debit2.id, name: "Карта папы"),
    ]
    let now = environment.now()
    let count = Reconciliation(
      date: environment.calendar.day(of: now), reconciledAt: now, actualTotalRubE4: .zero,
      kind: .opening, origin: .account)
    let balances = [
      (debit, 98_200), (debit2, 36_200), (cash, 8_000), (saving, 40_000), (creditCard, 12_400),
    ].map { account, units in
      ReconciledBalance(
        reconciliationId: count.id, accountId: account.id, currency: .rub,
        actualE4: AmountE4(whole: Int64(units)))
    }
    XCTAssertTrue(
      store.apply(
        PlanningChange(
          upsert: PlanningRows(
            reconciliations: [count], accountGroups: [money, savings, credit],
            paymentMethods: [debit, debit2, cash, saving, creditCard],
            reconciledBalances: balances, cards: cards, banks: [sber, tBank, cashBank]))))
    let books = await AccountActions(environment: environment, store: store).books()
    let dataset = try XCTUnwrap(books).dataset
    compute.applyLight(
      DataSnapshot.build(
        dataset: dataset, calendar: environment.calendar, today: environment.today,
        context: SnapshotContext(rubPerUnit: [:]), version: DataVersion(load: 0)))
  }

  private func makeWindow() -> NSWindow {
    SettingsNavigation.shared.query = ""
    SettingsNavigation.shared.section = .accounts
    let deps = AppDependencies(environment: environment, store: store, compute: compute)
    let root = AppScenes.root(deps, window: .settings, launches: false) {
      SettingsView(deps: $0)
    }
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: SettingsChromeMetrics.windowSize),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.contentViewController = NSHostingController(rootView: root)
    window.setContentSize(SettingsChromeMetrics.windowSize)
    window.isReleasedWhenClosed = false
    window.orderFront(nil)
    windows.append(window)
    return window
  }

  private static func tables(in view: NSView) -> [NSTableView] {
    (view as? NSTableView).map { [$0] } ?? view.subviews.flatMap(tables)
  }

  /// Waits until the tree is drawn with at least `rows`.
  private func treeTable(in window: NSWindow, rows: Int) throws -> NSTableView {
    let deadline = Date().addingTimeInterval(10)
    var found: NSTableView?
    repeat {
      RunLoop.main.run(until: Date().addingTimeInterval(0.05))
      found = (window.contentView.map(Self.tables) ?? []).first { table in
        table.convert(table.bounds, to: nil).minX > SettingsChromeMetrics.sidebarWidth
          && table.numberOfRows >= rows
      }
    } while found == nil && Date() < deadline
    for _ in 0..<10 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    return try XCTUnwrap(found, "the tree never filled")
  }

  /// A picture of the window, kept with the result of the test.
  private func attachPicture(of window: NSWindow, named name: String) throws {
    let view = try XCTUnwrap(window.contentView)
    let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: rep)
    let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  /// The frame's numbers, at the frame's size.
  func testTheAccountsOfTheSettingsAtTheSizeOfTheFrame() async throws {
    self.executionTimeAllowance = 240
    try await seed()
    let window = makeWindow()
    // Деньги, Сбер, Дебетовый, its card, Т-Банк, Дебетовая, two cards, Наличные, Кредитки…
    let tree = try treeTable(in: window, rows: 14)
    try attachPicture(of: window, named: "Настройки · Счета 1000×680")
    let content = try XCTUnwrap(window.contentView)
    XCTAssertEqual(content.bounds.size, SettingsChromeMetrics.windowSize)

    // The sidebar is 240 wide.
    let sidebar = try XCTUnwrap(
      Self.tables(in: content).first { $0.convert($0.bounds, to: nil).minX < 100 },
      "the sidebar has no list")
    let sidebarScroll = try XCTUnwrap(sidebar.enclosingScrollView)
    XCTAssertEqual(
      sidebarScroll.convert(sidebarScroll.bounds, to: nil).maxX,
      SettingsChromeMetrics.sidebarWidth, accuracy: 1.5)

    // The tree: 28 from the sidebar, 7 inside its card, 402 of rows, each 30 tall.
    let scroll = try XCTUnwrap(tree.enclosingScrollView)
    let frame = scroll.convert(scroll.bounds, to: nil)
    let left =
      SettingsChromeMetrics.sidebarWidth + 1 + SettingsChromeMetrics.contentInset
      + AccountsTreeMetrics.treeInset
    XCTAssertEqual(frame.minX, left, accuracy: 1.5, "the tree starts 28 + 7 from the sidebar")
    XCTAssertEqual(
      frame.width, AccountsTreeMetrics.treeWidth - 2 * AccountsTreeMetrics.treeInset,
      accuracy: 1.5, "416 wide with 7 inside")
    for row in 0..<min(tree.numberOfRows, 10) {
      XCTAssertEqual(tree.rect(ofRow: row).height, AccountsTreeMetrics.rowHeight, accuracy: 0.5)
    }
    // The panel: its own scroll view, 276 wide, 12 after the tree's card, 28 from the right.
    let treeCardRight = frame.maxX + AccountsTreeMetrics.treeInset
    let panel = try XCTUnwrap(
      Self.scrollViews(in: content).map { $0.convert($0.bounds, to: nil) }
        .first { $0.minX > treeCardRight && $0.height > 200 },
      "the panel was not found")
    XCTAssertEqual(panel.width, AccountsTreeMetrics.panelWidth, accuracy: 1)
    XCTAssertEqual(
      panel.minX, treeCardRight + AccountsTreeMetrics.columnGap, accuracy: 1.5)
    XCTAssertEqual(
      panel.maxX, SettingsChromeMetrics.windowSize.width - SettingsChromeMetrics.contentInset,
      accuracy: 1.5)
  }

  private static func scrollViews(in view: NSView) -> [NSScrollView] {
    (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
  }

  /// The numbers of the tree and of the panel, as the frame draws them.
  func testTheMeasuresFollowTheFrame() {
    XCTAssertEqual(AccountsTreeMetrics.treeWidth, 416)
    XCTAssertEqual(AccountsTreeMetrics.panelWidth, 276)
    XCTAssertEqual(AccountsTreeMetrics.columnGap, 12)
    XCTAssertEqual(AccountsTreeMetrics.rowHeight, 30)
    XCTAssertEqual(AccountsTreeMetrics.rowPadding, 8)
    XCTAssertEqual(AccountsTreeMetrics.rowGap, 4)
    XCTAssertEqual(AccountsTreeMetrics.indent, 12)
    XCTAssertEqual(AccountsTreeMetrics.mark, 14)
    XCTAssertEqual(AccountsTreeMetrics.symbol, 16)
    XCTAssertEqual(AccountsTreeMetrics.searchHeight, 30)
    XCTAssertEqual(AccountsTreeMetrics.barHeight, 44)
    XCTAssertEqual(AccountsTreeMetrics.panelPadding, 14)
    XCTAssertEqual(AccountsTreeMetrics.switchSize, CGSize(width: 44, height: 26))
    // 28 + 416 + 12 + 276 + 28 = the 760 of content beside the sidebar of 240.
    XCTAssertEqual(
      SettingsChromeMetrics.contentInset * 2 + AccountsTreeMetrics.treeWidth
        + AccountsTreeMetrics.columnGap + AccountsTreeMetrics.panelWidth
        + SettingsChromeMetrics.sidebarWidth,
      SettingsChromeMetrics.windowSize.width)
  }

  /// Every word of the tree and the panel is in both languages.
  func testTheWordsOfTheTreeAreInBothLanguages() throws {
    let keys = [
      "tree.search.prompt", "tree.collapseAll", "tree.expandAll", "tree.add", "tree.noGroup",
      "tree.toGroup", "tree.hide", "tree.show", "tree.toArchive", "tree.hidden", "tree.archive",
      "tree.inSummary", "tree.notInSummary", "tree.card.main", "tree.badge.borrowed",
      "tree.badge.credit", "panel.bank", "panel.group", "panel.name", "panel.currency",
      "panel.color", "panel.cashback", "panel.mainCard", "panel.inSummary", "panel.hide",
      "panel.note", "panel.note.touch", "panel.deleteAccount", "tree.edit", "tree.done",
    ]
    for code in ["ru", "en"] {
      let bundle = try XCTUnwrap(
        Bundle.main.path(forResource: code, ofType: "lproj").flatMap(Bundle.init(path:)))
      for key in keys {
        let text = bundle.localizedString(forKey: key, value: nil, table: EntryLinks.table)
        XCTAssertNotEqual(text, key, "\(code): \(key)")
      }
    }
  }
}
