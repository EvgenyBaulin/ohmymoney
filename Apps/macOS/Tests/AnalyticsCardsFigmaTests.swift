import AppCore
import AppDatabase
import AppKit
import SwiftUI
import XCTest

@testable import OhMyMoney

/// The cards of Analytics and the board of «Отчёты · По событиям» against the numbers of their
/// frames — the summary card of «Траты» (5:36907), the card of every other page (61:60578,
/// 61:62017), the ring and the bars, the board of 62:36343 — and the figures they show against
/// the core's own tables of the same synthetic book, so a card never says what the reports do
/// not.
@MainActor
final class AnalyticsCardsFigmaTests: XCTestCase {
  private let today = DateOnly(year: 2026, month: 11, day: 10)

  // MARK: The card

  /// 5:36982: 14 inside an edge of 1, 10 to the body, a title of 14 with its figure 8 to the
  /// right in 12. 61:60516: 16 inside the edge, 12 to the body, a title of 15 over 11, 2 apart.
  func testTheTwoCardsHaveTheNumbersOfTheirFrames() {
    XCTAssertEqual(AnalyticsCardMetrics.edge, 1)
    XCTAssertEqual(AnalyticsCardMetrics.padding(.summary), 14)
    XCTAssertEqual(AnalyticsCardMetrics.bodyGap(.summary), 10)
    XCTAssertEqual(AnalyticsCardMetrics.padding(.detail), 16)
    XCTAssertEqual(AnalyticsCardMetrics.bodyGap(.detail), 12)
    XCTAssertEqual(AnalyticsCardMetrics.subtitleGap, 2)
    XCTAssertEqual(AnalyticsCardMetrics.captionGap, 8)
    XCTAssertEqual(AnalyticsCardMetrics.radius, ContentCard.cornerRadius)
    XCTAssertEqual(AnalyticsCardType.title(.summary), .system(size: 14, weight: .semibold))
    XCTAssertEqual(AnalyticsCardType.title(.detail), .system(size: 15, weight: .semibold))
    XCTAssertEqual(AnalyticsCardType.subtitle, .system(size: 11))
  }

  /// The first page of «Траты»: two columns of their own on a wide page — «По месяцам» over
  /// «Аномалии», «Расходы по категориям» over «Хорошие и плохие», 16 apart, 14 between the cards
  /// of a column —; one column in the phone's order (5:6837).
  func testTheSummaryCardsStandWhereTheFramesPutThem() {
    let wide = OverviewSummaryLayout(isWide: true)
    XCTAssertEqual(wide.left, [.months, .anomalies])
    XCTAssertEqual(wide.right, [.categories, .quality])
    let phone = OverviewSummaryLayout(isWide: false)
    XCTAssertEqual(phone.left, [.categories, .months, .quality, .anomalies])
    XCTAssertTrue(phone.right.isEmpty)
    XCTAssertEqual(OverviewSummaryLayout.columnGap, 16)
    XCTAssertEqual(OverviewSummaryLayout.stackGap, 14)
  }

  /// 5:36997: twelve columns of 36.4, 9.2 apart, over 538; the tallest 86.4 of a plot of 100.
  func testTheMonthBarsHaveTheGeometryOfTheFrame() {
    XCTAssertEqual(MonthBarsMetrics.barWidth(count: 12, width: 538), 36.4, accuracy: 0.01)
    XCTAssertEqual(
      MonthBarsMetrics.barWidth(count: 12, width: 538) * MonthBarsMetrics.gapRatio, 9.2,
      accuracy: 0.01)
    XCTAssertEqual(MonthBarsMetrics.barHeight(500, top: 500, plot: 100), 86.4, accuracy: 0.01)
    XCTAssertEqual(MonthBarsMetrics.barHeight(250, top: 500, plot: 100), 43.2, accuracy: 0.01)
    XCTAssertEqual(MonthBarsMetrics.barHeight(-10, top: 500, plot: 100), 0)
    XCTAssertEqual(MonthBarsMetrics.barHeight(10, top: 0, plot: 100), 0)
    XCTAssertEqual(MonthBarsMetrics.height, 100)
    XCTAssertEqual(MonthBarsMetrics.radius, 6)
  }

