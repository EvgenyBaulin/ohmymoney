import AppCore
import AppDatabase
import AppKit
import SwiftUI
import XCTest

@testable import OhMyMoney

/// «Операции» in the sidebar, under «Обзор» (⌘4, and ⌘⇧T, ⌘F and the button of the toolbar from
/// anywhere): the table of every operation in the main window, its search through the whole
/// history, its filters, its columns, the arrows and ↓ of the line, and the editor beside it —
/// or the form at the side. And an amount in another currency shows grey «≈ … ₽» — before Enter
/// in the line, beside the row once written, and the exact rubles once the owner typed the rate.
@MainActor
final class OperationsSectionTests: XCTestCase {
  private var environment: AppEnvironment!
  private var store: TransactionsStore!
  private var compute: ComputeStore!
  private var windows: [NSWindow] = []
  private var directory: URL!
  private var logs: URL!
  private var dataDirectoryBefore: String?
  private var suiteName: String!
  private var defaults: UserDefaults!
  private let today = DateOnly(year: 2026, month: 10, day: 7)

  override func setUp() async throws {
    dataDirectoryBefore = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-operations-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    setenv("OHMYMONEY_DATA_DIR", directory.path, 1)
    logs = directory.appendingPathComponent("Logs", isDirectory: true)
    Logbook.shared.open(directory: logs, threshold: .debug)
    environment = AppEnvironment()
    await environment.start(preparing: {
      try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    })
    store = TransactionsStore()
    store.attach(
      try XCTUnwrap(environment.transactions), references: environment.references,
      planning: environment.planning)
    compute = ComputeStore(calendar: .system, rebuildsInline: true)
    compute.onSnapshot = { [store] snapshot in store?.show(snapshot.ledger) }
    suiteName = "ohmymoney-operations-\(UUID().uuidString)"
    defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
  }

  override func tearDown() async throws {
    for window in windows {
      window.contentViewController = nil
      window.close()
    }
    windows = []
    defaults?.removePersistentDomain(forName: suiteName)
    Logbook.shared.close()
    if let environment { await environment.close() }
    if let dataDirectoryBefore {
      setenv("OHMYMONEY_DATA_DIR", dataDirectoryBefore, 1)
    } else {
      unsetenv("OHMYMONEY_DATA_DIR")
    }
    if let directory { try? FileManager.default.removeItem(at: directory) }
  }

  // MARK: Helpers

  private func settle(_ passes: Int = 10) {
    for _ in 0..<passes { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
  }

  private let cafe = CoreKit.Category(kind: .expense, name: "Кафе", quality: .neutral)
  private let shop = CoreKit.Category(kind: .expense, name: "Продукты", quality: .neutral)
  private let place = Place(name: "Кофейня у дома")

  private func entry(
    _ note: String, daysAgo: Int, category: CoreKit.Category? = nil, placeId: UUID? = nil,
    on base: DateOnly? = nil
  ) throws -> TransactionEntry {
    let calendar = CalendarContext.system
    let day = calendar.adding(days: -daysAgo, to: base ?? calendar.day(of: Date()))
    var draft = TransactionDraft(
      occurredAt: calendar.startOfDay(day).addingTimeInterval(12 * 3600),
      amount: AmountE4(whole: 100), note: note)
    draft.placeId = placeId
    draft.normalizeSinglePart()
    draft.parts[0].categoryId = (category ?? shop).id
    return try draft.materialize()
  }

  private func snapshot(
    _ entries: [TransactionEntry], context: SnapshotContext = SnapshotContext()
  ) -> DataSnapshot {
    DataSnapshot.build(
      dataset: Dataset(entries: entries, categories: [cafe, shop], places: [place]),
      calendar: .system, today: environment.today, context: context,
      version: DataVersion(load: 0))
  }

  private func mainWindow(
    actions: OperationActions = OperationActions(), on section: SidebarItem = .section(.overview),
    operations: OperationsScreenState = OperationsScreenState(), width: CGFloat = 980
  ) -> NSWindow {
    let deps = AppDependencies(environment: environment, store: store, compute: compute)
    let root = AppScenes.root(deps, window: .main, launches: false) { deps in
      MainWindow(
        deps: deps, actions: actions, opensDetails: false, selection: section,
        operations: operations)
    }
    .environment(\.windowWidth, width)
    .defaultAppStorage(defaults)
    let controller = NSHostingController(rootView: root)
    let window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: width, height: 680),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentViewController = controller
    // The controller sizes the window to its content; the window of the test has its own size.
    window.setContentSize(CGSize(width: width, height: 680))
    window.orderFront(nil)
    windows.append(window)
    settle(20)
    return window
  }

