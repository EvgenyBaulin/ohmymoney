import AppCore
import AppDatabase
import SwiftUI
import XCTest

@testable import OhMyMoney

/// The screens of 2.1 («Разбор трат»): the Analytics sections that compare periods and look at
/// days, places and leaks, the two tiles of Overview, the «Разовое» mark in the panel, the menus
/// and the edit, and the settings of the weekend and of the hours of work.
@MainActor
final class SpendingScreensTests: XCTestCase {
  private var environment: AppEnvironment!
  private let moscow = CalendarContext(timeZone: TravelDay.moscowZone)
  private let food = CoreKit.Category(kind: .expense, name: "Food")
  // 2026-10-22 is a Thursday; 9 is a Friday, 10 a Saturday, 12 a Monday.
  private let today = DateOnly(year: 2026, month: 10, day: 22)

  override func setUp() async throws {
    environment = AppEnvironment()
    environment.language.choice = .english
    SpendingTileCache.shared.reset()
  }

  // MARK: Helpers

  private func day(_ month: Int, _ day: Int, year: Int = 2026) -> DateOnly {
    DateOnly(year: year, month: month, day: day)
  }

  private func entry(
    _ whole: Int64, _ on: DateOnly, hour: Int? = nil, oneOff: Bool = false, note: String? = nil,
    place: UUID? = nil, kind: TransactionKind = .expense
  ) throws -> TransactionEntry {
    let when = hour.map { moscow.moment(on, hour: $0, minute: 0) } ?? moscow.noon(of: on)
    var draft = TransactionDraft(
      kind: kind, occurredAt: when, amount: AmountE4(whole: whole), note: note, placeId: place,
      isOneOff: oneOff)
    draft.parts = [PartDraft(categoryId: food.id, amount: AmountE4(whole: whole))]
    return try draft.materialize(timeZone: TravelDay.moscowZone)
  }

  private func dataset(
    _ entries: [TransactionEntry], places: [Place] = [], events: [Event] = [],
    window: WeekendWindow = .standard, hours: WorkHoursSettings = WorkHoursSettings()
  ) -> Dataset {
    Dataset(
      entries: entries, categories: [food], places: places, events: events,
      weekendWindow: window, workHours: hours)
  }

  private func snapshot(_ dataset: Dataset, version: Int = 1) -> DataSnapshot {
    DataSnapshot.build(
      dataset: dataset, calendar: moscow, today: today, context: SnapshotContext(),
      version: DataVersion(load: version))
  }

  private func inputs(_ snapshot: DataSnapshot) -> TileInputs {
    TileInputs(
      ledger: snapshot.ledger, summary: snapshot.summary, planning: snapshot.planning,
      today: snapshot.today)
  }

  private func money(_ whole: Int64) -> String { environment.money.rounded(AmountE4(whole: whole)) }

  // MARK: The weekend tile

  private func weekendBook() throws -> [TransactionEntry] {
    [
      try entry(500, day(10, 9), hour: 19),  // Friday evening: weekend
      try entry(300, day(10, 10)),  // Saturday, no time: the whole day is weekend
      try entry(700, day(10, 12), hour: 10),  // Monday
      try entry(250, day(9, 5)),  // last month, a Saturday
    ]
  }

  func testTheWeekendTileShowsThePriceAndItsShareAndTheMonthBefore() throws {
    let snapshot = snapshot(dataset(try weekendBook()))
    guard
      case .figure(let figure) = SpendingTileText.result(
        of: .weekendPrice, snapshot: snapshot, environment)
    else { return XCTFail("a tile with spending has a figure") }
    XCTAssertEqual(figure.value, money(800))
    XCTAssertTrue(figure.caption?.contains("53") == true, figure.caption ?? "")
    XCTAssertEqual(figure.details, ["Last month: \(money(250))"])
    XCTAssertNotNil(figure.symbol)
  }

  func testTheWeekendTileAndItsBreakdownSayTheSameFigure() throws {
    let snapshot = snapshot(dataset(try weekendBook()))
    let explanation = TileExplanations.explain(.weekendPrice, inputs(snapshot))
    XCTAssertEqual(explanation.figure, .money(AmountE4(whole: 800), .rub))
    XCTAssertEqual(explanation.destination, .analytics(.days))
    let all = try XCTUnwrap(explanation.sections.dropFirst().first)
    XCTAssertEqual(all.addsUp, true, "the weekend and the weekdays come to the month")
    XCTAssertEqual(all.total?.value, .money(AmountE4(whole: 1_500), .rub))
  }

