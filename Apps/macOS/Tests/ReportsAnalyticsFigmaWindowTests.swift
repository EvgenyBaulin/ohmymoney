import AppCore
import AppDatabase
import AppKit
import SwiftUI
import XCTest

@testable import OhMyMoney

/// «Отчёты» and «Аналитика» in the main window at the sizes of their frames in the design — the
/// masters at 1440 × 900 (88:71026, 6:109683, 5:36907) and the narrow window at 1024 —, over six
/// months of a book with every feature: the page is measured against the frames' numbers — 28
/// from the sidebar, 14 (Reports) and 16 (Analytics) between the parts, the tabs, the table's
/// rows and widths, the buttons at the right edge — and a picture of the window is kept with the
/// result, to lay beside the frame.
@MainActor
final class ReportsAnalyticsFigmaWindowTests: XCTestCase {
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
      .appendingPathComponent("ohmymoney-reports-figma-\(UUID().uuidString)", isDirectory: true)
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
    suiteName = "ohmymoney-reports-figma-\(UUID().uuidString)"
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

  private func makeWindow(
    _ section: MainWindow.Section, width: CGFloat, height: CGFloat = 900
  ) -> NSWindow {
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

  /// The frame of the element with `identifier`, in the window's coordinates (y up). A control
  /// may hand its identifier down to the parts of its label: the largest of them is the control.
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

  /// Many hosts at once lay a window out slowly: the page is measured only once two reads of its
  /// parts in a row agree.
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

  /// The right edge of the sidebar: the only table in the window while the section is shown.
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

  // MARK: Reports

  private func assertReports(width: CGFloat, picture: String) throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    try TestEnvironment.requireScreen(width: width, height: 900)
    let window = makeWindow(.reports, width: width)
    settle(window)
    try waitUntilStill(["reports.tabs", "reports.table", "reports.export"], in: window)
    try attachPicture(of: window, named: picture)

    let sidebar = try sidebarEdge(in: window)
    let tabs = try frame(of: "reports.tabs", in: window)
    let table = try frame(of: "reports.table", in: window)
    let export = try frame(of: "reports.export", in: window)
    let period = try frame(of: "period.choose", in: window)
    let page = width - sidebar - 2 * StyleMetrics.pageSide
    let metrics = ReportsMetrics.mac

    // The page stands 28 from the sidebar; the buttons end at its right edge, the period 8
    // before «Выгрузить CSV…», both 34 tall.
    XCTAssertEqual(tabs.minX - sidebar, StyleMetrics.pageSide, accuracy: 1.5, "\(tabs)")
    XCTAssertEqual(table.minX, tabs.minX, accuracy: 1, "the table begins the page")
    XCTAssertEqual(export.maxX, sidebar + StyleMetrics.pageSide + page, accuracy: 1.5)
    XCTAssertEqual(export.minX - period.maxX, StyleMetrics.headerButtonGap, accuracy: 1.5)
    XCTAssertEqual(export.height, 34, accuracy: 3, "«Выгрузить CSV…» is 34 tall: \(export)")

    // The tabs: nine of them, 34 tall in their track; 14 above the table (y is up).
    XCTAssertEqual(tabs.height, 34, accuracy: 3, "the track of the tabs: \(tabs)")
    XCTAssertEqual(tabs.minY - table.maxY, metrics.stackGap, accuracy: 1.5, "tabs → table")
    XCTAssertGreaterThanOrEqual(export.minY - tabs.maxY, metrics.stackGap - 1.5, "header → tabs")
    for tab in ReportsTab.tabs(.mac) {
      XCTAssertNoThrow(try frame(of: "reports.tab.\(tab.rawValue)", in: window), "\(tab)")
    }

    // «По категориям»: as wide as its columns — 770 — or the page on a narrower window; a row
    // 32 tall; «Доходы» first under the header.
    let view = ReportGridView(
      grid: ReportGrid(
        columns: [
          .init(title: "", width: .name), .init(title: "", width: .amount),
          .init(title: "", width: .share),
        ], rows: [], spreads: false), metrics: metrics, idiom: .mac)
    XCTAssertEqual(view.naturalWidth, 770, accuracy: 0.5)
    XCTAssertEqual(table.width, min(view.naturalWidth, page), accuracy: 1.5, "\(table)")
    let income = try frame(of: "reports.row.section.0", in: window)
    XCTAssertEqual(income.height, 32, accuracy: 2, "a row of the table: \(income)")
    XCTAssertEqual(table.maxY - income.maxY, 32, accuracy: 3, "the header row above «Доходы»")
  }

