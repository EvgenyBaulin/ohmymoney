import AppCore
import AppKit
import SwiftUI
import XCTest

@testable import OhMyMoney

/// The week of the frames of «Итоги» (34:17697, 571:49182) as data: 18 400 ₽ spent from Monday
/// 12 to Sunday 18 October 2026 — housing 5 890, groceries 5 150, cafés 3 310, transport 2 210,
/// gifts 1 840 — good 7 900, usual 7 000, poor 3 500; 32 000 ₽ came in; the dearest day a
/// Friday; the week before as dear. September, and October 2025, are there to compare with.
@MainActor
enum PeriodsFigmaBook {
  static let home = CoreKit.Category(kind: .expense, name: "Жильё")
  static let food = CoreKit.Category(kind: .expense, name: "Продукты")
  static let cafe = CoreKit.Category(kind: .expense, name: "Кафе")
  static let transport = CoreKit.Category(kind: .expense, name: "Транспорт")
  static let gifts = CoreKit.Category(kind: .expense, name: "Подарки")
  static let salary = CoreKit.Category(kind: .income, name: "Зарплата")
  static let today = DateOnly(year: 2026, month: 10, day: 26)
  static let week = SummaryID.week(WeekKey(containing: DateOnly(year: 2026, month: 10, day: 14)))
  static let october = SummaryID.month(MonthKey(year: 2026, month: 10))

  private static func entry(
    _ kind: TransactionKind, _ whole: Int64, _ day: Int, month: Int = 10, year: Int = 2026,
    _ category: CoreKit.Category, _ quality: Quality? = nil
  ) -> TransactionEntry {
    let id = UUID()
    let amount = AmountE4(whole: whole)
    let date = DateOnly(year: year, month: month, day: day)
    return TransactionEntry(
      transaction: Transaction(
        id: id, kind: kind, occurredAt: CalendarContext.system.noon(of: date), amountE4: amount),
      parts: [
        TransactionPart(
          transactionId: id, categoryId: category.id, quality: quality, amountE4: amount)
      ])
  }

  static var dataset: Dataset {
    let entries = [
      entry(.income, 32_000, 12, salary),
      entry(.expense, 2_210, 12, transport, .neutral),
      entry(.expense, 3_140, 14, food, .neutral),
      entry(.expense, 1_650, 14, cafe, .neutral),
      entry(.expense, 1_660, 15, cafe, .bad),
      entry(.expense, 1_840, 15, gifts, .bad),
      entry(.expense, 5_890, 16, home, .good),
      entry(.expense, 2_010, 16, food, .good),
      // The week before, as dear; September; October a year before.
      entry(.expense, 18_400, 9, food, .neutral),
      entry(.expense, 20_000, 10, month: 9, food, .neutral),
      entry(.expense, 59_000, 10, month: 10, year: 2025, food, .neutral),
    ]
    return Dataset(
      entries: entries, categories: [home, food, cafe, transport, gifts, salary])
  }

  static var ledger: Ledger { Ledger(dataset: dataset, calendar: .system) }

  static func snapshot() -> DataSnapshot {
    DataSnapshot.build(
      dataset: dataset, calendar: .system, today: today, context: SnapshotContext(),
      version: DataVersion(load: 0))
  }

  static func board(_ id: SummaryID) -> PeriodBoard? {
    PeriodBoard.build(id, ledger: ledger, today: today)
  }
}

/// «Итоги» as the tab «По периодам» of Reports: the numbers of its frames, its words, every way
/// in, and the tab laid out at the width of the Mac frame with a picture of it kept.
@MainActor
final class PeriodsBoardTests: XCTestCase {
  private var environment: AppEnvironment!
  private var suiteName = ""
  private var defaults: UserDefaults!
  private var windows: [NSWindow] = []
  private var languageBefore: AppLanguage.Choice?

  override func setUp() async throws {
    environment = AppEnvironment()
    languageBefore = environment.language.choice
    environment.language.choice = .russian
    suiteName = "ohmymoney-periods-\(UUID().uuidString)"
    defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    SummariesRoute.shared.pending = nil
  }