  func testTheWeekendFollowsTheWindowOfTheSettings() throws {
    let narrow = WeekendWindow(
      startWeekday: 6, start: TimeOfDay(hour: 0, minute: 0), endWeekday: 6,
      end: TimeOfDay(hour: 23, minute: 59))
    let snapshot = snapshot(dataset(try weekendBook(), window: narrow))
    guard
      case .figure(let figure) = SpendingTileText.result(
        of: .weekendPrice, snapshot: snapshot, environment)
    else { return XCTFail("figure") }
    XCTAssertEqual(figure.value, money(300), "only Saturday counts, not Friday evening")
  }

  func testTheWeekendTileHasNothingToSayWithoutSpending() {
    let snapshot = snapshot(dataset([]))
    guard
      case .empty(let reason) = SpendingTileText.result(
        of: .weekendPrice, snapshot: snapshot, environment)
    else { return XCTFail("empty") }
    XCTAssertEqual(reason, "No spending this month or last")
    environment.language.choice = .russian
    guard
      case .empty(let russian) = SpendingTileText.result(
        of: .weekendPrice, snapshot: snapshot, environment)
    else { return XCTFail("empty") }
    XCTAssertEqual(russian, "В этом и прошлом месяце трат нет")
  }

  // MARK: The usual day tile

  /// Fourteen weekdays of 100, the latest weekdays before today.
  private func weekdays(_ count: Int) throws -> [TransactionEntry] {
    var entries: [TransactionEntry] = []
    var cursor = today.adding(days: -1)
    while entries.count < count {
      if cursor.weekday <= 4 { entries.append(try entry(100, cursor)) }
      cursor = cursor.adding(days: -1)
    }
    return entries
  }

  func testTheUsualDayTileShowsTheMedianWithWeekdaysAndWeekends() throws {
    let snapshot = snapshot(dataset(try weekdays(14)))
    guard
      case .figure(let figure) = SpendingTileText.result(
        of: .usualDay, snapshot: snapshot, environment)
    else { return XCTFail("fourteen days are enough") }
    XCTAssertEqual(figure.value, money(100))
    XCTAssertEqual(figure.details.count, 2)
    XCTAssertTrue(
      figure.details[0].hasPrefix("Weekdays: \(money(100)) (14 days)"), figure.details[0])
    XCTAssertTrue(figure.details[1].hasPrefix("Not enough data"), figure.details[1])
  }

  func testTheOneOffMarkTakesADayOutOfTheUsualDay() throws {
    var book = try weekdays(13)
    book.append(try entry(5_000, day(8, 5), oneOff: true))
    let marked = snapshot(dataset(book))
    guard
      case .empty(let reason) = SpendingTileText.result(
        of: .usualDay, snapshot: marked, environment)
    else { return XCTFail("13 days with spending are not enough") }
    XCTAssertEqual(reason, "Not enough data: 13 of 14 days with spending")

    book[book.count - 1] = try entry(5_000, day(8, 5))
    SpendingTileCache.shared.reset()
    let plain = snapshot(dataset(book), version: 2)
    guard case .figure = SpendingTileText.result(of: .usualDay, snapshot: plain, environment)
    else { return XCTFail("unmarked, the day counts") }
  }

  func testTheUsualDayTileAndItsBreakdownSayTheSameFigure() throws {
    let snapshot = snapshot(dataset(try weekdays(14)))
    let explanation = TileExplanations.explain(.usualDay, inputs(snapshot))
    XCTAssertEqual(explanation.figure, .money(AmountE4(whole: 100), .rub))
    XCTAssertEqual(explanation.destination, .analytics(.days))
    let empty = TileExplanations.explain(.usualDay, inputs(self.snapshot(dataset([]))))
    if case .empty = empty.state {} else { XCTFail("an empty book explains nothing to count") }
  }

  func testTheNewTilesAreInTheCatalogAndHiddenUntilAdded() {
    for tile in [OverviewTile.weekendPrice, .usualDay] {
      XCTAssertFalse(tile.isShownUnnamed)
      XCTAssertEqual(tile.defaultGroup, .analysis)
      XCTAssertNotNil(OverviewCatalog.item(of: tile))
      XCTAssertTrue(OverviewCatalog.canBeCompact(tile))
      XCTAssertFalse(OverviewLayout.firstRun.shown.contains(tile))
      XCTAssertTrue(OverviewLayout.firstRun.addable(facts: OverviewFacts()).contains(tile))
    }
  }

  // MARK: The comparison