  private func shown(_ section: String) -> Bool {
    Logbook.shared.lines().contains {
      $0.contains(" section.shown ") && $0.hasSuffix(" window=main section=\(section)")
    }
  }

  private static func russian(_ key: String, table: String = "Common") -> String {
    Bundle.main.path(forResource: "ru", ofType: "lproj").flatMap(Bundle.init(path:))?
      .localizedString(forKey: key, value: nil, table: table) ?? key
  }

  // MARK: The sidebar and the ways in

  /// «Операции» stands right under «Обзор», in place of «Траты»; Overview lists no operations
  /// under its cards — it floats no selection bar — and «Операции» does.
  func testOperationsStandsUnderOverviewInPlaceOfSpending() {
    XCTAssertEqual(
      MainWindow.Section.allCases,
      [.overview, .operations, .planning, .debts, .calendar, .capital, .purchases])
    XCTAssertEqual(Self.russian(MainWindow.Section.operations.titleKey), "Операции")
    XCTAssertEqual(
      environment.language(MainWindow.Section.operations.titleKey).isEmpty, false)
    XCTAssertEqual(MainWindow.Section.operations.shortcutIndex, 4)
    XCTAssertEqual(MainWindow.Section.operations.rawValue, "operations")
    XCTAssertFalse(SidebarItem.section(.overview).listsOperations)
    XCTAssertTrue(SidebarItem.section(.operations).listsOperations)
    // `--section spending` of the recipes written for «Траты» still finds it.
    XCTAssertEqual(MainWindow.Section.named("spending"), .operations)
    XCTAssertEqual(MainWindow.Section.named("operations"), .operations)
    XCTAssertEqual(MainWindow.Section.named("planning"), .planning)
    XCTAssertNil(MainWindow.Section.named("transactions"))
  }

  /// The English name is «Transactions», like the menu item of ⌘⇧T.
  func testTheEnglishNameIsTransactions() {
    let english = Bundle.main.path(forResource: "en", ofType: "lproj").flatMap(Bundle.init(path:))
    XCTAssertEqual(
      english?.localizedString(forKey: "section.operations", value: nil, table: "Common"),
      "Transactions")
    XCTAssertEqual(Self.russian("window.transactions"), "Операции")
  }

  /// ⌘4 is an item of the menu bar, and what it posts brings «Операции» on screen.
  func testCommandFourOpensOperations() throws {
    let four = Self.items(NSApp.mainMenu).filter {
      $0.keyEquivalent == "4"
        && $0.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask) == .command
    }
    XCTAssertEqual(four.count, 1, "⌘4: \(four.map(\.title))")
    XCTAssertTrue(
      [Self.russian("section.operations"), "Transactions"].contains(four.first?.title ?? ""),
      "⌘4 is «\(four.first?.title ?? "")»")