  func testReportsAt1440HaveTheNumbersOfTheMaster() throws {
    try assertReports(width: 1_440, picture: "Reports 1440 × 900 (Figma 88:71026)")
  }

  func testReportsAt1024FitTheTableToThePage() throws {
    try assertReports(width: 1_024, picture: "Reports 1024 × 900")
  }

  /// «По месяцам» (6:109683) spreads over the page: a column for each of the six months and
  /// «Итого».
  func testReportsByMonthSpreadOverThePage() throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    try TestEnvironment.requireScreen(width: 1_440, height: 900)
    defaults.set(ReportTable.Kind.monthly.rawValue, forKey: ReportsSelection.tableKey)
    let window = makeWindow(.reports, width: 1_440)
    settle(window)
    try waitUntilStill(["reports.tabs", "reports.table"], in: window)
    try attachPicture(of: window, named: "Reports by month 1440 × 900 (Figma 6:109683)")
    let sidebar = try sidebarEdge(in: window)
    let table = try frame(of: "reports.table", in: window)
    XCTAssertEqual(
      table.width, 1_440 - sidebar - 2 * StyleMetrics.pageSide, accuracy: 2,
      "the table spans the page: \(table)")
    XCTAssertNoThrow(try frame(of: "reports.row.difference", in: window), "«Разница» is there")
  }

  // MARK: Analytics

  private func assertAnalytics(width: CGFloat, picture: String) throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    try TestEnvironment.requireScreen(width: width, height: 900)
    let window = makeWindow(.analytics, width: width)
    settle(window)
    try waitUntilStill(["analytics.groups", "analytics.newOperation"], in: window)
    try attachPicture(of: window, named: picture)

    let sidebar = try sidebarEdge(in: window)
    let groups = try frame(of: "analytics.groups", in: window)
    let add = try frame(of: "analytics.newOperation", in: window)
    let subtitle = try frame(of: "analytics.subtitle", in: window)
    let page = width - sidebar - 2 * StyleMetrics.pageSide
    let metrics = AnalyticsMetrics.mac

    XCTAssertEqual(groups.minX - sidebar, StyleMetrics.pageSide, accuracy: 1.5, "\(groups)")
    XCTAssertEqual(add.maxX, sidebar + StyleMetrics.pageSide + page, accuracy: 1.5, "\(add)")
    XCTAssertEqual(add.height, 34, accuracy: 3, "«Новая операция» is 34 tall: \(add)")
    // The groups: 32 tall; 16 under the period line (y is up).
    XCTAssertEqual(groups.height, 32, accuracy: 3, "the track of the groups: \(groups)")
    XCTAssertEqual(subtitle.minY - groups.maxY, metrics.stackGap, accuracy: 2, "subtitle → tabs")
    XCTAssertEqual(subtitle.minX, groups.minX, accuracy: 1, "the period under the title")
    // The chips of «Траты»: seven of them.
    for section in AnalyticsGroup.spending.sections {
      XCTAssertNoThrow(try frame(of: "analytics.chip.\(section.rawValue)", in: window))
    }
    if width >= 1_440 {
      // The master: the period at the left of «Новая операция», 8 apart, 34 tall.
      let period = try frame(of: "analytics.period", in: window)
      XCTAssertEqual(add.minX - period.maxX, StyleMetrics.headerButtonGap, accuracy: 6)
      XCTAssertEqual(period.height, 34, accuracy: 3, "the period's track: \(period)")
      XCTAssertEqual(period.midY, add.midY, accuracy: 2, "one line with «Новая операция»")
    }
  }

  func testAnalyticsAt1440HasTheNumbersOfTheMaster() throws {
    try assertAnalytics(width: 1_440, picture: "Analytics 1440 × 900 (Figma 5:36907)")
  }

  func testAnalyticsAt1024KeepsItsHeader() throws {
    try assertAnalytics(width: 1_024, picture: "Analytics 1024 × 900")
  }

  /// «Привычки» (61:62017): a group opens on its first section, and its chips are its own.
  func testAnalyticsHabitsShowsItsOwnChips() throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    try TestEnvironment.requireScreen(width: 1_440, height: 900)
    defaults.set(AnalyticsSection.days.rawValue, forKey: AnalyticsWindow.sectionKey)
    let window = makeWindow(.analytics, width: 1_440)
    settle(window)
    try waitUntilStill(["analytics.groups"], in: window)
    try attachPicture(of: window, named: "Analytics habits 1440 × 900 (Figma 61:62017)")
    for section in AnalyticsGroup.habits.sections {
      XCTAssertNoThrow(try frame(of: "analytics.chip.\(section.rawValue)", in: window))
    }
    XCTAssertNil(find("analytics.chip.overview", in: window), "the chips of «Траты» are gone")
  }

  private func find(_ identifier: String, in window: NSWindow) -> AnyObject? {
    guard let root = window.contentView else { return nil }
    var found: [AnyObject] = []
    Self.elements(in: root, into: &found) { $0.accessibilityIdentifier?() == identifier }
    return found.first
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

/// The numbers and the rules of the two screens that need no window: the tabs of each design,
/// what a tab stores and reads, the groups of Analytics, the kinds of its period.
@MainActor
final class ReportsAnalyticsFigmaTests: XCTestCase {
  private let today = DateOnly(year: 2026, month: 11, day: 10)

  /// The tabs as each frame names them: nine on the Mac (88:71026), the six tables of the tablet
  /// (6:155364) and «По периодам» (572:224407), three on a phone (6:111711) — a phone has «Итоги»
  /// as a page of «Ещё».
  func testEachDesignHasTheTabsOfItsFrame() {
    XCTAssertEqual(
      ReportsTab.tabs(.mac),
      [
        .byCategory, .byEvent, .byPerson, .byAccount, .byPlace, .byMonth, .byPeriods, .total,
        .saved,
      ])
    XCTAssertEqual(
      ReportsTab.tabs(.pad),
      [.byCategory, .byMonth, .byPerson, .byPlace, .byEvent, .byAccount, .byPeriods])
    XCTAssertEqual(ReportsTab.tabs(.phone), [.byCategory, .byMonth, .total])
    let environment = AppEnvironment()
    environment.language.choice = .russian
    XCTAssertEqual(
      ReportsTab.tabs(.mac).map { ReportsText.t($0.titleKey, environment) },
      [
        "По категориям", "По событиям", "По людям", "По счетам", "По местам", "По месяцам",
        "По периодам", "Итого", "Сохранённые",
      ])
  }

  /// A tab stores a table and a grouping, and the same tab is read back from them; a saved
  /// report of an older table opens the tab that shows it.
  func testATabIsReadBackFromWhatItStores() {
    for tab in ReportsTab.allCases {
      guard let stored = tab.stored else {
        XCTAssertFalse(tab.showsTable, "\(tab)")
        XCTAssertEqual(tab.opensSheet, tab == .saved, "only «Сохранённые» is a sheet now")
        continue
      }
      XCTAssertEqual(ReportsTab(kind: stored.kind, grouping: stored.grouping), tab)
    }
    XCTAssertEqual(ReportsTab(kind: .incomeByCategory, grouping: .place), .byCategory)
    XCTAssertEqual(ReportsTab(kind: .expensesByCategoryAndSubcategory, grouping: .event), .byEvent)
    // A tab the design of a phone has not opens «По категориям».
    let selection = ReportsSelection(
      table: "expensesByCategory", period: "", grouping: "place", today: today)
    XCTAssertEqual(selection.tab(.mac), .byPlace)
    XCTAssertEqual(selection.tab(.phone), .byCategory)
  }

  /// What each tab is built from: the core's tables, unchanged, so the CSV is theirs.
  func testEveryTabIsMadeOfTheCoresTables() {
    let period = AnalyticsPeriod(kind: .month, month: MonthKey(year: 2026, month: 10))
    func kinds(_ tab: ReportsTab) -> [ReportTable.Kind] {
      ReportsSheetRequest(tab: tab, period: period, today: today).tables.map(\.kind)
    }
    XCTAssertEqual(kinds(.byCategory), [.incomeByCategory, .expensesByCategoryAndSubcategory])
    XCTAssertEqual(kinds(.byEvent), [.expensesByCategory])
    XCTAssertEqual(
      ReportsSheetRequest(tab: .byAccount, period: period, today: today).tables.first?.grouping,
      .paymentMethod)
    XCTAssertEqual(kinds(.byMonth), [.monthly])
    XCTAssertEqual(kinds(.total), [.periodTotal])
    // «По месяцам» of October: the six months May to October, as the frame draws them.
    XCTAssertEqual(
      ReportsSheetRequest(tab: .byMonth, period: period, today: today).months.map(\.iso),
      ["2026-05", "2026-06", "2026-07", "2026-08", "2026-09", "2026-10"])
    // Of a year: its months up to the month of today.
    let year = AnalyticsPeriod(kind: .year, month: MonthKey(year: 2026, month: 11))
    XCTAssertEqual(
      ReportsSheetRequest(tab: .byMonth, period: year, today: today).months.count, 11)
    XCTAssertEqual(
      ReportFileName.stem(for: ReportsSheetRequest(tab: .byCategory, period: period, today: today)),
      "ohmymoney-by-category-2026-10")
  }

  /// The table's numbers: the Mac 12 × 8 with 12 between the cells, name 420, amount 170, share
  /// 130; the phone 10 × 7 with 6, amount 70, share 62, the card rounded 10; the tabs 14 × 6 in
  /// a track of 3, the phone's 10 × 7 over the width.
  func testTheTableAndTheTabsHaveTheNumbersOfTheFrames() {
    let mac = ReportsMetrics.mac
    XCTAssertEqual(
      [
        mac.cellHorizontal, mac.cellVertical, mac.cellGap, mac.nameWidth, mac.amountWidth,
        mac.shareWidth, mac.tableRadius,
      ],
      [12, 8, 12, 420, 170, 130, 12])
    XCTAssertEqual(
      [
        mac.tabTrack, mac.tabHorizontal, mac.tabVertical, mac.tabGap, mac.tabTrackRadius,
        mac.tabRadius,
      ],
      [3, 14, 6, 2, 10, 8])
    XCTAssertEqual([mac.side, mac.top, mac.stackGap], [28, 22, 14])
    XCTAssertFalse(mac.tabsFillWidth)
    let phone = ReportsMetrics.phone
    XCTAssertEqual(
      [
        phone.cellHorizontal, phone.cellVertical, phone.cellGap, phone.amountWidth,
        phone.shareWidth, phone.tableRadius, phone.side, phone.stackGap,
      ],
      [10, 7, 6, 70, 62, 10, PhoneMetrics.screenMargin, 10])
    XCTAssertEqual([phone.tabHorizontal, phone.tabVertical, phone.tabTrack], [10, 7, 3])
    XCTAssertTrue(phone.tabsFillWidth)
    XCTAssertFalse(phone.showsTitle)
  }

  /// Every listed section is in exactly one group, in the order of the frames' chips; a group
  /// opens on its first section.
  func testTheGroupsOfAnalyticsAreThoseOfTheFrames() {
    XCTAssertEqual(
      AnalyticsGroup.spending.sections,
      [.overview, .quality, .others, .forWhom, .places, .events, .paymentMethods])
    XCTAssertEqual(AnalyticsGroup.income.sections, [.incomeSavings])
    XCTAssertEqual(AnalyticsGroup.forecast.sections, [.forecast, .anomalies, .comparison])
    XCTAssertEqual(AnalyticsGroup.habits.sections, [.days, .habits, .leaks])
    let grouped = AnalyticsGroup.allCases.flatMap(\.sections)
    XCTAssertEqual(Set(grouped), Set(AnalyticsSection.listed))
    XCTAssertEqual(grouped.count, AnalyticsSection.listed.count, "no section twice")
    for section in AnalyticsSection.listed {
      XCTAssertTrue(AnalyticsGroup.of(section).sections.contains(section))
    }
    // No group has more than seven chips on view.
    XCTAssertTrue(AnalyticsGroup.allCases.allSatisfy { $0.sections.count <= 7 })
    let environment = AppEnvironment()
    environment.language.choice = .russian
    XCTAssertEqual(
      AnalyticsGroup.allCases.map { AnalyticsText.t($0.titleKey, environment) },
      ["Траты", "Доход", "Прогноз", "Привычки"])
    XCTAssertEqual(
      AnalyticsPeriodChoice.allCases.map { AnalyticsText.t($0.titleKey, environment) },
      ["Неделя", "Месяц", "Квартал", "Год", "Свои даты"])
  }

  /// The header's numbers: the groups 14 × 6 in a track of 2, the chips 6 × 5, 6 apart; 16 to
  /// the tabs and the cards; a phone's chips 10 × 5 on a line of their own, the chosen one on
  /// the accent.
  func testTheHeaderOfAnalyticsHasTheNumbersOfTheFrames() {
    let mac = AnalyticsMetrics.mac
    XCTAssertEqual(
      [
        mac.side, mac.top, mac.subtitleGap, mac.stackGap, mac.groupTrack, mac.groupHorizontal,
        mac.groupVertical, mac.groupRadius, mac.dividerHeight, mac.chipHorizontal,
        mac.chipVertical, mac.chipGap,
      ],
      [28, 22, 14, 16, 2, 14, 6, 8, 18, 6, 5, 6])
    XCTAssertFalse(mac.chosenChipFilled)
    XCTAssertTrue(mac.showsPeriodChoice)
    let phone = AnalyticsMetrics.phone
    XCTAssertEqual(
      [phone.side, phone.stackGap, phone.chipHorizontal, phone.chipVertical, phone.chipGap],
      [PhoneMetrics.screenMargin, 14, 10, 5, 6])
    XCTAssertTrue(phone.groupsFillWidth)
    XCTAssertTrue(phone.chipsOnOwnLine)
    XCTAssertTrue(phone.chosenChipFilled)
    XCTAssertFalse(phone.showsTitle)
  }

  /// «Неделя», «Месяц», «Квартал», «Год» are the current ones; anything else is «Свои даты».
  func testThePeriodChoiceOfTheHeader() {
    XCTAssertEqual(AnalyticsPeriodChoice(.current(.week, today: today), today: today), .week)
    XCTAssertEqual(AnalyticsPeriodChoice(.current(.month, today: today), today: today), .month)
    XCTAssertEqual(
      AnalyticsPeriodChoice(.current(.quarter, today: today), today: today), .quarter)
    XCTAssertEqual(AnalyticsPeriodChoice(.current(.year, today: today), today: today), .year)
    XCTAssertEqual(
      AnalyticsPeriodChoice(.current(.twelveMonths, today: today), today: today), .custom)
    XCTAssertEqual(
      AnalyticsPeriodChoice(
        AnalyticsPeriod(kind: .month, month: MonthKey(year: 2026, month: 9)), today: today),
      .custom)
  }

  /// A week runs Monday to Sunday and a quarter three whole months; both are kept as text and
  /// come back the same, and the texts of an older version still read.
  func testAWeekAndAQuarterAreWholeAndKeptAsText() throws {
    let week = AnalyticsPeriod.current(.week, today: today)
    XCTAssertEqual(week.period.range.start.iso, "2026-11-09")
    XCTAssertEqual(week.period.range.end.iso, "2026-11-15")
    XCTAssertEqual(week.storage, "week:2026-11-09")
    XCTAssertEqual(AnalyticsPeriod(storage: week.storage), week)
    let quarter = AnalyticsPeriod.current(.quarter, today: today)
    XCTAssertEqual(quarter.period.range.start.iso, "2026-10-01")
    XCTAssertEqual(quarter.period.range.end.iso, "2026-12-31")
    XCTAssertTrue(quarter.period.isWholeMonths)
    XCTAssertEqual(AnalyticsPeriod(storage: quarter.storage), quarter)
    XCTAssertEqual(
      AnalyticsPeriod(storage: "twelveMonths:2026-09"),
      AnalyticsPeriod(kind: .twelveMonths, month: MonthKey(year: 2026, month: 9)))
    // Steps: a week by seven days, a quarter by three months; never past today.
    XCTAssertEqual(week.stepped(by: -1).period.range.start.iso, "2026-11-02")
    XCTAssertFalse(week.canStepForward(today: today))
    XCTAssertEqual(quarter.stepped(by: -1).month.iso, "2026-07")
    XCTAssertFalse(quarter.canStepForward(today: today))
    XCTAssertEqual(
      AnalyticsPeriod(week: DateOnly(year: 2027, month: 1, day: 4)).clamped(to: today), week)
    // A saved filter of a week or a quarter opens as one.
    XCTAssertEqual(QuestionOpening.analyticsPeriod(for: week.period, today: today), week)
    XCTAssertEqual(QuestionOpening.analyticsPeriod(for: quarter.period, today: today), quarter)
    let environment = AppEnvironment()
    environment.language.choice = .russian
    XCTAssertFalse(AnalyticsText.title(of: week, environment).isEmpty)
    XCTAssertTrue(AnalyticsText.title(of: quarter, environment).hasSuffix("2026"))
  }
}