  func testEveryReadyMadePairCountsItsRanges() throws {
    let anchor = MonthKey(year: 2026, month: 8)
    var setup = ComparisonSetup(anchor: anchor)
    let cases: [(ComparisonPairKind, DayRange, DayRange)] = [
      (.monthToPreviousMonth, DayRange(day(8, 1), day(8, 31)), DayRange(day(7, 1), day(7, 31))),
      (
        .monthToSameMonthLastYear, DayRange(day(8, 1), day(8, 31)),
        DayRange(day(8, 1, year: 2025), day(8, 31, year: 2025))
      ),
      (.quarterToPreviousQuarter, DayRange(day(7, 1), day(9, 30)), DayRange(day(4, 1), day(6, 30))),
      (
        .quarterToSameQuarterLastYear, DayRange(day(7, 1), day(9, 30)),
        DayRange(day(7, 1, year: 2025), day(9, 30, year: 2025))
      ),
    ]
    for (kind, current, baseline) in cases {
      setup.kind = kind
      let periods = try XCTUnwrap(setup.pair(anchor: anchor, events: [])).periods()
      XCTAssertEqual(periods.current, current, "\(kind)")
      XCTAssertEqual(periods.baseline, baseline, "\(kind)")
    }
  }

  func testAnEventPairNeedsALiveEventAndACustomPairNeedsRealRanges() throws {
    let anchor = MonthKey(year: 2026, month: 8)
    let event = Event(name: "Trip", startDate: day(8, 3), endDate: day(8, 9))
    var setup = ComparisonSetup(anchor: anchor)
    setup.kind = .eventToUsualMonth
    XCTAssertNil(setup.pair(anchor: anchor, events: [event]), "no event chosen yet")
    setup.chooseDefaultEvent(from: [event])
    XCTAssertEqual(setup.eventId, event.id)
    XCTAssertNotNil(setup.pair(anchor: anchor, events: [event]))
    var archived = event
    archived.archived = true
    XCTAssertNil(setup.pair(anchor: anchor, events: [archived]))

    setup.kind = .custom
    XCTAssertEqual(setup.customCurrent, DayRange(day(8, 1), day(8, 31)))
    XCTAssertNotNil(setup.pair(anchor: anchor, events: []))
    setup.customCurrent = DayRange(day(8, 20), day(8, 10))
    XCTAssertNil(setup.pair(anchor: anchor, events: []), "an end before the start is no range")
    setup.customCurrent = DayRange(day(1, 5), day(1, 20))
    setup.customBaseline = DayRange(day(2, 1), day(2, 3))
    let periods = try XCTUnwrap(setup.pair(anchor: anchor, events: [])).periods()
    XCTAssertEqual(periods.current.dayCount, 16)
    XCTAssertEqual(periods.baseline.dayCount, 3)
  }

  func testEveryPairAndChoiceIsNamedInBothLanguages() {
    for choice in [AppLanguage.Choice.english, .russian] {
      environment.language.choice = choice
      var names: Set<String> = []
      for kind in ComparisonPairKind.allCases {
        let name = SpendingText.name(of: kind, environment)
        XCTAssertFalse(name.hasPrefix("spending."), "\(kind)")
        names.insert(name)
      }
      XCTAssertEqual(names.count, ComparisonPairKind.allCases.count)
      for dimension in ComparisonDimension.allCases {
        XCTAssertFalse(SpendingText.name(of: dimension, environment).hasPrefix("spending."))
      }
      for value in ComparisonChoice.allCases {
        XCTAssertFalse(SpendingText.name(of: value, environment).hasPrefix("spending."))
      }
      for grouping in LeakGrouping.allCases {
        XCTAssertFalse(SpendingText.name(of: grouping, environment).hasPrefix("spending."))
      }
    }
  }

  private func comparison(
    _ book: [TransactionEntry], current: DayRange, baseline: DayRange
  ) -> SpendingComparison {
    SpendingComparison(
      ledger: Ledger(dataset: dataset(book), calendar: moscow),
      periods: ComparisonPeriods(current: current, baseline: baseline))
  }

  func testTheNoteAboutTheMeasureAppearsOnlyWhenTheAppSwitchedToTheAverageDay() throws {
    let book = [try entry(100, day(9, 3)), try entry(300, day(10, 4))]
    let same = comparison(
      book, current: DayRange(day(10, 1), day(10, 31)), baseline: DayRange(day(9, 1), day(9, 30)))
    XCTAssertNil(SpendingText.measureNote(same, environment), "30 and 31 days compare totals")
    let different = comparison(
      book, current: DayRange(day(10, 1), day(10, 10)), baseline: DayRange(day(9, 1), day(9, 30)))
    XCTAssertEqual(
      SpendingText.measureNote(different, environment),
      "per day on average, the periods differ in length")
    environment.language.choice = .russian
    XCTAssertEqual(
      SpendingText.measureNote(different, environment), "в среднем за день, периоды разной длины")
    var forced = ComparisonSetup(anchor: MonthKey(year: 2026, month: 10))
    forced.choice = .perDay
    let chosen = SpendingComparison(
      ledger: Ledger(dataset: dataset(book), calendar: moscow),
      periods: ComparisonPeriods(
        current: DayRange(day(10, 1), day(10, 31)), baseline: DayRange(day(9, 1), day(9, 30))),
      choice: forced.choice)
    XCTAssertEqual(SpendingText.measureNote(chosen, environment), "в среднем за день")
  }