  override func tearDown() async throws {
    for window in windows {
      window.contentView = nil
      window.close()
    }
    windows = []
    environment.amounts.hidesAmounts = false
    if let languageBefore { environment.language.choice = languageBefore }
    SummariesRoute.shared.pending = nil
    UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
  }

  private var text: PeriodsBoardText {
    PeriodsBoardText(
      environment: environment, names: SummaryNames(dataset: PeriodsFigmaBook.dataset))
  }

  // MARK: The numbers of the frames

  /// Mac 34:17697: two columns of 568 in 1152, 16 apart; the coloured card 20 inside, 8 between
  /// its lines; white cards 16 inside, rounded 12; the plot 160 tall and 468 wide; a grade's
  /// track 200. Tablet 572:224407: 411 of 1060, rounded 22. Phone 264:91420: one column, rounded
  /// 22, the coloured card 16 inside and 7 between, the plot 128.5, the track 140.
  func testTheNumbersOfTheFrames() {
    let mac = PeriodsBoardMetrics.mac
    XCTAssertEqual(PeriodsBoardMetrics.leftColumn(.mac, width: 1_152), 568)
    XCTAssertEqual(mac.cardGap, 16)
    XCTAssertEqual(mac.heroPadding, 20)
    XCTAssertEqual(mac.heroGap, 8)
    XCTAssertEqual(mac.heroRadius, 12)
    XCTAssertEqual(mac.cardPadding, 16)
    XCTAssertEqual(mac.cardRadius, 12)
    XCTAssertEqual(mac.plotHeight, 160)
    XCTAssertEqual(mac.plotWidth, 468)
    XCTAssertEqual(mac.gradeTrack, 200)
    XCTAssertEqual(mac.axisSize, 11)
    XCTAssertEqual(PeriodsBoardMetrics.columnsCardHeight, 302)
    XCTAssertEqual(PeriodsBoardMetrics.donut, 160)
    XCTAssertEqual(PeriodsBoardMetrics.donutToLegend, 24)
    XCTAssertEqual(PeriodsBoardMetrics.legendName, 90)
    XCTAssertEqual(PeriodsBoardMetrics.gradeWord, 70)
    XCTAssertEqual(PeriodsBoardMetrics.heroBar, 8)
    XCTAssertTrue(PeriodsBoardMetrics.fitsTwoColumns(.mac, width: 1_152))
    // The narrowest window of Reports (760 less its margins) stacks the cards.
    XCTAssertFalse(PeriodsBoardMetrics.fitsTwoColumns(.mac, width: 760 - 56))

    let pad = PeriodsBoardMetrics.pad
    XCTAssertEqual(PeriodsBoardMetrics.leftColumn(.pad, width: 1_060), 411)
    XCTAssertEqual(pad.heroRadius, 22)
    XCTAssertEqual(pad.cardRadius, 22)
    XCTAssertTrue(PeriodsBoardMetrics.fitsTwoColumns(.pad, width: 1_060))

    let phone = PeriodsBoardMetrics.phone
    XCTAssertFalse(PeriodsBoardMetrics.fitsTwoColumns(.phone, width: 408))
    XCTAssertEqual(phone.cardGap, 12)
    XCTAssertEqual(phone.heroPadding, 16)
    XCTAssertEqual(phone.heroGap, 7)
    XCTAssertEqual(phone.heroRadius, 22)
    XCTAssertEqual(phone.cardRadius, 22)
    XCTAssertEqual(phone.topPadding, 14)
    XCTAssertEqual(phone.topGap, 8)
    XCTAssertEqual(phone.plotHeight, 128.5)
    XCTAssertNil(phone.plotWidth)
    XCTAssertEqual(phone.gradeTrack, 140)
    XCTAssertEqual(phone.axisSize, 9)
    XCTAssertEqual(PeriodsBoardMetrics.phoneSegmentHeight, 34)
  }