    compute.applyLight(snapshot([try entry("кофе", daysAgo: 0)]))
    _ = mainWindow()
    XCTAssertTrue(shown("overview"))
    NotificationCenter.default.post(name: .selectSection, object: 4)
    settle()
    XCTAssertTrue(shown("operations"), "⌘4 did not bring «Операции»")
  }

  /// ⌘⇧T, ⌘F, the toolbar and the reconciliation come to «Операции» of the main window: there is
  /// no window of Transactions any more, and one item of the menu bar answers ⌘⇧T.
  func testTheWaysInChooseOperationsOfTheMainWindow() throws {
    let shiftT = Self.items(NSApp.mainMenu).filter {
      $0.keyEquivalent.lowercased() == "t"
        && $0.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask)
          == [.command, .shift]
    }
    XCTAssertEqual(shiftT.count, 1, "⌘⇧T: \(shiftT.map(\.title))")

    compute.applyLight(snapshot([try entry("кофе", daysAgo: 0)]))
    _ = mainWindow()
    XCTAssertTrue(shown("overview"))
    OperationsScreenOpening.choose()
    settle()
    XCTAssertTrue(shown("operations"), "⌘⇧T did not bring «Операции»")
    // `--open transactions` of the recipes opens no window of its own.
    XCTAssertTrue(LaunchOptions.Window.allCases.contains(.transactions))
  }

  /// ↓ in the empty line over Overview: «Операции» opens and its newest row is selected.
  func testDownInTheLineOverOverviewOpensOperationsOnTheNewestRow() throws {
    let newest = try entry("новая", daysAgo: 0)
    compute.applyLight(snapshot([try entry("старая", daysAgo: 3), newest]))
    let actions = OperationActions()
    _ = mainWindow(actions: actions)
    XCTAssertTrue(shown("overview"))
    NotificationCenter.default.post(name: .walkOperationsList, object: nil)
    settle(30)
    XCTAssertTrue(shown("operations"), "↓ over Overview did not open «Операции»")
    XCTAssertEqual(actions.selection, [newest.id], "the newest row is not the one selected")
  }

  // MARK: The search and the filters

  /// The filters start on the whole history: the table shows its newest months, and the search
  /// finds words, categories and places through all of it — a coffee of four months ago too.
  func testTheSearchLooksThroughTheWholeHistory() throws {
    let old = try entry("кофе давний", daysAgo: 120)
    let recent = try entry("кофе", daysAgo: 1)
    let bread = try entry("хлеб", daysAgo: 2)
    let latte = try entry("латте", daysAgo: 3, category: cafe)
    let bun = try entry("булка", daysAgo: 4, placeId: place.id)
    let ledger = snapshot([old, recent, bread, latte, bun]).ledger
    var filters = TransactionFilters(today: environment.today)
    XCTAssertEqual(filters.period, .allTime)
    XCTAssertEqual(filters.activeCount, 0)
    func ids(_ search: String) -> Set<UUID> {
      filters.search = search
      return TransactionListing.build(
        matching: filters.entryFilter(today: environment.today), in: ledger
      ).visibleIds
    }
    XCTAssertEqual(ids(""), [old.id, recent.id, bread.id, latte.id, bun.id])
    XCTAssertEqual(ids("кофе"), [old.id, recent.id, bun.id], "«Кофейня у дома» too")
    XCTAssertEqual(ids("КАФЕ"), [latte.id], "by the category")
    XCTAssertEqual(ids("булка дома"), [bun.id], "by the place, every word")
    XCTAssertEqual(ids("булка кафе"), [])
    XCTAssertEqual(ids("  ").count, 5, "a cleared search is no search")
  }

  /// «Фильтры · N» counts what narrows the table, the search aside; «Сбросить» brings back the
  /// whole history.
  func testTheFiltersCountWhatNarrowsTheTable() {
    var filters = TransactionFilters(today: environment.today)
    filters.search = "кофе"
    XCTAssertEqual(filters.activeCount, 0, "the search is not a filter")
    filters.period = .thisMonth
    filters.setKind(.expense, tree: [shop])
    filters.setCategory(shop.id)
    filters.placeId = place.id
    filters.quality = .bad
    XCTAssertEqual(filters.activeCount, 5)
    XCTAssertTrue(filters.canReset)
    filters.reset()
    XCTAssertEqual(filters.period, .allTime)
    XCTAssertEqual(filters.activeCount, 0)
    XCTAssertEqual(filters.search, "")
    XCTAssertFalse(filters.canReset)
  }

  // MARK: The columns

  /// The standard table: every column but the event, in their order, the description and the
  /// amount first after the time.
  func testTheStandardColumns() {
    let layout = OperationColumnLayout.standard
    XCTAssertEqual(
      layout.visible,
      [
        .time, .description, .amount, .category, .account, .place, .forWhom, .quality, .cashback,
        .note,
      ])
    XCTAssertFalse(layout.isShown(.event))
    XCTAssertEqual(OperationColumnLayout(storage: nil), .standard)
    XCTAssertEqual(OperationColumnLayout(storage: ""), .standard)
    XCTAssertEqual(OperationColumnLayout(storage: layout.storage), .standard)
    XCTAssertEqual(layout.width(of: .description), OperationColumn.description.standardWidth)
    XCTAssertEqual(OperationColumnLayout.storageKey, "operations.columns")
    // Every column has its title in both languages.
    for column in OperationColumn.allCases {
      XCTAssertNotEqual(
        Self.russian(column.titleKey, table: "Transactions"), column.titleKey, "\(column)")
    }
  }

  /// What «Настроить столбцы…» changes is kept as text and read back the same; the description
  /// and the amount are never hidden; a width stays within its column's bounds.
  func testTheLayoutIsKeptAndReadBack() {
    var layout = OperationColumnLayout.standard
    layout.setShown(false, .place)
    layout.setShown(true, .event)
    layout.setShown(false, .description)
    layout.setShown(false, .amount)
    layout.move(.note, by: -1)
    layout.move(.time, by: -1)
    layout.setWidth(260, of: .description)
    layout.setWidth(5, of: .amount)
    layout.setWidth(10_000, of: .note)
    XCTAssertTrue(layout.isShown(.description))
    XCTAssertTrue(layout.isShown(.amount))
    XCTAssertFalse(layout.isShown(.place))
    XCTAssertTrue(layout.isShown(.event))
    XCTAssertEqual(layout.order.first, .time, "the first column moves no further up")
    XCTAssertEqual(Array(layout.order.suffix(3)), [.note, .cashback, .event])
    XCTAssertEqual(layout.width(of: .description), 260)
    XCTAssertEqual(layout.width(of: .amount), OperationColumn.amount.minimumWidth)
    XCTAssertEqual(layout.width(of: .note), OperationColumn.note.maximumWidth)
    XCTAssertEqual(OperationColumnLayout(storage: layout.storage), layout)
    XCTAssertTrue(layout.storage.contains("-place"))
    XCTAssertTrue(layout.storage.contains("description:260"))
  }

  /// A text written by another version: an unknown name goes, a repeated one keeps its first
  /// place, a column it does not name comes at its standard place, «-description» stays shown.
  func testALayoutOfAnotherVersionIsReadSafely() {
    let layout = OperationColumnLayout(
      storage: "amount:120,-description,mystery:40,time,amount:300,-quality, place :90")
    XCTAssertEqual(Array(layout.order.prefix(3)), [.amount, .description, .time])
    XCTAssertTrue(layout.isShown(.description))
    XCTAssertFalse(layout.isShown(.quality))
    XCTAssertEqual(layout.width(of: .amount), 120)
    XCTAssertEqual(layout.width(of: .place), 90)
    XCTAssertEqual(Set(layout.order), Set(OperationColumn.allCases))
    XCTAssertEqual(layout.order.count, OperationColumn.allCases.count)
    XCTAssertFalse(layout.isShown(.event), "a column not named comes with its standard visibility")
    // «category» stands after «time» — the last column before it in the standard order.
    let index = layout.order.firstIndex(of: .category)
    XCTAssertEqual(index.map { layout.order[$0 - 1] }, .time)
  }

  /// A drag in the list of the sheet moves the rows where they are dropped.
  func testADragMovesTheColumns() {
    var layout = OperationColumnLayout.standard
    layout.move(fromOffsets: [0], toOffset: 3)
    XCTAssertEqual(Array(layout.order.prefix(3)), [.description, .amount, .time])
    layout.move(fromOffsets: [9, 10], toOffset: 0)
    XCTAssertEqual(Array(layout.order.prefix(2)), [.note, .event])
    XCTAssertEqual(layout.order.count, OperationColumn.allCases.count)
  }

  /// The table shows the columns of the layout kept on this Mac, and a row shows the account,
  /// the comment and the cashback of its operation.
  func testTheTableShowsTheColumnsOfTheLayout() throws {
    var layout = OperationColumnLayout.standard
    layout.setShown(false, .forWhom)
    layout.setShown(true, .event)
    defaults.set(layout.storage, forKey: OperationColumnLayout.storageKey)
    var coffee = try entry("кофе", daysAgo: 0)
    coffee.transaction.cashback = Money(amount: AmountE4(whole: 3), currency: .rub)
    compute.applyLight(snapshot([coffee]))
    let window = mainWindow(on: .section(.operations), width: 1200)
    let table = try XCTUnwrap(Self.tables(in: window.contentView).first, "the table")
    settle(20)
    XCTAssertEqual(table.tableColumns.count, layout.visible.count)
    let listing = TransactionListing.build([coffee.id], ledger: snapshot([coffee]).ledger)
    let row = try XCTUnwrap(listing.sections.first?.rows.first)
    XCTAssertEqual(row.cashback, Money(amount: AmountE4(whole: 3), currency: .rub))
    XCTAssertEqual(row.note, "кофе")
  }

  // MARK: Editing

  /// With the entry line, a double click edits beside the table; in a screen too narrow for
  /// the column, in the sheet.
  func testADoubleClickEditsBesideTheTableOrInTheSheet() throws {
    let before = environment.entryStyle
    defer { environment.entryStyle = before }
    environment.entryStyle = .line
    let coffee = try entry("кофе", daysAgo: 0)
    compute.applyLight(snapshot([coffee]))
    let actions = OperationActions()
    let state = OperationsScreenState()
    _ = mainWindow(actions: actions, on: .section(.operations), operations: state, width: 1200)
    XCTAssertNotNil(actions.opensEditor, "the screen takes the double click")
    actions.edit([coffee.id], store: store)
    settle()
    XCTAssertEqual(state.editor?.id, coffee.id, "the editor beside the table")
    XCTAssertNil(actions.editing)

    state.editor = nil
    let narrowActions = OperationActions()
    let narrow = OperationsScreenState()
    _ = mainWindow(
      actions: narrowActions, on: .section(.operations), operations: narrow, width: 760)
    narrowActions.edit([coffee.id], store: store)
    settle()
    XCTAssertNil(narrow.editor)
    XCTAssertEqual(narrowActions.editing?.id, coffee.id, "the sheet, with no room beside")
  }

  /// With the form at the side, a double click selects the operation and the form edits it:
  /// nothing opens beside the table.
  func testWithTheFormAtTheSideTheFormEdits() throws {
    let before = environment.entryStyle
    defer { environment.entryStyle = before }
    environment.entryStyle = .form
    let coffee = try entry("кофе", daysAgo: 0)
    compute.applyLight(snapshot([coffee]))
    let actions = OperationActions()
    let state = OperationsScreenState()
    _ = mainWindow(actions: actions, on: .section(.operations), operations: state, width: 1200)
    actions.edit([coffee.id], store: store)
    settle()
    XCTAssertNil(state.editor)
    XCTAssertNil(actions.editing)
    XCTAssertEqual(actions.selection, [coffee.id], "the form follows the selection")
  }

  /// The filters, the search and the editor stay while another screen is shown.
  func testTheScreenKeepsItsStateAcrossScreens() throws {
    let coffee = try entry("кофе", daysAgo: 0)
    compute.applyLight(snapshot([coffee]))
    let state = OperationsScreenState()
    state.filters.search = "кофе"
    _ = mainWindow(on: .section(.operations), operations: state)
    NotificationCenter.default.post(name: .selectSection, object: 1)
    settle()
    NotificationCenter.default.post(name: .selectSection, object: 4)
    settle()
    XCTAssertEqual(state.filters.search, "кофе")
  }

  private static func items(_ menu: NSMenu?) -> [NSMenuItem] {
    (menu?.items ?? []).flatMap { [$0] + items($0.submenu) }
  }

  private static func tables(in view: NSView?) -> [NSTableView] {
    guard let view else { return [] }
    return view.subviews.flatMap { subview -> [NSTableView] in
      ((subview as? NSTableView).map { [$0] } ?? []) + tables(in: subview)
    }
  }

  // MARK: «≈»

  private func context(usd: Decimal, on day: DateOnly) -> SnapshotContext {
    var context = SnapshotContext()
    context.rubPerUnit[.usd] = usd
    context.rateDays[.usd] = day
    return context
  }

  /// «кофе 5 usd» before Enter: «≈ 475.00 ₽» at the bank's last rate, with its day when it is
  /// not today's.
  func testTheLineShowsTheApproximateRublesBeforeEnter() {
    compute.applyLight(snapshot([], context: context(usd: 95, on: environment.today)))
    let rubles = environment.money.exact(AmountE4(whole: 475), currency: .rub)
    XCTAssertEqual(
      ApproximateText.of(
        amount: AmountE4(whole: 5), currency: .usd, environment: environment, compute: compute),
      "≈ " + rubles)

    let earlier = environment.calendar.adding(days: -2, to: environment.today)
    compute.applyLight(snapshot([], context: context(usd: 95, on: earlier)))
    let text = ApproximateText.of(
      amount: AmountE4(whole: 5), currency: .usd, environment: environment, compute: compute)
    XCTAssertEqual(
      text,
      "≈ " + rubles + " · "
        + environment.language.format(
          "approximate.rateOf", table: "Transactions", environment.dates.dayAndMonth(earlier)))
    XCTAssertNil(
      ApproximateText.of(
        amount: AmountE4(whole: 500), currency: .rub, environment: environment, compute: compute),
      "rubles need no «≈»")
  }

  /// The row of a dollar expense at the bank's rate: grey «≈ … ₽», «курс от …» when the rate is
  /// of another day; the rate typed by hand: the exact «= 500.00 ₽», no «≈».
  func testTheRowShowsApproximateRublesUntilTheRateIsTyped() throws {
    compute.applyLight(snapshot([]))
    var dollars = Transaction(
      kind: .expense, occurredAt: environment.calendar.startOfDay(environment.today),
      currency: .usd, amountE4: AmountE4(whole: 5), amountRubE4: AmountE4(whole: 475))
    dollars.rate = 95
    dollars.rateSource = .cbr
    dollars.rateDate = environment.today
    let rubles = environment.money.exact(AmountE4(whole: 475), currency: .rub)
    XCTAssertEqual(
      ApproximateText.of(dollars, environment: environment, compute: compute), "≈ " + rubles)

    let friday = environment.calendar.adding(days: -3, to: environment.today)
    dollars.rateDate = friday
    XCTAssertEqual(
      ApproximateText.of(dollars, environment: environment, compute: compute),
      "≈ " + rubles + " · "
        + environment.language.format(
          "approximate.rateOf", table: "Transactions", environment.dates.dayAndMonth(friday)))
    XCTAssertTrue(Self.russian("approximate.rateOf", table: "Transactions").contains("курс от"))

    // The editor: «100» typed into «Курс» — the rate is the owner's, the rubles exact.
    let model = EntryDraftModel(environment: environment)
    model.reload()
    model.draft.currency = .usd
    model.draft.amount = AmountE4(whole: 5)
    model.draft.note = "кофе"
    model.draft.normalizeSinglePart()
    model.setManualRate("100")
    let typed = try model.draftForSaving.materialize(
      rublesConverter: environment.rublesConverter(for: model.draft)
    ).transaction
    XCTAssertEqual(typed.rateSource, .manual)
    XCTAssertEqual(typed.amountRubE4, AmountE4(whole: 500))
    XCTAssertEqual(
      ApproximateText.of(typed, environment: environment, compute: compute),
      "= " + environment.money.exact(AmountE4(whole: 500), currency: .rub))
  }
}