  func testAChangeIsWrittenWithASignAndASymbol() throws {
    let book = [try entry(100, day(9, 3)), try entry(300, day(10, 4))]
    let result = comparison(
      book, current: DayRange(day(10, 1), day(10, 31)), baseline: DayRange(day(9, 1), day(9, 30)))
    let row = try XCTUnwrap(result.rows.first)
    let text = SpendingText.change(row, environment)
    XCTAssertTrue(text.contains("200") && text.contains("%"), text)
    XCTAssertEqual(SpendingText.symbol(of: row), "arrow.up.right")
    XCTAssertEqual(
      SpendingText.symbol(
        of: ComparisonRow(key: .total, current: .zero, baseline: AmountE4(whole: 5))),
      "arrow.down.right")
  }

  func testTheYearAgoLineSaysMoreOrLessInWholePercents() {
    let less = ComparisonRow(
      key: .uncategorized, current: AmountE4(whole: 80), baseline: AmountE4(whole: 100))
    XCTAssertEqual(
      SpendingText.yearAgoLine(less, name: "Taxi", environment),
      "Taxi: 20 % less".replacingOccurrences(of: " %", with: "%"))
    environment.language.choice = .russian
    XCTAssertEqual(
      SpendingText.yearAgoLine(less, name: "Такси", environment)?.hasPrefix("Такси: на 20"), true)
    let new = ComparisonRow(key: .uncategorized, current: AmountE4(whole: 80), baseline: .zero)
    XCTAssertNil(SpendingText.yearAgoLine(new, name: "x", environment), "nothing a year ago")
  }

  func testWithoutAYearOfHistoryTheCardSaysFromWhenTheHistoryBegins() {
    environment.language.choice = .russian
    XCTAssertEqual(
      SpendingText.yearAgoNoData(historyStart: MonthKey(year: 2026, month: 3), environment)
        .hasPrefix("Мало данных: история с "), true)
    XCTAssertTrue(
      SpendingText.yearAgoNoData(historyStart: MonthKey(year: 2026, month: 3), environment)
        .contains("2026"))
    XCTAssertEqual(
      SpendingText.yearAgoNoData(historyStart: nil, environment), "Мало данных: операций ещё нет")
    let ledger = Ledger(
      dataset: dataset([try? entry(100, day(3, 5))].compactMap { $0 }), calendar: moscow)
    let result = YearAgo.build(ledger: ledger, month: MonthKey(year: 2026, month: 10), today: today)
    guard case .notEnoughData(let start) = result else { return XCTFail("seven months of history") }
    XCTAssertEqual(start, MonthKey(year: 2026, month: 3))
  }

  func testTheComparisonFileIsNamedByItsPeriodsAndReadsAsCSV() throws {
    let book = [try entry(100, day(9, 3)), try entry(300, day(10, 4))]
    let result = comparison(
      book, current: DayRange(day(10, 1), day(10, 31)), baseline: DayRange(day(9, 1), day(9, 30)))
    XCTAssertEqual(
      ComparisonCSV.fileName(for: result.periods), "comparison-2026-10-vs-2026-09.csv")
    let names = AnalyticsNames(dataset: dataset(book))
    let data = ComparisonCSV.data(result) { AnalyticsText.name(of: $0, names, self.environment) }
    let text = try XCTUnwrap(String(data: data, encoding: .utf8))
    XCTAssertTrue(text.hasPrefix("row_type,name,current_rub"), text)
    XCTAssertTrue(text.contains("item,Food,300"), text)
    XCTAssertTrue(text.contains("total,Total"), text)
    XCTAssertEqual(ComparisonCSVDocument(data: data).data, data)
  }

  // MARK: Days and time

  func testTheHeatmapShadesAreWholeStepsOfTheBusiestCell() {
    let top = AmountE4(whole: 1_000)
    XCTAssertEqual(HeatmapReading.level(of: .zero, maximum: top), 0)
    XCTAssertEqual(HeatmapReading.level(of: AmountE4(whole: 1), maximum: top), 1)
    XCTAssertEqual(HeatmapReading.level(of: AmountE4(whole: 250), maximum: top), 1)
    XCTAssertEqual(HeatmapReading.level(of: AmountE4(whole: 251), maximum: top), 2)
    XCTAssertEqual(HeatmapReading.level(of: AmountE4(whole: 760), maximum: top), 4)
    XCTAssertEqual(HeatmapReading.level(of: top, maximum: top), 4)
    XCTAssertEqual(HeatmapReading.level(of: top, maximum: .zero), 0)
  }