  /// The ring: the four largest categories and «Прочее» last, whole shares that make 100 %.
  func testTheRingShowsFourCategoriesAndTheRest() {
    let keys = (0..<6).map { _ in ReportKey.category(UUID()) }
    let values = zip(keys, [340, 220, 180, 140, 70, 50]).map {
      RankedValue(key: $0, value: Int64($1), share: nil)
    }
    let donut = OverviewDonut.make(values.reversed())
    XCTAssertEqual(donut.total, 1_000)
    XCTAssertEqual(donut.parts.map(\.key), Array(keys.prefix(4)) + [nil])
    XCTAssertEqual(donut.parts.map(\.basisPoints), [3_400, 2_200, 1_800, 1_400, 1_200])
    XCTAssertEqual(donut.parts.map(\.basisPoints).reduce(0, +), 10_000)
    // Four or fewer: no «Прочее»; a refund that outweighed its category is left out.
    let few = OverviewDonut.make([
      RankedValue(key: keys[0], value: 300, share: nil),
      RankedValue(key: keys[1], value: -20, share: nil),
    ])
    XCTAssertEqual(few.parts.map(\.key), [keys[0]])
    XCTAssertEqual(OverviewDonut.make([]).parts, [])
    XCTAssertEqual(OverviewDonutMetrics.ring, 120)
    XCTAssertEqual(OverviewDonutMetrics.ringToLegend, 14)
    XCTAssertEqual(OverviewDonutMetrics.legendGap, 5)
  }

  /// «148 тыс.» in the hole of the ring; under a thousand and from a million, as an axis says.
  func testTheHoleOfTheRingSaysThousands() {
    let environment = AppEnvironment()
    environment.language.choice = .russian
    XCTAssertEqual(AnalyticsText.thousands(148_200, environment), "148\u{00A0}тыс.")
    XCTAssertEqual(AnalyticsText.thousands(148_500, environment), "149\u{00A0}тыс.")
    XCTAssertEqual(AnalyticsText.thousands(950, environment), environment.money.axis(950))
    XCTAssertEqual(
      AnalyticsText.thousands(2_400_000, environment), environment.money.axis(2_400_000))
    environment.language.choice = .english
    XCTAssertEqual(AnalyticsText.thousands(148_200, environment), "148K")
  }

  /// The line between the chips and the cards: only on the pages that look at another span than
  /// the header's period (61:60578), and always for «часть скрыта».
  func testTheLineOverTheCardsIsWhereTheFramesDrawIt() {
    XCTAssertFalse(AnalyticsSectionLine.isShown(.overview, partHidden: false))
    XCTAssertFalse(AnalyticsSectionLine.isShown(.days, partHidden: false))
    XCTAssertTrue(AnalyticsSectionLine.isShown(.incomeSavings, partHidden: false))
    XCTAssertTrue(AnalyticsSectionLine.isShown(.forecast, partHidden: false))
    XCTAssertTrue(AnalyticsSectionLine.isShown(.overview, partHidden: true))
  }

  // MARK: The figures of the first page

