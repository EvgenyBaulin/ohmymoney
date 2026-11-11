import AppCore
import AppDatabase
import AppKit
import SwiftUI
import XCTest

@testable import OhMyMoney

/// «Операции» against the design: the numbers of the frames (Mac 5:35437, tablet 5:76347, phone
/// 5:7984), the rules of what the header shows — the chips, the month, «Фильтры · N» —, the head
/// of a day, and the screen itself at the size of the master frame with the six operations the
/// frame draws: measured against the frame, a picture of it kept with the result.
@MainActor
final class OperationsFigmaTests: XCTestCase {
  private var environment: AppEnvironment!
  private var store: TransactionsStore!
  private var compute: ComputeStore!
  private var windows: [NSWindow] = []
  private var directory: URL!
  private var dataDirectoryBefore: String?
  private var suiteName: String!
  private var defaults: UserDefaults!
  private var languageBefore: AppLanguage.Choice?
  private var styleBefore: EntryStyle?

  private struct NotFound: Error {}

  private let today = DateOnly(year: 2026, month: 11, day: 10)

  override func setUp() async throws {
    dataDirectoryBefore = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-operations-figma-\(UUID().uuidString)", isDirectory: true)
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
    compute.onSnapshot = { [store] snapshot in store?.show(snapshot.ledger) }
    suiteName = "ohmymoney-operations-figma-\(UUID().uuidString)"
    defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    languageBefore = environment.language.choice
    environment.language.choice = .russian
    styleBefore = environment.entryStyle
    environment.entryStyle = .line
  }

  override func tearDown() async throws {
    for window in windows {
      window.contentViewController = nil
      window.close()
    }
    windows = []
    if let languageBefore { environment?.language.choice = languageBefore }
    if let styleBefore { environment?.entryStyle = styleBefore }
    defaults?.removePersistentDomain(forName: suiteName)
    if let environment { await environment.close() }
    if let dataDirectoryBefore {
      setenv("OHMYMONEY_DATA_DIR", dataDirectoryBefore, 1)
    } else {
      unsetenv("OHMYMONEY_DATA_DIR")
    }
    if let directory { try? FileManager.default.removeItem(at: directory) }
  }

  // MARK: The numbers of the frames

  /// The header, the chips, the month and the card of the Mac's frame (5:35437).
  func testTheMacNumbersAreTheFrames() {
    XCTAssertEqual(OperationsMetrics.pageSide, 24)
    XCTAssertEqual(OperationsMetrics.headerTop, 14)
    XCTAssertEqual(OperationsMetrics.headerBottom, 10)
    XCTAssertEqual(
      OperationsMetrics.headerTop + OperationsMetrics.controlHeight - 2
        + OperationsMetrics.headerBottom, 56, "the title row is 56 tall")
    XCTAssertEqual(OperationsMetrics.searchWidth, 220)
    XCTAssertEqual(OperationsMetrics.controlHeight, 34)
    XCTAssertEqual(OperationsMetrics.controlRadius, 10)
    XCTAssertEqual(OperationsMetrics.searchHorizontal, 12)
    XCTAssertEqual(OperationsMetrics.searchIcon, 15)
    XCTAssertEqual(OperationsMetrics.searchIconGap, 8)
    XCTAssertEqual(OperationsMetrics.headerGap, 10)
    XCTAssertEqual(OperationsMetrics.chipsTop, 6)
    XCTAssertEqual(OperationsMetrics.chipsToTable, 16)
    XCTAssertEqual(OperationsMetrics.chipGap, 8)
    XCTAssertEqual(OperationsMetrics.chipHorizontal, 14)
    XCTAssertEqual(OperationsMetrics.chipVertical, 6)
    XCTAssertEqual(OperationsMetrics.monthHorizontal, 12)
    XCTAssertEqual(OperationsMetrics.monthVertical, 6)
    XCTAssertEqual(OperationsMetrics.monthChevron, 13)
    XCTAssertEqual(OperationsMetrics.monthGap, 8)
    XCTAssertEqual(OperationsMetrics.cardRadius, 12)
    XCTAssertEqual(OperationsMetrics.cardVertical, 4)
    XCTAssertEqual(OperationsMetrics.cardShadowY, 4)
    XCTAssertEqual(OperationsMetrics.cardShadowBlur, 16)
    XCTAssertEqual(OperationsMetrics.cardShadowOpacity, 0.03)
    XCTAssertEqual(OperationsCard.radius, 12)
  }