  /// The bars of the frames: the coloured card's bar is the share kept — 21 % fills 111 of 528
  /// (68:18433); a grade's bar is its money against the largest — 43/38/19 % fill 197.8, 174.8
  /// and 87.4 of 200 in the frame, which draws them a little short of the whole.
  func testTheBarsAreFilledAsTheFrames() {
    XCTAssertEqual(PeriodsHeroCard.fill(2_100, of: 528), 110.88, accuracy: 0.01)
    let largest: Int64 = 7_900
    XCTAssertEqual(PeriodsGradesCard.fill(7_900, largest: largest, track: 200), 200)
    XCTAssertEqual(
      PeriodsGradesCard.fill(7_000, largest: largest, track: 200), 174.8, accuracy: 2.5)
    XCTAssertEqual(PeriodsGradesCard.fill(3_500, largest: largest, track: 200), 87.4, accuracy: 1.5)
    XCTAssertEqual(PeriodsGradesCard.fill(0, largest: 0, track: 200), 0)
  }

  // MARK: The figures and the words

  /// The week of the frame: 18 400 ₽, «как на прошлой неделе», Friday the dearest day, the four
  /// main categories 5 890 / 5 150 / 3 310 / 2 210, the ring 32/28/18/12/10 %, the grades 43/38/19 %.
  func testTheWeekSaysWhatTheFrameSays() throws {
    let board = try XCTUnwrap(PeriodsFigmaBook.board(PeriodsFigmaBook.week))
    let text = text
    XCTAssertEqual(text.title(board.id), "Неделя в цифрах")
    XCTAssertEqual(text.spentCaption(.week), "Потрачено за неделю")
    XCTAssertEqual(board.spent, AmountE4(whole: 18_400))
    XCTAssertEqual(board.income, AmountE4(whole: 32_000))
    XCTAssertEqual(text.change(board), "как на прошлой неделе")
    XCTAssertNil(text.changeSymbol(board))
    XCTAssertEqual(text.highlightLabel(board), "Дорогой день")
    XCTAssertEqual(text.highlight(board), "Пятница")
    XCTAssertEqual(
      board.topCategories.map(\.amount.decimal), [5_890, 5_150, 3_310, 2_210])
    XCTAssertEqual(
      board.topCategories.map { text.category($0.categoryId) },
      ["Жильё", "Продукты", "Кафе", "Транспорт"])
    XCTAssertEqual(
      board.slices.map { text.percent($0.shareBP) },
      [
        "32\u{00A0}%", "28\u{00A0}%", "18\u{00A0}%", "12\u{00A0}%", "10\u{00A0}%",
      ])
    XCTAssertEqual(text.category(board.slices.last?.categoryId), "Другое")
    XCTAssertEqual(
      board.grades.map { text.percent($0.shareBP) },
      [
        "43\u{00A0}%", "38\u{00A0}%", "19\u{00A0}%",
      ])
    XCTAssertTrue(
      text.grade(board.grades[0]).hasSuffix(" · 43\u{00A0}%"), text.grade(board.grades[0]))
    XCTAssertEqual(text.columnsTitle(.week), "Расходы по неделям")
    XCTAssertEqual(board.columns.count, 6)
    XCTAssertEqual(text.axis(board.columns[5]), "12\u{00A0}окт")
    XCTAssertTrue(text.saved(board).hasSuffix(" · 43\u{00A0}%"), text.saved(board))
  }

  /// A month and a year: «Октябрь в цифрах», «+84 % к сентябрю»; «2026 в цифрах», «−4 % к 2025»;
  /// the months under the columns «Май» … «Окт».
  func testAMonthAndAYearSayHowTheyStandToTheOneBefore() throws {
    let text = text
    let month = try XCTUnwrap(PeriodsFigmaBook.board(PeriodsFigmaBook.october))
    XCTAssertEqual(text.title(month.id), "Октябрь в цифрах")
    XCTAssertEqual(text.spentCaption(.month), "Потрачено за месяц")
    XCTAssertEqual(text.change(month), "+84\u{00A0}% к сентябрю")
    XCTAssertEqual(text.changeSymbol(month), "arrow.up.right")
    XCTAssertEqual(text.columnsTitle(.month), "Расходы по месяцам")
    XCTAssertEqual(
      month.columns.map { text.axis($0) }, ["Май", "Июн", "Июл", "Авг", "Сен", "Окт"])
    let year = try XCTUnwrap(PeriodsFigmaBook.board(.year(2026)))
    XCTAssertEqual(text.title(year.id), "2026 в цифрах")
    XCTAssertEqual(text.change(year), "−4\u{00A0}% к 2025")
    XCTAssertEqual(text.changeSymbol(year), "arrow.down.right")
    XCTAssertEqual(text.spentCaption(.year), "Потрачено за год")
  }