  /// «По месяцам» is the spending of the twelve months to the month of the period, that month
  /// picked out; a year that runs on past today ends with the month of today. «Хорошие и
  /// плохие» says what the tab of the same name says.
  func testTheSummaryCardsShowWhatTheCoreCounts() throws {
    let ledger = PlanningFigmaWindowTests.snapshot(today: today).ledger
    let october = MonthKey(year: 2026, month: 10)
    let model = AnalyticsBuilder.overview(ledger: ledger, period: .month(october), today: today)
    let bars = try XCTUnwrap(model.months.content)
    XCTAssertEqual(bars.months.count, 12)
    XCTAssertEqual(bars.highlighted, october)
    XCTAssertEqual(bars.months.last?.month, october)
    for month in bars.months {
      XCTAssertEqual(
        month.value, ledger.expenses(in: Period.month(month.month).range).wholeRubles,
        "the spending of \(month.month.iso)")
    }
    let year = AnalyticsBuilder.monthBars(ledger: ledger, period: .year(2026), today: today)
    XCTAssertEqual(year.content?.highlighted, today.monthKey)

    let quality = try XCTUnwrap(model.quality.content)
    let tab = AnalyticsBuilder.quality(ledger: ledger, period: .month(october), today: today)
    XCTAssertEqual(quality, QualityTotals.make(columns: try XCTUnwrap(tab.shares.content)))
    XCTAssertNil(model.anomalies, "no anomalies before step 6 has run")
    let found = AnalyticsBuilder.overview(
      ledger: ledger, period: .month(october), today: today, anomalies: AnomalyReport())
    XCTAssertEqual(found.anomalies?.reason, .noAnomalies)
  }

  // MARK: «Отчёты · По событиям»

  /// The board of 62:36343 is read from the core's tables: the cards' figures are the total and
  /// the lines of the spending by event, the list the categories of the largest event, and the
  /// change is measured against the spending of the month before.
  func testTheEventBoardIsTheCoresTables() throws {
    let ledger = PlanningFigmaWindowTests.snapshot(today: today).ledger
    let period = AnalyticsPeriod(kind: .month, month: today.monthKey)
    let sheet = ReportsSheetBuilder.sheet(
      ReportsSheetRequest(tab: .byEvent, period: period, today: today), ledger: ledger)
    let board = try XCTUnwrap(sheet.eventBoard)
    let builder = ReportBuilder(ledger: ledger, today: today)
    let byEvent = builder.table(.expensesByCategory, period: period.period, grouping: .event)
    let total = try XCTUnwrap(byEvent.total.values.first ?? nil)
    XCTAssertEqual(board.total, total.wholeRubles)
    XCTAssertEqual(board.change.current, total)
    // November is not over on the 10th: it is compared with 1–10 October, not all of it.
    let span = DayRange(DateOnly(year: 2026, month: 10, day: 1), DateOnly(year: 2026, month: 10, day: 10))
    XCTAssertEqual(board.previousSpan, span)
    let before = builder.table(.expensesByCategory, period: .days(span), grouping: .event)
    XCTAssertEqual(board.change.previous, before.total.values.first ?? nil)
    let october = AnalyticsPeriod(kind: .month, month: MonthKey(year: 2026, month: 10))
    XCTAssertNil(ReportsEventBoard.previousSpan(of: october, today: today), "October is over")
    XCTAssertNil(
      ReportsEventBoard.previousSpan(
        of: october, today: DateOnly(year: 2026, month: 10, day: 31)), "its last day: whole")
    // Every month of the book: the largest event and its categories.
    var monthsWithEvents = 0
    for back in 0..<6 {
      let month = AnalyticsPeriod(kind: .month, month: today.monthKey.adding(months: -back))
      let table = builder.table(.expensesByCategory, period: month.period, grouping: .event)
      let events = table.rows.filter { $0.key != .noEvent }
      let board = try XCTUnwrap(
        ReportsSheetBuilder.sheet(
          ReportsSheetRequest(tab: .byEvent, period: month, today: today), ledger: ledger
        ).eventBoard)
      guard let largest = board.largest else {
        XCTAssertTrue(events.isEmpty, "\(month.month.iso)")
        continue
      }
      monthsWithEvents += 1
      let top = events.map { ($0.values.first ?? nil)?.wholeRubles ?? 0 }.max()
      XCTAssertEqual(largest.value, top)
      XCTAssertFalse(board.breakdown.isEmpty, "the largest event has its categories")
      XCTAssertEqual(
        Double(board.breakdown.map(\.value).reduce(0, +)), Double(largest.value),
        accuracy: Double(board.breakdown.count), "the categories make the event")
      XCTAssertEqual(board.breakdown.map(\.value), board.breakdown.map(\.value).sorted(by: >))
      // Each category's share is of the event: together they make it whole.
      let shares = board.breakdown.compactMap(\.share).reduce(0, +)
      XCTAssertEqual(Double(shares), 10_000, accuracy: Double(board.breakdown.count))
    }
    XCTAssertGreaterThan(monthsWithEvents, 0, "the book has events")
    if let without = board.withoutEvent {
      XCTAssertEqual(without.key, .noEvent)
      let row = try XCTUnwrap(byEvent.rows.first { $0.key == .noEvent })
      XCTAssertEqual(without.value, (row.values.first ?? nil)?.wholeRubles)
      XCTAssertEqual(without.share, row.share)
    }
    // The CSV of the tab is the one table it always was.
    XCTAssertEqual(sheet.models.map(\.request.kind), [.expensesByCategory])
    XCTAssertNil(
      ReportsSheetBuilder.sheet(
        ReportsSheetRequest(tab: .byPerson, period: period, today: today), ledger: ledger
      ).eventBoard)
  }