  /// The column of the editor beside the table (6:89246): 360 wide, 16 inside, its head 17 bold
  /// with the round × of 28.
  func testTheEditorColumnIsTheFrames() {
    XCTAssertEqual(InspectorMetrics.width, 360)
    XCTAssertEqual(TransactionInspector.idealWidth, InspectorMetrics.width)
    XCTAssertEqual(InspectorMetrics.padding, 16)
    XCTAssertEqual(InspectorMetrics.close, 28)
    XCTAssertEqual(InspectorMetrics.title, AppFont.system(size: 17, weight: .bold))
  }

  /// A row and the head of a day of the Mac's table: 18 at the sides, 9 above and below, the
  /// mark 32 with a 16-pt drawing 12 from the words, the columns 160 / 140 / 70 / 120, the day
  /// 10 above and 6 below.
  func testTheRowAndTheDayOfTheTableAreTheFrames() {
    XCTAssertEqual(OperationsMetrics.rowHorizontal, 18)
    XCTAssertEqual(OperationsMetrics.rowVertical, 9)
    XCTAssertEqual(OperationsMetrics.columnGap, 12)
    XCTAssertEqual(OperationsMetrics.badge, 32)
    XCTAssertEqual(OperationsMetrics.badgeSymbol, 16)
    XCTAssertEqual(OperationsMetrics.badgeGap, 12)
    XCTAssertEqual(
      OperationsMetrics.rowVertical * 2 + OperationsMetrics.badge, 50, "a row is 50 tall")
    XCTAssertEqual(OperationsMetrics.categoryWidth, 160)
    XCTAssertEqual(OperationsMetrics.accountWidth, 140)
    XCTAssertEqual(OperationsMetrics.timeWidth, 70)
    XCTAssertEqual(OperationsMetrics.amountWidth, 120)
    XCTAssertEqual(OperationColumn.category.standardWidth, 160)
    XCTAssertEqual(OperationColumn.account.standardWidth, 140)
    XCTAssertEqual(OperationColumn.time.standardWidth, 70)
    XCTAssertEqual(OperationColumn.amount.standardWidth, 120)
    // The description takes the rest of a row of 1156 (the card of 1158 inside its hairline):
    // 1156 − 2 · 18 − 4 · 12 − the four.
    XCTAssertEqual(
      OperationColumn.description.standardWidth, 1156 - 36 - 48 - 160 - 140 - 70 - 120)
    XCTAssertEqual(OperationsMetrics.dayTop, 10)
    XCTAssertEqual(OperationsMetrics.dayBottom, 6)
  }

  /// The tablet's (5:76347) and the phone's (5:7984) own numbers.
  func testTheTabletAndThePhoneNumbersAreTheFrames() {
    XCTAssertEqual(OperationsMetrics.padPageSide, 32)
    XCTAssertEqual(OperationsMetrics.padSearchWidth, 240)
    XCTAssertEqual(OperationsMetrics.padSearchHorizontal, 14)
    XCTAssertEqual(OperationsMetrics.padSearchIcon, 16)
    XCTAssertEqual(OperationsMetrics.padStackGap, 16)
    XCTAssertEqual(OperationsMetrics.padChipHorizontal, 16)
    XCTAssertEqual(OperationsMetrics.padChipVertical, 7)
    XCTAssertEqual(OperationsMetrics.padMonthHorizontal, 14)
    XCTAssertEqual(OperationsMetrics.padMonthVertical, 7)
    XCTAssertEqual(OperationsMetrics.padMonthChevron, 14)
    XCTAssertEqual(OperationsMetrics.padCardRadius, 22)
    XCTAssertEqual(OperationsMetrics.padRowVertical, 8)
    XCTAssertEqual(OperationsMetrics.padDayTop, 8)
    XCTAssertEqual(OperationsMetrics.padDayBottom, 4)
    XCTAssertEqual(OperationsMetrics.phonePageSide, 16)
    XCTAssertEqual(OperationsMetrics.phoneStackGap, 10)
    XCTAssertEqual(OperationsMetrics.phoneDayInset, 6)
    XCTAssertEqual(OperationsMetrics.phoneDayGap, 4)
    XCTAssertEqual(OperationsMetrics.phoneCardRadius, 22)
    XCTAssertEqual(OperationsMetrics.phoneShadowY, 6)
    XCTAssertEqual(OperationsMetrics.phoneShadowBlur, 20)
    XCTAssertEqual(OperationsMetrics.phoneShadowOpacity, 0.05)
    XCTAssertEqual(OperationsMetrics.phoneRowHorizontal, 14)
    XCTAssertEqual(OperationsMetrics.phoneRowVertical, 10)
    XCTAssertEqual(OperationsMetrics.phoneBadge, 36)
    XCTAssertEqual(OperationsMetrics.phoneBadgeSymbol, 18)
    XCTAssertEqual(
      OperationsMetrics.phoneRowVertical * 2 + OperationsMetrics.phoneBadge, 56,
      "a row of the phone is 56 tall")
  }