  /// With «Скрыть суммы» on, no figure of money is written anywhere on the board; shares stay.
  func testHiddenAmountsLeaveNoAmountOnTheBoard() throws {
    let board = try XCTUnwrap(PeriodsFigmaBook.board(PeriodsFigmaBook.week))
    environment.amounts.hidesAmounts = true
    let text = text
    let written =
      [text.rubles(board.spent), text.rubles(board.income), text.saved(board)]
      + board.topCategories.map { text.rubles($0.amount) } + board.grades.map(text.grade)
    for line in written {
      XCTAssertFalse(line.contains("18"), line)
      XCTAssertFalse(line.contains("5\u{00A0}890") || line.contains("5,890"), line)
    }
    XCTAssertTrue(text.grade(board.grades[0]).hasSuffix("43\u{00A0}%"), "shares stay")
  }

  // MARK: Every way in

  /// «Выгрузить CSV…» on «По периодам» writes the period total of the summary on screen: the
  /// table «Итого» of its week, month or year, built by the core as for every tab, and named so.
  func testTheCsvOfTheTabIsThePeriodTotalOfTheSummary() throws {
    let ledger = PeriodsFigmaBook.ledger
    let today = PeriodsFigmaBook.today
    let week = try XCTUnwrap(ReportsSheetRequest.summary(PeriodsFigmaBook.week, today: today))
    XCTAssertEqual(week.tab, .byPeriods)
    XCTAssertEqual(week.period.period.range, PeriodsFigmaBook.week.range)
    XCTAssertEqual(week.tables.map(\.kind), [.periodTotal])
    let sheet = ReportsSheetBuilder.sheet(week, ledger: ledger)
    let table = try XCTUnwrap(sheet.models.first?.table)
    XCTAssertEqual(table.rows[1].amount, AmountE4(whole: 18_400), "spent in the week")
    XCTAssertEqual(table.rows[0].amount, AmountE4(whole: 32_000), "came in")
    XCTAssertFalse(ReportExport.files(sheet, environment: environment).isEmpty)
    XCTAssertEqual(ReportFileName.stem(for: week), "ohmymoney-by-periods-2026-10-12-2026-10-18")

    let month = try XCTUnwrap(ReportsSheetRequest.summary(PeriodsFigmaBook.october, today: today))
    XCTAssertEqual(month.tables.first?.period, .month(MonthKey(year: 2026, month: 10)))
    let year = try XCTUnwrap(ReportsSheetRequest.summary(.year(2025), today: today))
    XCTAssertEqual(year.tables.first?.period, .year(2025))
    XCTAssertEqual(ReportFileName.stem(for: year), "ohmymoney-by-periods-2025")
  }

  /// The card above the tiles, the settings and a notification all ask the route: Reports opens
  /// on «По периодам» with the summary asked for; the tab takes the request once.
  func testEveryWayInOpensTheTab() {
    let route = SummariesRoute()
    route.ask(PeriodsFigmaBook.week, defaults: defaults)
    XCTAssertTrue(defaults.bool(forKey: ReportsSelection.byPeriodsKey))
    XCTAssertEqual(route.take(), PeriodsFigmaBook.week)
    XCTAssertNil(route.take(), "taken once")
    let selection = ReportsSelection(
      table: "", period: "", grouping: "", today: PeriodsFigmaBook.today)
    XCTAssertEqual(selection.tab(.mac, byPeriods: true), .byPeriods)
    XCTAssertEqual(selection.tab(.pad, byPeriods: true), .byPeriods)
    XCTAssertEqual(selection.tab(.phone, byPeriods: true), .byCategory, "a phone has its page")
    XCTAssertEqual(selection.tab(.mac, byPeriods: false), .byCategory)
  }