  /// The words of the cards: «Расходы за октябрь», «−6 % к сентябрю», «23.36 %».
  func testTheEventBoardSpeaksAsTheFrame() {
    let environment = AppEnvironment()
    environment.language.choice = .russian
    let october = AnalyticsPeriod(kind: .month, month: MonthKey(year: 2026, month: 10))
    XCTAssertEqual(ReportsEventText.spendingTitle(october, environment), "Расходы за октябрь")
    let board = ReportsEventBoard(
      change: Change(current: money("91600"), previous: money("97448")),
      total: 91_600, largest: nil, withoutEvent: nil, breakdown: [],
      previous: october.stepped(by: -1))
    XCTAssertEqual(ReportsEventText.change(board, environment), "−6\u{00A0}% к сентябрю")
    XCTAssertEqual(ReportsEventText.share(2_336, environment), "23.36\u{00A0}%")
    XCTAssertEqual(ReportsEventText.share(nil, environment), "—")
    var partial = board
    partial.previousSpan = DayRange(
      DateOnly(year: 2026, month: 9, day: 1), DateOnly(year: 2026, month: 9, day: 10))
    XCTAssertTrue(
      ReportsEventText.change(partial, environment).hasSuffix("к \(environment.dates.span(partial.previousSpan!))"))
    var empty = board
    empty.change = Change(current: money("100"), previous: .zero)
    XCTAssertEqual(ReportsEventText.change(empty, environment), "не с чем сравнить")
    environment.language.choice = .english
    XCTAssertEqual(ReportsEventText.spendingTitle(october, environment), "Spending in October")
  }

  /// 62:36343: three cards 12 apart, the table 681.6 and the list 454.4 of 1152, 16 apart.
  func testTheEventBoardHasTheNumbersOfTheFrame() {
    let widths = ReportsEventBoardMetrics.widths(1_152)
    XCTAssertEqual(widths.table, 681, accuracy: 1)
    XCTAssertEqual(widths.list, 455, accuracy: 1)
    XCTAssertEqual(widths.table + widths.list + ReportsEventBoardMetrics.columnGap, 1_152)
    XCTAssertEqual(ReportsEventBoardMetrics.cardGap, 12)
    XCTAssertEqual(ReportsEventBoardMetrics.badge, 30)
    XCTAssertEqual(ReportsEventBoardMetrics.rowHeight, 54)
    XCTAssertEqual(ReportsEventBoardMetrics.amountWidth, 195)
    XCTAssertEqual(ReportsEventBoardMetrics.shareWidth, 134)
  }
}

/// The first page of «Траты» (5:36907), «Доход» (61:60578) and «Отчёты · По событиям»
/// (62:36343) in the main window at 1440 × 900 over six months of a book with every feature:
/// the cards are measured against the frames' numbers and a picture of the window is kept with
/// the result, to lay beside the frame.
@MainActor
final class AnalyticsCardsFigmaWindowTests: XCTestCase {
  private var environment: AppEnvironment!
  private var store: TransactionsStore!
  private var compute: ComputeStore!
  private var directory: URL!
  private var suiteName: String!
  private var defaults: UserDefaults!
  private var windows: [NSWindow] = []
  private var dataDirectoryBefore: String?
  private var languageBefore: AppLanguage.Choice?
  private var entryStyleBefore: EntryStyle?