  // MARK: What the header shows

  /// ‹ from the whole history shows the current month, then the ones before it; › goes back up
  /// and from the current month returns to the whole history. The current and the previous month
  /// are the filters' own periods; an earlier one is its days.
  func testTheMonthStepsThroughTheHistory() {
    var filters = TransactionFilters(today: today)
    XCTAssertEqual(filters.period, .allTime)
    XCTAssertNil(OperationsMonth.shown(in: filters, today: today))
    XCTAssertFalse(OperationsMonth.canGoForward(filters, today: today))

    OperationsMonth.back(&filters, today: today)
    XCTAssertEqual(filters.period, .thisMonth)
    XCTAssertEqual(OperationsMonth.shown(in: filters, today: today), today.monthKey)
    OperationsMonth.back(&filters, today: today)
    XCTAssertEqual(filters.period, .lastMonth)
    OperationsMonth.back(&filters, today: today)
    XCTAssertEqual(filters.period, .custom)
    XCTAssertEqual(filters.customStart, DateOnly(year: 2026, month: 9, day: 1))
    XCTAssertEqual(filters.customEnd, DateOnly(year: 2026, month: 9, day: 30))
    XCTAssertEqual(
      OperationsMonth.shown(in: filters, today: today), MonthKey(year: 2026, month: 9))
    OperationsMonth.back(&filters, today: today)
    XCTAssertEqual(filters.customEnd, DateOnly(year: 2026, month: 8, day: 31))

    XCTAssertTrue(OperationsMonth.canGoForward(filters, today: today))
    OperationsMonth.forward(&filters, today: today)
    XCTAssertEqual(
      OperationsMonth.shown(in: filters, today: today), MonthKey(year: 2026, month: 9))
    OperationsMonth.forward(&filters, today: today)
    XCTAssertEqual(filters.period, .lastMonth)
    OperationsMonth.forward(&filters, today: today)
    XCTAssertEqual(filters.period, .thisMonth)
    OperationsMonth.forward(&filters, today: today)
    XCTAssertEqual(filters.period, .allTime, "past the current month is the whole history")
  }

  func testMonthNavigationKeepsSearchAndOtherFilters() {
    let state = OperationsScreenState()
    XCTAssertEqual(state.filters.period, .allTime)
    XCTAssertEqual(OperationsMonth.otherFilters(state.filters), 0)
    var filters = TransactionFilters(today: today)
    filters.search = "кофе"
    filters.setKind(.expense, tree: [])
    filters.quality = .bad
    filters.placeId = UUID()
    let original = filters
    for _ in 0..<3 { OperationsMonth.back(&filters, today: today) }
    XCTAssertEqual(filters.period, .custom)
    XCTAssertEqual(filters.search, original.search)
    XCTAssertEqual(filters.kind, original.kind)
    XCTAssertEqual(filters.quality, original.quality)
    XCTAssertEqual(filters.placeId, original.placeId)
    XCTAssertEqual(OperationsMonth.otherFilters(filters), 2)
    for _ in 0..<3 { OperationsMonth.forward(&filters, today: today) }
    XCTAssertEqual(filters.period, .allTime)
    XCTAssertEqual(filters.search, original.search)
    XCTAssertEqual(filters.kind, original.kind)
    XCTAssertEqual(filters.quality, original.quality)
    XCTAssertEqual(filters.placeId, original.placeId)
    XCTAssertEqual(OperationsMonth.otherFilters(filters), 2)
  }