  func testTheBusiestHoursAreNamedInWords() throws {
    let book = [
      try entry(500, day(10, 9), hour: 19),  // Friday 19:00
      try entry(100, day(10, 12), hour: 9),  // Monday 9:00
      try entry(900, day(10, 10), hour: 23),  // Saturday 23:00
      try entry(40, day(10, 11)),  // Sunday, no time
    ]
    let map = HourHeatmap(
      ledger: Ledger(dataset: dataset(book), calendar: moscow),
      range: DayRange(day(10, 1), day(10, 31)))
    let busiest = HeatmapReading.busiest(map)
    XCTAssertEqual(busiest.map(\.hour), [23, 19, 9])
    XCTAssertEqual(busiest.map(\.weekday), [6, 5, 1])
    XCTAssertEqual(map.withoutTime, 1, "an operation without a time is counted apart")
    XCTAssertEqual(HeatmapReading.busiest(map, limit: 1).count, 1)
  }

  // MARK: Places

  func testAPlaceIsSetOnlyWhereTheDescriptionIsItsName() throws {
    let shop = Place(name: "Пятёрочка", aliases: ["5ka"])
    let cafe = Place(name: "Cafe")
    let twin = Place(name: "cafe")
    let book = [
      try entry(100, day(10, 1), note: "пятерочка"),  // ё = е, case ignored
      try entry(200, day(10, 2), note: "5KA"),  // an alias
      try entry(300, day(10, 3), note: "Пятёрочка у дома"),  // part of a word: not guessed
      try entry(400, day(10, 4), note: "Cafe"),  // two places share the name: left alone
      try entry(500, day(10, 5), note: "пятёрочка", place: cafe.id),  // already has a place
      try entry(600, day(10, 6), note: "пятёрочка", kind: .income),
    ]
    let plan = PlaceFromNotePlan.build(entries: book, places: [shop, cafe, twin])
    XCTAssertEqual(plan.proposals.count, 1)
    XCTAssertEqual(plan.proposals[0].placeId, shop.id)
    XCTAssertEqual(Set(plan.proposals[0].ids), [book[0].id, book[1].id])
    XCTAssertEqual(plan.operationCount, 2)
    XCTAssertEqual(plan.assignments(including: []).count, 0, "a line switched off writes nothing")
    XCTAssertEqual(plan.assignments(including: [shop.id])[book[0].id], shop.id)
    XCTAssertTrue(PlaceFromNotePlan.build(entries: book, places: []).proposals.isEmpty)
  }

  func testTheHintSaysHowManyOperationsHaveNoPlace() throws {
    let shop = Place(name: "Shop")
    let book = [
      try entry(100, day(10, 1), place: shop.id), try entry(100, day(10, 2)),
      try entry(100, day(10, 3)), try entry(100, day(10, 4)),
    ]
    let ledger = Ledger(dataset: dataset(book, places: [shop]), calendar: moscow)
    let places = FavoritePlaces(ledger: ledger, period: .month(MonthKey(year: 2026, month: 10)))
    XCTAssertEqual(
      SpendingText.withoutPlaceHint(places, environment), "75 % of the operations have no place")
    let all = FavoritePlaces(
      ledger: Ledger(
        dataset: dataset([try entry(1, day(10, 1), place: shop.id)], places: [shop]),
        calendar: moscow),
      period: .month(MonthKey(year: 2026, month: 10)))
    XCTAssertNil(SpendingText.withoutPlaceHint(all, environment))
  }

  // MARK: Leaks, limits, hours

  func testTheLeakLineReadsAsASentenceInBothLanguages() {
    XCTAssertEqual(
      SpendingText.leakLine(
        name: "Coffee", largest: AmountE4(whole: 300), count: 22, perMonth: AmountE4(whole: 5_900),
        environment),
      "Coffee up to \(money(300)) · 22 times · \(money(5_900)) a month")
    environment.language.choice = .russian
    XCTAssertEqual(
      SpendingText.leakLine(
        name: "Кофе", largest: AmountE4(whole: 300), count: 22, perMonth: AmountE4(whole: 5_900),
        environment),
      "Кофе до \(money(300)) · 22 раза · \(money(5_900)) в месяц")
  }