  private struct NotFound: Error {}

  override func setUp() async throws {
    dataDirectoryBefore = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-analytics-cards-\(UUID().uuidString)", isDirectory: true)
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
    suiteName = "ohmymoney-analytics-cards-\(UUID().uuidString)"
    defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    compute.applyLight(PlanningFigmaWindowTests.snapshot(today: environment.today))
    entryStyleBefore = environment.entryStyle
    environment.entryStyle = .line
    languageBefore = environment.language.choice
    environment.language.choice = .russian
  }

  override func tearDown() async throws {
    for window in windows {
      window.contentViewController = nil
      window.close()
    }
    windows = []
    if let languageBefore { environment?.language.choice = languageBefore }
    if let entryStyleBefore { environment?.entryStyle = entryStyleBefore }
    if let environment { await environment.close() }
    defaults?.removePersistentDomain(forName: suiteName)
    if let dataDirectoryBefore {
      setenv("OHMYMONEY_DATA_DIR", dataDirectoryBefore, 1)
    } else {
      unsetenv("OHMYMONEY_DATA_DIR")
    }
    if let directory { try? FileManager.default.removeItem(at: directory) }
  }

  private func makeWindow(_ section: MainWindow.Section, width: CGFloat) -> NSWindow {
    let deps = AppDependencies(environment: environment, store: store, compute: compute)
    let actions = OperationActions()
    let root =
      AppScenes.root(deps, window: .main, launches: false) { deps in
        MainWindow(
          deps: deps, actions: actions, opensDetails: false, selection: .section(section))
      }
      .environment(\.windowWidth, width)
      .defaultAppStorage(defaults)
    let controller = NSHostingController(rootView: root)
    controller.sceneBridgingOptions = [.toolbars]
    let window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: width, height: 900),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentViewController = controller
    window.setContentSize(CGSize(width: width, height: 900))
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

  private func find(_ identifier: String, in window: NSWindow) -> CGRect? {
    guard let root = window.contentView else { return nil }
    var found: [AnyObject] = []
    Self.elements(in: root, into: &found) { $0.accessibilityIdentifier?() == identifier }
    let frames = found.compactMap { $0.accessibilityFrame?() }.filter { $0.width > 0 }
    return frames.max { $0.width * $0.height < $1.width * $1.height }
      .map { window.convertFromScreen($0) }
  }

  private func frame(of identifier: String, in window: NSWindow) throws -> CGRect {
    let deadline = Date().addingTimeInterval(8)
    repeat {
      if let frame = find(identifier, in: window) { return frame }
      settle(window, passes: 5)
    } while Date() < deadline
    XCTFail("\(identifier) was not found")
    throw NotFound()
  }

  /// The page is measured only once two reads of its parts in a row agree.
  private func waitUntilStill(_ identifiers: [String], in window: NSWindow) throws {
    var last = try identifiers.map { try frame(of: $0, in: window) }
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline {
      settle(window, passes: 5)
      let now = try identifiers.map { try frame(of: $0, in: window) }
      if now == last { return }
      last = now
    }
    XCTFail("the page never stopped moving: \(identifiers)")
  }