  /// February of a leap year ends on the 29th; a custom range that is not a whole month is no
  /// month, and ‹ from it shows the current one.
  func testOnlyAWholeMonthIsAMonth() {
    var filters = TransactionFilters(today: today)
    OperationsMonth.show(MonthKey(year: 2028, month: 2), in: &filters, today: today)
    XCTAssertEqual(filters.customEnd, DateOnly(year: 2028, month: 2, day: 29))
    filters.customEnd = DateOnly(year: 2028, month: 2, day: 28)
    XCTAssertNil(OperationsMonth.shown(in: filters, today: today))
    OperationsMonth.back(&filters, today: today)
    XCTAssertEqual(filters.period, .thisMonth)
    filters.period = .thisYear
    XCTAssertNil(OperationsMonth.shown(in: filters, today: today))
  }

  /// The capsule says the month as a title — «Ноябрь 2026» —, or the period it shows.
  func testTheCapsuleSaysTheMonthOrThePeriod() {
    var filters = TransactionFilters(today: today)
    XCTAssertEqual(
      OperationsMonth.title(filters, today: today, environment: environment), "Всё время")
    filters.period = .thisMonth
    XCTAssertEqual(
      OperationsMonth.title(filters, today: today, environment: environment), "Ноябрь 2026")
    filters.period = .lastMonth
    XCTAssertEqual(
      OperationsMonth.title(filters, today: today, environment: environment), "Октябрь 2026")
  }

  /// «Фильтры · N» counts what the chips and the month do not show.
  func testTheFiltersChipCountsOnlyWhatTheRowDoesNotShow() {
    var filters = TransactionFilters(today: today)
    XCTAssertEqual(OperationsMonth.otherFilters(filters), 0)
    filters.period = .thisMonth
    filters.setKind(.expense, tree: [])
    XCTAssertEqual(OperationsMonth.otherFilters(filters), 0, "the month and a chip show these")
    filters.quality = .bad
    filters.placeId = UUID()
    XCTAssertEqual(OperationsMonth.otherFilters(filters), 2)
  }

  /// A chip (5:35451): the chosen one on the accent tint in the accent's content colour, the
  /// others on the neutral fill in the primary colour; 13 medium either way, so the chosen one
  /// differs in its fill and its trait, not in a colour alone.
  func testAChipIsTheFrames() {
    let theme = AppThemeColors.fallback
    XCTAssertEqual(OperationsChip.fill(selected: true, in: theme), theme.accentTint)
    XCTAssertEqual(OperationsChip.ink(selected: true, in: theme), theme.accentContent)
    XCTAssertEqual(OperationsChip.fill(selected: false, in: theme), theme.fillNeutral)
    XCTAssertEqual(OperationsChip.ink(selected: false, in: theme), theme.contentPrimary)
    XCTAssertEqual(OperationsChip.horizontal, 14)
    XCTAssertEqual(OperationsChip.vertical, 6)
  }

  /// The head of a day: the name in the accent's content colour on the Mac, and one signed
  /// figure — the frame's «−2 650 ₽» and «+118 581 ₽»; a day of transfers says none.
  func testTheHeadOfADaySaysOneSignedFigure() {
    let theme = AppThemeColors.fallback
    XCTAssertEqual(OperationDayHead.nameInk(in: theme), theme.accentContent)
    let money = environment.money
    XCTAssertEqual(
      OperationDayHead.figure(RowTotals(myExpenses: AmountE4(whole: 2_650)), money: money),
      "\u{2212}2,650\u{00A0}₽")
    XCTAssertEqual(
      OperationDayHead.figure(
        RowTotals(myExpenses: AmountE4(whole: 1_419), income: AmountE4(whole: 120_000)),
        money: money),
      "+118,581\u{00A0}₽")
    let mixed = RowTotals(
      myExpenses: AmountE4(whole: 5_000), income: AmountE4(whole: 8_000),
      forOthers: AmountE4(whole: 2_000), moneyReturned: AmountE4(whole: 500))
    XCTAssertEqual(mixed.net, AmountE4(whole: 1_500))
    XCTAssertEqual(OperationDayHead.figure(mixed, money: money), "+1,500\u{00A0}₽")
    XCTAssertNil(OperationDayHead.figure(.zero, money: money))
  }