  func testWhatAteTheLimitNamesTheOthersWithTheirCeiling() throws {
    var book = [try entry(900, day(10, 1)), try entry(800, day(10, 2)), try entry(700, day(10, 3))]
    for dayNumber in 4...7 { book.append(try entry(100, day(10, dayNumber))) }
    let eaten = LimitConsumption(
      ledger: Ledger(dataset: dataset(book), calendar: moscow), categoryId: food.id,
      month: MonthKey(year: 2026, month: 10))
    XCTAssertEqual(eaten.largest.count, 3)
    XCTAssertEqual(
      SpendingText.othersLine(eaten, environment),
      "and 4 more purchases up to \(money(100)) — \(money(400))")
    environment.language.choice = .russian
    XCTAssertEqual(
      SpendingText.othersLine(eaten, environment),
      "и ещё 4 покупки до \(money(100)) — \(money(400))")
    let few = LimitConsumption(
      ledger: Ledger(dataset: dataset([book[0]]), calendar: moscow), categoryId: food.id,
      month: MonthKey(year: 2026, month: 10))
    XCTAssertNil(SpendingText.othersLine(few, environment), "no others, no line")
  }

  func testThePriceInHoursNeedsTheSwitchAndFollowsTheHours() throws {
    // Three months of 168 000 earned: 1 000 an hour at 168 hours a month.
    var book: [TransactionEntry] = []
    for month in [7, 8, 9] {
      book.append(try entry(168_000, day(month, 10), kind: .income))
    }
    let on = Ledger(dataset: dataset(book), calendar: moscow)
    let off = WorkRate(ledger: on, today: today, settings: WorkHoursSettings())
    XCTAssertNil(off, "switched off: no price in hours anywhere")
    let rate = try XCTUnwrap(
      WorkRate(
        ledger: on, today: today, settings: WorkHoursSettings(isEnabled: true, hoursPerMonth: 168)))
    XCTAssertEqual(rate.hourly, AmountE4(whole: 1_000))
    XCTAssertEqual(
      SpendingText.hoursLine(rate, price: AmountE4(whole: 14_000), environment),
      "14 hours of your work")
    environment.language.choice = .russian
    XCTAssertEqual(
      SpendingText.hoursLine(rate, price: AmountE4(whole: 14_000), environment),
      "14 часов вашей работы")
    let other = try XCTUnwrap(
      WorkRate(
        ledger: on, today: today, settings: WorkHoursSettings(isEnabled: true, hoursPerMonth: 84)))
    XCTAssertEqual(other.wholeHours(for: AmountE4(whole: 14_000)), 7, "own hours change the result")
  }

  // MARK: The settings

  func testTheWeekendSettingsRoundTripThroughTimePickers() {
    let time = TimeOfDay(hour: 20, minute: 30)
    let date = SpendingAnalysisSettingsForm.date(for: time)
    XCTAssertEqual(SpendingAnalysisSettingsForm.time(from: date), time)
    let start = SpendingAnalysisSettingsForm.settingStart(
      .standard, weekday: 4, time: TimeOfDay(hour: 20, minute: 0))
    XCTAssertEqual(start.startWeekday, 4)
    XCTAssertEqual(start.endWeekday, 7, "the end stays")
    let over = SpendingAnalysisSettingsForm.settingEnd(
      start, weekday: 1, time: TimeOfDay(hour: 6, minute: 0))
    XCTAssertEqual(
      over.storedValue, "4@20:00-1@06:00", "an end before the start runs over the week")
    XCTAssertEqual(WeekendWindow(storedValue: over.storedValue), over)
    XCTAssertEqual(SpendingAnalysisSettingsForm.hoursRange, 1...744)
    XCTAssertEqual(WorkHoursSettings().hoursPerMonth, 168, "the default of the hours")
  }

  func testTheWindowIsToldInWordsInBothLanguages() {
    XCTAssertEqual(
      SpendingText.windowLine(.standard, environment), "Friday 18:00 — Sunday 23:59")
    environment.language.choice = .russian
    XCTAssertEqual(
      SpendingText.windowLine(.standard, environment).lowercased(),
      "пятница 18:00 — воскресенье 23:59")
  }

  // MARK: The menu

  func testTheMenuMarksUnlessEverythingIsMarkedAlready() throws {
    let plain = try entry(100, day(10, 1))
    let marked = try entry(100, day(10, 2), oneOff: true)
    let income = try entry(100, day(10, 3), kind: .income)
    XCTAssertEqual(OneOffMenu.action(for: [plain]), .mark)
    XCTAssertEqual(OneOffMenu.action(for: [marked]), .unmark)
    XCTAssertEqual(OneOffMenu.action(for: [plain, marked]), .mark)
    XCTAssertEqual(OneOffMenu.action(for: [marked, marked]), .unmark)
    XCTAssertNil(OneOffMenu.action(for: [income]), "an income is not spending")
    XCTAssertNil(OneOffMenu.action(for: []))
    XCTAssertEqual(OneOffMenu.targets(in: [plain, income, marked]), [plain.id, marked.id])
  }

  // MARK: Sections