  private func sidebarEdge(in window: NSWindow) throws -> CGFloat {
    let root = try XCTUnwrap(window.contentView)
    var scrolls: [NSScrollView] = []
    Self.allSubviews(of: root, into: &scrolls)
    let sidebar = try XCTUnwrap(
      scrolls.first { scroll in
        var tables: [NSTableView] = []
        Self.allSubviews(of: scroll, into: &tables)
        return !tables.isEmpty
      }, "the sidebar was not found")
    return sidebar.convert(sidebar.bounds, to: nil).maxX
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

  /// 5:36907: «По месяцам» starts the page 16 under the groups, «Расходы по категориям» 16 to its
  /// right, each half of the page less the gap; «Аномалии» 14 under «По месяцам», «Хорошие и
  /// плохие» 14 under the ring; no line between the groups and the cards.
  func testTheFirstPageOfSpendingHasTheCardsOfTheMaster() throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    try TestEnvironment.requireScreen(width: 1_440, height: 900)
    defaults.set(AnalyticsSection.overview.rawValue, forKey: AnalyticsWindow.sectionKey)
    let window = makeWindow(.analytics, width: 1_440)
    settle(window)
    let cards = [
      "analytics.overview.months", "analytics.overview.categories",
      "analytics.overview.quality", "analytics.overview.anomalies",
    ]
    try waitUntilStill(["analytics.groups"] + cards, in: window)
    try attachPicture(of: window, named: "Analytics · Траты · Обзор 1440 × 900 (Figma 5:36907)")

    let sidebar = try sidebarEdge(in: window)
    let page = 1_440 - sidebar - 2 * StyleMetrics.pageSide
    let column = (page - OverviewSummaryLayout.columnGap) / 2
    let groups = try frame(of: "analytics.groups", in: window)
    let months = try frame(of: "analytics.overview.months", in: window)
    let categories = try frame(of: "analytics.overview.categories", in: window)
    let quality = try frame(of: "analytics.overview.quality", in: window)
    let anomalies = try frame(of: "analytics.overview.anomalies", in: window)

    XCTAssertEqual(months.minX - sidebar, StyleMetrics.pageSide, accuracy: 1.5, "\(months)")
    XCTAssertEqual(months.width, column, accuracy: 1.5, "a column: \(months)")
    XCTAssertEqual(categories.width, column, accuracy: 1.5, "a column: \(categories)")
    XCTAssertEqual(categories.minX - months.maxX, 16, accuracy: 1.5, "the columns' gap")
    // y is up: the first cards 16 under the groups, both at one height.
    XCTAssertEqual(groups.minY - months.maxY, 16, accuracy: 2, "groups → cards")
    XCTAssertEqual(categories.maxY, months.maxY, accuracy: 1, "both columns start together")
    XCTAssertEqual(months.minY - anomalies.maxY, 14, accuracy: 1.5, "months → anomalies")
    XCTAssertEqual(categories.minY - quality.maxY, 14, accuracy: 1.5, "ring → ratings")
    XCTAssertEqual(anomalies.minX, months.minX, accuracy: 1)
    XCTAssertEqual(quality.minX, categories.minX, accuracy: 1)
    XCTAssertNil(find("analytics.section.line", in: window), "no line over the cards")
    // The frame's heights (180, 177, 140) with the type of this Mac: within a few points.
    XCTAssertEqual(months.height, 180, accuracy: 8, "«По месяцам»: \(months)")
    XCTAssertEqual(categories.height, 177, accuracy: 8, "«Расходы по категориям»: \(categories)")
    XCTAssertEqual(quality.height, 140, accuracy: 8, "«Хорошие и плохие»: \(quality)")
  }