  /// What the notifications said; posted and heard on the main thread.
  private final class Heard: @unchecked Sendable {
    var item: SidebarItem?
    var summary: SummaryID?
  }

  /// `SummariesRoute.open` brings Reports forward in the main window and says which summary.
  func testOpeningAsksForReportsAndTheSummary() {
    let heard = Heard()
    let center = NotificationCenter.default
    let one = center.addObserver(forName: .openSidebarItem, object: nil, queue: nil) { note in
      heard.item = note.object as? SidebarItem
    }
    let two = center.addObserver(forName: .openSummaries, object: nil, queue: nil) { note in
      heard.summary = note.object as? SummaryID
    }
    defer {
      center.removeObserver(one)
      center.removeObserver(two)
      UserDefaults.standard.removeObject(forKey: ReportsSelection.byPeriodsKey)
    }
    SummariesRoute.open(PeriodsFigmaBook.october)
    XCTAssertEqual(heard.item, .section(.reports))
    XCTAssertEqual(heard.summary, PeriodsFigmaBook.october)
    XCTAssertEqual(SummariesRoute.shared.take(), PeriodsFigmaBook.october)
  }

  /// A phone goes to its page «Итоги», a tablet to Reports; «Ещё» of a phone lists «Итоги», the
  /// tools of a tablet do not.
  func testAPhoneHasAPageAndATabletTheTab() {
    let phone = PhoneRouter()
    phone.openSummaries(isPad: false)
    XCTAssertEqual(phone.tab, .more)
    XCTAssertEqual(phone.morePath, [.summaries])
    XCTAssertEqual(phone.padSection, .reports)
    let pad = PhoneRouter()
    pad.openSummaries(isPad: true)
    XCTAssertEqual(pad.morePath, [.reports])
    XCTAssertTrue(MoreMenu.make(more: [], tripIsOn: false).sections.contains(.summaries))
    XCTAssertFalse(PadLayout.tools(tripIsOn: true, hasConflicts: true).contains(.summaries))
  }

  // MARK: The tab in a window

  private func show(width: CGFloat, height: CGFloat = 900) -> NSWindow {
    defaults.set(true, forKey: ReportsSelection.byPeriodsKey)
    let compute = ComputeStore(calendar: .system, rebuildsInline: true)
    compute.applyLight(PeriodsFigmaBook.snapshot())
    let deps = AppDependencies(
      environment: environment, store: TransactionsStore(), compute: compute)
    SummariesRoute.shared.pending = PeriodsFigmaBook.week
    let view = ReportsWindow(deps: deps, embedded: true)
      .appDependencies(deps)
      .defaultAppStorage(defaults)
    let window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(rootView: view)
    window.orderFront(nil)
    windows.append(window)
    settle(window)
    return window
  }