  func testTheNewSectionsAreInTheSidebarWithNamesAndSymbolsInBothLanguages() {
    let spending = AnalyticsSection.allCases.filter(\.isSpending)
    XCTAssertEqual(spending, [.comparison, .days, .habits, .leaks])
    for choice in [AppLanguage.Choice.english, .russian] {
      environment.language.choice = choice
      var titles: Set<String> = []
      for section in AnalyticsSection.allCases {
        let title = AnalyticsText.t(section.titleKey, environment)
        XCTAssertNotEqual(title, section.titleKey, "\(section) \(choice)")
        titles.insert(title)
      }
      XCTAssertEqual(titles.count, AnalyticsSection.allCases.count, "two sections share a name")
    }
    for section in spending {
      XCTAssertTrue(section.followsThePeriod)
      XCTAssertNil(section.plannedFor)
      XCTAssertFalse(section.symbol.isEmpty)
    }
    XCTAssertTrue(AnalyticsSection.allCases.filter { !$0.isSpending }.allSatisfy { !$0.isSpending })
  }

  func testTheSpendingSectionsBuildNoModelOfTheirOwn() {
    let ledger = Ledger(dataset: dataset([]), calendar: moscow)
    for section in AnalyticsSection.allCases where section.isSpending {
      let request = AnalyticsRequest(section: section, period: .month(today.monthKey), today: today)
      XCTAssertEqual(AnalyticsBuilder.model(request, ledger: ledger).request.section, section)
    }
  }

  func testTheTileOpensTheSectionOfDaysAndTime() {
    XCTAssertEqual(AnalyticsSection(rawValue: TileAnalyticsSection.days.rawValue), .days)
  }

  // MARK: Words

  func testEveryWordOfTheSpendingScreensIsInBothLanguages() {
    for choice in [AppLanguage.Choice.english, .russian] {
      environment.language.choice = choice
      for key in SpendingText.keys + SpendingText.countedKeys + SpendingText.breakdownKeys {
        XCTAssertNotEqual(
          environment.language(key, table: SpendingText.table), key, "\(key) \(choice)")
      }
      for tile in [OverviewTile.weekendPrice, .usualDay] {
        XCTAssertNotEqual(
          OverviewTileText.name(of: tile, environment), OverviewTileText.nameKey(of: tile))
        XCTAssertNotEqual(
          environment.language("why.rule.\(tile.rawValue)", table: "Overview"),
          "why.rule.\(tile.rawValue)")
      }
      XCTAssertNotEqual(
        environment.language("why.open.analytics.days", table: "Overview"),
        "why.open.analytics.days")
    }
  }

  func testTheCountedWordsPickTheirPluralFormInBothLanguages() {
    func said(_ key: String, _ count: Int, _ choice: AppLanguage.Choice) -> String {
      environment.language.choice = choice
      return SpendingText.counted(key, environment, count: count)
    }
    XCTAssertEqual(said("spending.hours.price", 1, .english), "1 hour of your work")
    XCTAssertEqual(said("spending.hours.price", 3, .english), "3 hours of your work")
    XCTAssertEqual(said("spending.hours.price", 1, .russian), "1 час вашей работы")
    XCTAssertEqual(said("spending.hours.price", 3, .russian), "3 часа вашей работы")
    XCTAssertEqual(said("spending.hours.price", 18, .russian), "18 часов вашей работы")
    XCTAssertEqual(said("spending.leaks.times", 5, .russian), "5 раз")
    XCTAssertEqual(said("spending.places.visits", 22, .russian), "22 визита")
    XCTAssertEqual(said("spending.places.visits", 1, .english), "1 visit")
    XCTAssertEqual(said("spending.heat.withoutTime", 2, .russian).hasPrefix("2 операции"), true)
  }

  func testTheBreakdownPhrasesOfTheNewTilesCarryTheirOwnCatalog() throws {
    let explanation = TileExplanations.explain(
      .weekendPrice, inputs(snapshot(dataset(try weekendBook()))))
    let phrases = explanation.sections.flatMap {
      [$0.title].compactMap { $0 } + $0.rows.map(\.label)
    }
    XCTAssertTrue(phrases.allSatisfy { $0.table == TileExplanations.spendingTable })
    XCTAssertEqual(TileExplanations.spendingTable, SpendingText.table)
    XCTAssertEqual(explanation.rule.key, "why.rule.weekendPrice")
  }

  // MARK: The edit and the panel