  /// 61:60578: the line «Последние 12 месяцев · по …» 16 under the groups and the first cards 16
  /// under it.
  func testIncomeKeepsItsLineOverTheCards() throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    try TestEnvironment.requireScreen(width: 1_440, height: 900)
    defaults.set(AnalyticsSection.incomeSavings.rawValue, forKey: AnalyticsWindow.sectionKey)
    let window = makeWindow(.analytics, width: 1_440)
    settle(window)
    try waitUntilStill(["analytics.groups", "analytics.section.line"], in: window)
    try attachPicture(of: window, named: "Analytics · Доход 1440 × 900 (Figma 61:60578)")
    let groups = try frame(of: "analytics.groups", in: window)
    let line = try frame(of: "analytics.section.line", in: window)
    XCTAssertEqual(groups.minY - line.maxY, 16, accuracy: 2, "groups → line")
    XCTAssertEqual(line.minX, groups.minX, accuracy: 1)
  }

  /// 62:36343: the three cards 14 under the tabs, 12 apart, one width; the table 14 under them
  /// and the list of the largest event 16 to its right, 60 : 40 of the page.
  func testReportsByEventHaveTheBoardOfTheFrame() throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    try TestEnvironment.requireScreen(width: 1_440, height: 900)
    defaults.set(ReportTable.Kind.expensesByCategory.rawValue, forKey: ReportsSelection.tableKey)
    defaults.set(ReportGrouping.event.rawValue, forKey: ReportsSelection.groupingKey)
    // The month of the book whose spending names the most events, so the list has its rows.
    let ledger = try XCTUnwrap(compute.snapshot?.ledger)
    let builder = ReportBuilder(ledger: ledger, today: environment.today)
    let month = try XCTUnwrap(
      (0..<6).map { environment.today.monthKey.adding(months: -$0) }.max { lhs, rhs in
        func events(_ month: MonthKey) -> Int {
          builder.table(.expensesByCategory, period: .month(month), grouping: .event).rows
            .filter { $0.key != .noEvent }.count
        }
        return events(lhs) < events(rhs)
      })
    defaults.set(
      AnalyticsPeriod(kind: .month, month: month).storage, forKey: ReportsSelection.periodKey)
    let window = makeWindow(.reports, width: 1_440)
    settle(window)
    try waitUntilStill(["reports.tabs", "reports.table", "reports.events.total"], in: window)
    try attachPicture(of: window, named: "Reports · По событиям 1440 × 900 (Figma 62:36343)")

    let sidebar = try sidebarEdge(in: window)
    let page = 1_440 - sidebar - 2 * StyleMetrics.pageSide
    let tabs = try frame(of: "reports.tabs", in: window)
    let total = try frame(of: "reports.events.total", in: window)
    let table = try frame(of: "reports.table", in: window)
    XCTAssertEqual(total.minX - sidebar, StyleMetrics.pageSide, accuracy: 1.5, "\(total)")
    XCTAssertEqual(tabs.minY - total.maxY, ReportsMetrics.mac.stackGap, accuracy: 1.5)
    XCTAssertEqual(total.minY - table.maxY, ReportsMetrics.mac.stackGap, accuracy: 1.5)
    XCTAssertEqual(total.height, 93.6, accuracy: 6, "a card of the board: \(total)")
    let cards = ["reports.events.total", "reports.events.largest", "reports.events.without"]
      .compactMap { find($0, in: window) }
    let gaps = CGFloat(cards.count - 1) * ReportsEventBoardMetrics.cardGap
    for card in cards {
      XCTAssertEqual(card.width, (page - gaps) / CGFloat(cards.count), accuracy: 1.5, "\(card)")
    }
    XCTAssertNotNil(find("reports.events.largest", in: window), "the largest event of \(month.iso)")
    if let list = find("reports.events.list", in: window) {
      let widths = ReportsEventBoardMetrics.widths(page)
      XCTAssertEqual(table.width, widths.table, accuracy: 1.5, "the table: \(table)")
      XCTAssertEqual(list.width, widths.list, accuracy: 1.5, "the list: \(list)")
      XCTAssertEqual(list.minX - table.maxX, 16, accuracy: 1.5, "table → list")
      XCTAssertEqual(list.maxY, table.maxY, accuracy: 1, "both from the top")
    } else {
      XCTAssertEqual(table.width, page, accuracy: 1.5, "alone, the table takes the page")
    }
  }

  private static func allSubviews<V: NSView>(of view: NSView, into found: inout [V]) {
    if let match = view as? V { found.append(match) }
    for subview in view.subviews { allSubviews(of: subview, into: &found) }
  }

  private static func elements(
    in node: AnyObject, depth: Int = 0, into found: inout [AnyObject],
    where matches: (AnyObject) -> Bool
  ) {
    if matches(node) { found.append(node) }
    guard depth < 40 else { return }
    for child in node.accessibilityChildren?() ?? [] {
      elements(in: child as AnyObject, depth: depth + 1, into: &found, where: matches)
    }
  }
}