  /// The header of the table writes the names in capitals, in either language.
  func testTheColumnNamesAreInCapitals() {
    XCTAssertEqual(
      OperationColumn.description.headerTitle(language: environment.language), "ОПИСАНИЕ")
    XCTAssertEqual(OperationColumn.account.headerTitle(language: environment.language), "СЧЁТ")
    environment.language.choice = .english
    XCTAssertEqual(OperationColumn.amount.headerTitle(language: environment.language), "AMOUNT")
  }

  // MARK: The screen at the size of the frame

  private func operation(
    _ note: String, daysAgo: Int, hour: Int, amount: Int64, kind: TransactionKind = .expense,
    category: CoreKit.Category
  ) throws -> TransactionEntry {
    let calendar = CalendarContext.system
    let day = calendar.adding(days: -daysAgo, to: environment.today)
    var draft = TransactionDraft(
      occurredAt: calendar.startOfDay(day).addingTimeInterval(TimeInterval(hour) * 3600),
      amount: AmountE4(whole: amount), note: note)
    draft.kind = kind
    draft.normalizeSinglePart()
    draft.parts[0].categoryId = category.id
    return try draft.materialize()
  }

  private func makeWindow(width: CGFloat, height: CGFloat) throws -> NSWindow {
    let cafe = CoreKit.Category(
      kind: .expense, name: "Кафе", quality: .neutral,
      appearance: CategoryAppearance(icon: "cup.and.saucer", color: "tone1"))
    let food = CoreKit.Category(
      kind: .expense, name: "Продукты", quality: .neutral,
      appearance: CategoryAppearance(icon: "cart", color: "tone2"))
    let ride = CoreKit.Category(
      kind: .expense, name: "Транспорт", quality: .neutral,
      appearance: CategoryAppearance(icon: "car", color: "tone3"))
    let work = CoreKit.Category(
      kind: .income, name: "Заработок", quality: .neutral,
      appearance: CategoryAppearance(icon: "briefcase", color: "tone4"))
    let entries = [
      try operation("Кофе", daysAgo: 0, hour: 14, amount: 250, category: cafe),
      try operation("Магнит", daysAgo: 0, hour: 13, amount: 1_840, category: food),
      try operation("Такси", daysAgo: 0, hour: 9, amount: 560, category: ride),
      try operation(
        "Зарплата", daysAgo: 1, hour: 12, amount: 120_000, kind: .income, category: work),
      try operation("Музыка", daysAgo: 1, hour: 8, amount: 299, category: cafe),
      try operation("Аптека", daysAgo: 1, hour: 19, amount: 1_120, category: food),
    ]
    compute.applyLight(
      DataSnapshot.build(
        dataset: Dataset(entries: entries, categories: [cafe, food, ride, work]),
        calendar: .system, today: environment.today, context: SnapshotContext(),
        version: DataVersion(load: 0)))
    let deps = AppDependencies(environment: environment, store: store, compute: compute)
    let root = AppScenes.root(deps, window: .main, launches: false) { deps in
      MainWindow(
        deps: deps, actions: OperationActions(), opensDetails: false,
        selection: .section(.operations))
    }
    .environment(\.windowWidth, width)
    .defaultAppStorage(defaults)
    let controller = NSHostingController(rootView: root)
    controller.sceneBridgingOptions = [.toolbars]
    let window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: width, height: height),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentViewController = controller
    window.setContentSize(CGSize(width: width, height: height))
    window.toolbarStyle = .unified
    window.orderFront(nil)
    windows.append(window)
    return window
  }

  private func settle(_ window: NSWindow, passes: Int = 30) {
    for _ in 0..<passes {
      window.updateConstraintsIfNeeded()
      window.layoutIfNeeded()
      window.displayIfNeeded()
      RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
  }

  /// The frame of the element with `identifier`, in the window's coordinates (y up).
  private func frame(of identifier: String, in window: NSWindow) throws -> CGRect {
    let deadline = Date().addingTimeInterval(5)
    repeat {
      if let root = window.contentView,
        let found = Self.element(in: root, where: { $0.accessibilityIdentifier?() == identifier }),
        let onScreen = found.accessibilityFrame?(), onScreen.width > 0
      {
        return window.convertFromScreen(onScreen)
      }
      settle(window, passes: 5)
    } while Date() < deadline
    XCTFail("\(identifier) was not found")
    throw NotFound()
  }

  /// The table of «Операции»: the table with the most columns in the window (the sidebar has
  /// one).
  private func operationsTable(in window: NSWindow) throws -> NSTableView {
    let deadline = Date().addingTimeInterval(5)
    repeat {
      var tables: [NSTableView] = []
      if let root = window.contentView { Self.allSubviews(of: root, into: &tables) }
      if let table = tables.max(by: { $0.tableColumns.count < $1.tableColumns.count }),
        table.tableColumns.count > 1, table.numberOfRows > 0
      {
        return table
      }
      settle(window, passes: 5)
    } while Date() < deadline
    XCTFail("the table of the operations never filled")
    throw NotFound()
  }

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

  /// The screen in a window of the master frame (1440 × 900) with the frame's six operations:
  /// the search box 220 × 34 and «Новая операция» 34 tall at the right edge of the page, 24 in
  /// from it; the chips 28 tall under them; the table's columns in the frame's order and widths;
  /// the card of the table 24 from the edge of the page. A picture is kept with the result.
  func testTheScreenAtTheSizeOfTheMasterFrameHasItsNumbers() throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    try TestEnvironment.requireScreen(width: 1_440, height: 900)
    let window = try makeWindow(width: 1_440, height: 900)
    settle(window)
    let table = try operationsTable(in: window)
    settle(window, passes: 20)
    try attachPicture(of: window, named: "Операции 1440 × 900 (Figma 5:35386)")

    let content = try XCTUnwrap(window.contentView).bounds.width
    let search = try frame(of: "operations.searchBox", in: window)
    XCTAssertEqual(search.width, OperationsMetrics.searchWidth, accuracy: 1, "\(search)")
    XCTAssertEqual(search.height, OperationsMetrics.controlHeight, accuracy: 1, "\(search)")
    let add = try frame(of: "operations.add", in: window)
    XCTAssertEqual(add.height, OperationsMetrics.controlHeight, accuracy: 1, "\(add)")
    XCTAssertEqual(
      content - add.maxX, OperationsMetrics.pageSide, accuracy: 1.5,
      "«Новая операция» stands 24 from the edge (\(add))")
    XCTAssertEqual(
      add.minX - search.maxX, OperationsMetrics.headerGap, accuracy: 1.5, "10 between them")
    XCTAssertEqual(search.midY, add.midY, accuracy: 1, "one row")

    let chip = try frame(of: "operations.chip.all", in: window)
    XCTAssertEqual(chip.height, 28, accuracy: 1.5, "a chip is 28 tall (\(chip))")
    XCTAssertEqual(
      search.minY - chip.maxY, OperationsMetrics.headerBottom + OperationsMetrics.chipsTop - 1,
      accuracy: 3, "the chips stand under the title row")
    let month = try frame(of: "operations.month.forward", in: window)
    XCTAssertGreaterThan(month.minX, chip.maxX, "the month is right of the chips")
    XCTAssertEqual(
      content - month.maxX, OperationsMetrics.pageSide + OperationsMetrics.monthHorizontal,
      accuracy: 2, "the month keeps the right edge of the page (\(month))")

    // A row of an operation is 50 tall, as the frame's; row 0 is the head of the day.
    let rows = (0..<table.numberOfRows).map { table.rect(ofRow: $0).height }
    XCTAssertEqual(
      rows.dropFirst().first ?? 0, OperationsMetrics.rowVertical * 2 + OperationsMetrics.badge,
      accuracy: 1, "the rows: \(rows)")

    XCTAssertEqual(
      table.tableColumns.map(\.title),
      ["ОПИСАНИЕ", "КАТЕГОРИЯ", "СЧЁТ", "ВРЕМЯ", "СУММА"])
    let widths = Dictionary(
      uniqueKeysWithValues: table.tableColumns.map { ($0.title, $0.width) })
    XCTAssertEqual(widths["КАТЕГОРИЯ"] ?? 0, OperationsMetrics.categoryWidth, accuracy: 24)
    XCTAssertEqual(widths["СЧЁТ"] ?? 0, OperationsMetrics.accountWidth, accuracy: 24)
    let card = try XCTUnwrap(table.enclosingScrollView).convert(
      try XCTUnwrap(table.enclosingScrollView).bounds, to: nil)
    XCTAssertEqual(
      content - card.maxX, OperationsMetrics.pageSide, accuracy: 1.5,
      "the card of the table stands 24 from the edge (\(card))")
    XCTAssertEqual(
      search.minY - card.maxY,
      OperationsMetrics.headerBottom + OperationsMetrics.chipsTop + 28
        + OperationsMetrics.chipsToTable + OperationsMetrics.cardVertical - 1,
      accuracy: 4, "the table starts 16 under the chips, inside the card's 4")
  }

  func testTheMarkedCategoriesOfTheFrameKeepTheirSymbolsAndTonesInTheListing() throws {
    let window = try makeWindow(width: 1_024, height: 768)
    settle(window)
    let snapshot = try XCTUnwrap(compute.snapshot)
    let rows = TransactionListing.build(matching: .none, in: snapshot.ledger)
      .sections.flatMap(\.rows)
    XCTAssertEqual(rows.count, 6)
    XCTAssertEqual(
      rows.compactMap { $0.categoryMark?.icon }.sorted(),
      ["briefcase", "car", "cart", "cart", "cup.and.saucer", "cup.and.saucer"])
    XCTAssertEqual(
      rows.compactMap { $0.categoryMark?.tone.key }.sorted(),
      ["tone1", "tone1", "tone2", "tone2", "tone3", "tone4"])
    let table = try operationsTable(in: window)
    XCTAssertEqual(
      table.rect(ofRow: 1).height, OperationsMetrics.rowVertical * 2 + OperationsMetrics.badge,
      accuracy: 1, "category marks keep the frame's 50-point rows")
  }

  func testTheVisibleMonthCapsuleStartsAtAllTimeAndReturnsToIt() throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    let window = try makeWindow(width: 1_024, height: 768)
    settle(window)
    let root = try XCTUnwrap(window.contentView)
    func element(_ id: String) -> AnyObject? {
      Self.element(in: root) { $0.accessibilityIdentifier?() == id }
    }
    func expectTitle(_ expected: String) throws {
      let deadline = Date().addingTimeInterval(5)
      var actual: String?
      repeat {
        // Called by selector: on an untyped node `accessibilityValue` is ambiguous in Swift.
        let month = element("operations.month") as? NSObject
        actual =
          Self.text(month, "accessibilityValue") ?? Self.text(month, "accessibilityLabel")
          ?? Self.text(month, "accessibilityTitle")
        if actual == expected { break }
        settle(window, passes: 2)
      } while Date() < deadline
      XCTAssertEqual(actual, expected)
      XCTAssertNil(element("operations.filters"), "period and kind need no extra filters chip")
    }
    try expectTitle("Всё время")
    let back = try XCTUnwrap(element("operations.month.back"))
    let forward = try XCTUnwrap(element("operations.month.forward"))
    let forwardObject = try XCTUnwrap(forward as? NSObject)
    XCTAssertEqual(
      WindowAccessibility.attribute(forwardObject, "isAccessibilityEnabled") as? Bool, false)
    _ = back.accessibilityPerformPress?()
    try expectTitle(environment.dates.monthTitle(environment.today.monthKey))
    _ = back.accessibilityPerformPress?()
    try expectTitle(environment.dates.monthTitle(environment.today.monthKey.previous))
    _ = forward.accessibilityPerformPress?()
    try expectTitle(environment.dates.monthTitle(environment.today.monthKey))
    _ = forward.accessibilityPerformPress?()
    try expectTitle("Всё время")
  }

  private static func allSubviews<V: NSView>(of view: NSView, into found: inout [V]) {
    if let match = view as? V { found.append(match) }
    for subview in view.subviews { allSubviews(of: subview, into: &found) }
  }

  private static func text(_ node: NSObject?, _ getter: String) -> String? {
    let selector = NSSelectorFromString(getter)
    guard let node, node.responds(to: selector) else { return nil }
    return node.perform(selector)?.takeUnretainedValue() as? String
  }

  private static func element(
    in node: AnyObject, depth: Int = 0, where matches: (AnyObject) -> Bool
  ) -> AnyObject? {
    if matches(node) { return node }
    guard depth < 40 else { return nil }
    for child in node.accessibilityChildren?() ?? [] {
      if let found = element(in: child as AnyObject, depth: depth + 1, where: matches) {
        return found
      }
    }
    return nil
  }
}