  private func settle(_ window: NSWindow, passes: Int = 30) {
    for _ in 0..<passes {
      window.layoutIfNeeded()
      window.displayIfNeeded()
      RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
  }

  private struct NotFound: Error {}

  /// The frame of the element with `identifier` in the window (y up): the largest of the
  /// elements that carry it.
  private func frame(of identifier: String, in window: NSWindow) throws -> CGRect {
    let deadline = Date().addingTimeInterval(8)
    repeat {
      if let root = window.contentView {
        var found: [AnyObject] = []
        Self.elements(in: root, into: &found) { $0.accessibilityIdentifier?() == identifier }
        let frames = found.compactMap { $0.accessibilityFrame?() }.filter { $0.width > 0 }
        if let largest = frames.max(by: { $0.width * $0.height < $1.width * $1.height }) {
          return window.convertFromScreen(largest)
        }
      }
      settle(window, passes: 5)
    } while Date() < deadline
    XCTFail("\(identifier) was not found")
    throw NotFound()
  }

  private func isThere(_ identifier: String, in window: NSWindow) -> Bool {
    settle(window, passes: 5)
    guard let root = window.contentView else { return false }
    var found: [AnyObject] = []
    Self.elements(in: root, into: &found) { $0.accessibilityIdentifier?() == identifier }
    return !found.isEmpty
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

  /// Many hosts at once lay a window out slowly: measured once two reads in a row agree.
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

  /// The Mac frame 34:17697 at its width: the page 1152 wide 28 from the edges, the coloured
  /// card and the ring side by side, 568 each and 16 apart; the columns under the coloured card,
  /// the grades and the main categories under the ring, 16 between them, the columns at least
  /// 302 tall and as tall as the two beside them; «Поделиться…» and the period in the header,
  /// no «Выгрузить CSV…».
  func testTheTabHasTheNumbersOfTheMacFrame() throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    let side = StyleMetrics.pageSide
    let width = 1_152 + 2 * side
    try TestEnvironment.requireScreen(width: width, height: 900)
    let window = show(width: width)
    let parts = [
      "summaries.hero", "summaries.donut", "summaries.columns", "summaries.grades", "summaries.top",
    ]
    try waitUntilStill(parts, in: window)
    try attachPicture(of: window, named: "Итоги · неделя 1208 × 900 (Figma 34:17697)")

    let hero = try frame(of: "summaries.hero", in: window)
    let donut = try frame(of: "summaries.donut", in: window)
    let columns = try frame(of: "summaries.columns", in: window)
    let grades = try frame(of: "summaries.grades", in: window)
    let top = try frame(of: "summaries.top", in: window)
    XCTAssertEqual(hero.minX, side, accuracy: 1, "the page stands 28 from the edge")
    XCTAssertEqual(hero.width, 568, accuracy: 1.5, "\(hero)")
    XCTAssertEqual(donut.minX - hero.maxX, 16, accuracy: 1)
    XCTAssertEqual(donut.width, 568, accuracy: 1.5, "\(donut)")
    XCTAssertEqual(hero.height, donut.height, accuracy: 1, "the first row shares its height")
    XCTAssertEqual(hero.minY - columns.maxY, 16, accuracy: 1.5, "16 under the first row")
    XCTAssertEqual(columns.width, 568, accuracy: 1.5)
    XCTAssertGreaterThanOrEqual(columns.height, 302 - 1)
    XCTAssertEqual(grades.minX, donut.minX, accuracy: 1)
    XCTAssertEqual(grades.width, 568, accuracy: 1.5)
    XCTAssertEqual(grades.minY - top.maxY, 16, accuracy: 1.5)
    XCTAssertEqual(columns.maxY, grades.maxY, accuracy: 1, "the second row starts together")
    XCTAssertEqual(columns.minY, top.minY, accuracy: 1, "and ends together")

    // «Выгрузить CSV…» stays the one orange button of Reports at the right edge (0598);
    // «Поделиться…» stands before it, 8 apart, and the period before that.
    let export = try frame(of: "reports.export", in: window)
    let share = try frame(of: "summaries.shareMenu", in: window)
    let period = try frame(of: "summaries.period", in: window)
    XCTAssertEqual(export.maxX, width - side, accuracy: 1.5, "\(export)")
    XCTAssertEqual(export.minX - share.maxX, StyleMetrics.headerButtonGap, accuracy: 1.5)
    XCTAssertEqual(share.minX - period.maxX, StyleMetrics.headerButtonGap, accuracy: 1.5)
    XCTAssertEqual(share.height, export.height, accuracy: 2, "the same size, not the same colour")
    XCTAssertNoThrow(try frame(of: "reports.tab.byPeriods", in: window))
    XCTAssertFalse(isThere("reports.table", in: window), "no table under «По периодам»")
  }

  /// The narrowest window of Reports: the cards one under another, across the page.
  func testANarrowWindowStacksTheCards() throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    let width = ReportsWindow.minimumWidth
    let window = show(width: width)
    try waitUntilStill(["summaries.hero", "summaries.grades"], in: window)
    try attachPicture(of: window, named: "Итоги · неделя \(Int(width)) × 900")
    let hero = try frame(of: "summaries.hero", in: window)
    let donut = try frame(of: "summaries.donut", in: window)
    XCTAssertEqual(hero.width, width - 2 * StyleMetrics.pageSide, accuracy: 1.5)
    XCTAssertEqual(donut.width, hero.width, accuracy: 1)
    XCTAssertEqual(hero.minY - donut.maxY, 16, accuracy: 1.5, "one under the other")
  }
}