  func testAnEditKeepsTheOneOffMarkAndCanChangeIt() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-oneoff-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let before = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    setenv("OHMYMONEY_DATA_DIR", directory.path, 1)
    defer {
      if let before {
        setenv("OHMYMONEY_DATA_DIR", before, 1)
      } else {
        unsetenv("OHMYMONEY_DATA_DIR")
      }
      try? FileManager.default.removeItem(at: directory)
    }
    let live = AppEnvironment()
    await live.start(preparing: { try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main)) })
    defer { Task { await live.close() } }
    let store = TransactionsStore()
    store.attach(
      try XCTUnwrap(live.transactions), references: live.references, planning: live.planning,
      spending: live.spendingRules)

    var draft = TransactionDraft(
      occurredAt: Date().addingTimeInterval(-3_600), amount: AmountE4(whole: 400), note: "cinema",
      isOneOff: true)
    draft.normalizeSinglePart()
    let saved = try draft.materialize()
    XCTAssertTrue(store.save(saved))

    // A new operation made in the panel with the field on is saved marked.
    XCTAssertTrue(
      try XCTUnwrap(try XCTUnwrap(live.transactions).entries(ids: [saved.id]).first).transaction
        .isOneOff)

    // An edit of the note alone leaves the mark.
    let editor = TransactionEditorModel(entry: saved, environment: live)
    XCTAssertTrue(editor.draft.draft.isOneOff, "the panel shows the mark of the operation")
    editor.draft.draft.note = "cinema with friends"
    XCTAssertTrue(editor.save(store: store, environment: live))
    let after = try XCTUnwrap(try XCTUnwrap(live.transactions).entries(ids: [saved.id]).first)
    XCTAssertEqual(after.transaction.note, "cinema with friends")
    XCTAssertTrue(after.transaction.isOneOff)

    // The field turns it off in the edit; one ⌘Z brings it back.
    let second = TransactionEditorModel(entry: after, environment: live)
    second.draft.draft.isOneOff = false
    XCTAssertTrue(second.hasChanges)
    XCTAssertTrue(second.save(store: store, environment: live))
    let off = try XCTUnwrap(try XCTUnwrap(live.transactions).entries(ids: [saved.id]).first)
    XCTAssertFalse(off.transaction.isOneOff)
    store.undo()
    let back = try XCTUnwrap(try XCTUnwrap(live.transactions).entries(ids: [saved.id]).first)
    XCTAssertTrue(back.transaction.isOneOff)

    // The menu marks and unmarks a selection in one step each.
    var another = TransactionDraft(
      occurredAt: Date().addingTimeInterval(-1_800), amount: AmountE4(whole: 90), note: "tea",
      isOneOff: true)
    another.normalizeSinglePart()
    let other = try another.materialize()
    XCTAssertTrue(store.save(other))
    let selection = try XCTUnwrap(live.transactions).entries(ids: [saved.id, other.id])
    XCTAssertEqual(OneOffMenu.action(for: selection), .unmark)
    XCTAssertTrue(
      store.setOneOff(false, ids: OneOffMenu.targets(in: selection)),
      "\(String(describing: store.lastError)) \(String(describing: store.failure))")
    func marks() throws -> Int {
      try XCTUnwrap(live.transactions).entries(ids: [saved.id, other.id])
        .filter(\.transaction.isOneOff).count
    }
    XCTAssertEqual(try marks(), 0)
    store.undo()
    XCTAssertEqual(try marks(), 2)
  }

  // MARK: Places written at once

  func testPlacesFromDescriptionsAreOneWriteAndOneStepOfUndo() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-places-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let before = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    setenv("OHMYMONEY_DATA_DIR", directory.path, 1)
    defer {
      if let before {
        setenv("OHMYMONEY_DATA_DIR", before, 1)
      } else {
        unsetenv("OHMYMONEY_DATA_DIR")
      }
      try? FileManager.default.removeItem(at: directory)
    }
    let live = AppEnvironment()
    await live.start(preparing: { try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main)) })
    defer { Task { await live.close() } }
    let store = TransactionsStore()
    store.attach(
      try XCTUnwrap(live.transactions), references: live.references, planning: live.planning,
      spending: live.spendingRules)

    func save(_ note: String) throws -> TransactionEntry {
      var draft = TransactionDraft(
        occurredAt: Date().addingTimeInterval(-3_600), amount: AmountE4(whole: 100), note: note)
      draft.normalizeSinglePart()
      let entry = try draft.materialize()
      XCTAssertTrue(store.save(entry))
      return entry
    }
    let first = try save("Shop")
    let second = try save("shop")
    let place = Place(name: "Shop")
    try XCTUnwrap(live.references).save(place)

    XCTAssertTrue(store.setPlaces([first.id: place.id, second.id: place.id]))
    func places() throws -> [UUID] {
      try XCTUnwrap(live.transactions).entries(ids: [first.id, second.id])
        .compactMap(\.transaction.placeId)
    }
    XCTAssertEqual(try places(), [place.id, place.id])
    // Written again, nothing changes and no step is added.
    XCTAssertTrue(store.setPlaces([first.id: place.id]))
    store.undo()
    XCTAssertEqual(try places(), [], "one ⌘Z takes both places away")
    XCTAssertFalse(store.setPlaces([:]))
  }
}
