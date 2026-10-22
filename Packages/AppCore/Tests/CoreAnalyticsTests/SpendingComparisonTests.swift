import CoreKit
import Foundation
import Testing

@testable import CoreAnalytics

/// «Разбор трат», part 1: two periods side by side, «я год назад», the CSV and the cache.
@Suite("Comparison of two periods")
struct SpendingComparisonTests {
  private func day(_ month: Int, _ day: Int, year: Int = 2026) -> DateOnly {
    SpendKit.day(year, month, day)
  }

  private func money(_ whole: Int64) -> AmountE4 { AmountE4(whole: whole) }

  // MARK: - The ready pairs

  @Test func everyReadyPairGivesItsTwoRanges() {
    let sameMonth = ComparisonPair.monthToSameMonthLastYear(MonthKey(year: 2026, month: 9))
      .periods()
    #expect(sameMonth.current == DayRange(day(9, 1), day(9, 30)))
    #expect(sameMonth.baseline == DayRange(day(9, 1, year: 2025), day(9, 30, year: 2025)))

    let previous = ComparisonPair.monthToPreviousMonth(MonthKey(year: 2026, month: 1)).periods()
    #expect(previous.baseline == DayRange(day(12, 1, year: 2025), day(12, 31, year: 2025)))

    let quarter = ComparisonPair.quarterToPreviousQuarter(year: 2026, quarter: 1).periods()
    #expect(quarter.current == DayRange(day(1, 1), day(3, 31)))
    #expect(quarter.baseline == DayRange(day(10, 1, year: 2025), day(12, 31, year: 2025)))

    let lastYear = ComparisonPair.quarterToSameQuarterLastYear(year: 2026, quarter: 3).periods()
    #expect(lastYear.current == DayRange(day(7, 1), day(9, 30)))
    #expect(lastYear.baseline == DayRange(day(7, 1, year: 2025), day(9, 30, year: 2025)))

    let own = ComparisonPair.custom(
      current: DayRange(day(2, 3), day(2, 9)), baseline: DayRange(day(5, 1), day(5, 20)))
    #expect(own.periods().current == DayRange(day(2, 3), day(2, 9)))
    #expect(own.periods().baseline == DayRange(day(5, 1), day(5, 20)))
  }

  @Test func anEventIsSetAgainstTheClosestMonthNoEventTouches() {
    let wedding = Event(name: "Wedding", startDate: day(8, 20), endDate: day(8, 24))
    let holiday = Event(name: "Holiday", startDate: day(7, 28), endDate: day(8, 3))
    // July is touched by the holiday, June is free.
    let periods = ComparisonPair.eventToUsualMonth(wedding).periods(events: [wedding, holiday])
    #expect(periods.current == DayRange(day(8, 20), day(8, 24)))
    #expect(periods.baseline == DayRange(day(6, 1), day(6, 30)))
    // With no other event, the month right before the event's own.
    let alone = ComparisonPair.eventToUsualMonth(wedding).periods(events: [wedding])
    #expect(alone.baseline == DayRange(day(7, 1), day(7, 31)))
    // An event that begins in the first days of a month does not touch the month before it.
    let early = Event(name: "Early", startDate: day(8, 1), endDate: day(8, 2))
    #expect(
      ComparisonPair.eventToUsualMonth(early).periods(events: [early]).baseline
        == DayRange(day(7, 1), day(7, 31)))
  }

  // MARK: - Sums agree with the Reports

  @Test func theFiguresAreTheSumsOfTheReports() throws {
    let entries = [
      try SpendKit.purchase(1_000, on: day(9, 5), category: SpendKit.food),
      try SpendKit.purchase(400, on: day(9, 6), category: SpendKit.dairy),
      try SpendKit.purchase(700, on: day(9, 7), category: SpendKit.taxi),
      try SpendKit.purchase(900, on: day(9, 5, year: 2025), category: SpendKit.food),
      try SpendKit.purchase(1_500, on: day(9, 9, year: 2025), category: SpendKit.fun),
    ]
    let ledger = SpendKit.ledger(entries)
    let periods = ComparisonPair.monthToSameMonthLastYear(MonthKey(year: 2026, month: 9)).periods()
    let comparison = SpendingComparison(ledger: ledger, periods: periods)
    #expect(comparison.measure == .totals)

    let builder = ReportBuilder(ledger: ledger, today: day(10, 1))
    for (range, pick) in [
      (periods.current, \ComparisonRow.current), (periods.baseline, \ComparisonRow.baseline),
    ] {
      let table = builder.table(.expensesByCategory, period: .days(range))
      for report in table.rows {
        let row = try #require(comparison.rows.first { $0.key == report.key })
        #expect(row[keyPath: pick] == report.amount)
      }
      #expect(comparison.total[keyPath: pick] == table.total.amount)
    }
    // Food and its subcategory are one line, the top-level category.
    let foodRow = try #require(
      comparison.rows.first { $0.key == .category(SpendKit.food.id) })
    #expect(foodRow.current == money(1_400))
    #expect(foodRow.baseline == money(900))
    #expect(foodRow.changeBasisPoints == 5_556)
    // A category that had nothing in the baseline has no percentage to show.
    let taxiRow = try #require(comparison.rows.first { $0.key == .category(SpendKit.taxi.id) })
    #expect(taxiRow.changeBasisPoints == nil)
    #expect(taxiRow.delta == money(700))
    // The largest current figure comes first.
    #expect(comparison.rows.first?.key == .category(SpendKit.food.id))
  }

  @Test func aReconciliationDifferenceIsNoSpending() throws {
    var counted = try SpendKit.purchase(5_000, on: day(9, 10), category: SpendKit.fun)
    counted.transaction.externalId = "reconcile:\(UUID().uuidString.lowercased())"
    let ledger = SpendKit.ledger([counted, try SpendKit.purchase(100, on: day(9, 11))])
    let comparison = SpendingComparison(
      ledger: ledger,
      periods: ComparisonPair.monthToPreviousMonth(MonthKey(year: 2026, month: 9)).periods())
    #expect(comparison.total.current == money(100))
  }

  // MARK: - Periods of different length

  @Test func lengthsWithinThreeDaysAreComparedByTotals() {
    func periods(_ current: Int, _ baseline: Int) -> ComparisonPeriods {
      ComparisonPeriods(
        current: DayRange(day(9, 1), day(9, 1).adding(days: current - 1)),
        baseline: DayRange(day(3, 1), day(3, 1).adding(days: baseline - 1)))
    }
    #expect(periods(30, 31).measure(for: .automatic) == .totals)
    #expect(periods(30, 33).measure(for: .automatic) == .totals)
    #expect(periods(30, 34).measure(for: .automatic) == .perDay)
    #expect(periods(10, 30).measure(for: .automatic) == .perDay)
    #expect(periods(10, 30).measure(for: .totals) == .totals)
    #expect(periods(30, 31).measure(for: .perDay) == .perDay)
  }

  @Test func theNoteAboutLengthsShowsOnlyWhenTheAppSwitched() throws {
    let ledger = SpendKit.ledger([
      try SpendKit.purchase(600, on: day(9, 2)), try SpendKit.purchase(300, on: day(8, 5)),
    ])
    let short = DayRange(day(9, 1), day(9, 10))
    let long = DayRange(day(8, 1), day(8, 30))
    let automatic = SpendingComparison(
      ledger: ledger, periods: ComparisonPeriods(current: short, baseline: long))
    #expect(automatic.measure == .perDay)
    #expect(automatic.showsDifferentLengthNote)
    // 600 over 10 days and 300 over 30 days.
    #expect(automatic.total.current == money(60))
    #expect(automatic.total.baseline == money(10))

    let totals = SpendingComparison(
      ledger: ledger, periods: ComparisonPeriods(current: short, baseline: long), choice: .totals)
    #expect(totals.total.current == money(600))
    #expect(!totals.showsDifferentLengthNote)
    let forced = SpendingComparison(
      ledger: ledger, periods: ComparisonPeriods(current: short, baseline: long), choice: .perDay)
    #expect(forced.measure == .perDay)
    #expect(!forced.showsDifferentLengthNote)

    let same = SpendingComparison(
      ledger: ledger,
      periods: ComparisonPair.monthToPreviousMonth(MonthKey(year: 2026, month: 9)).periods())
    #expect(same.measure == .totals)
    #expect(!same.showsDifferentLengthNote)
  }

  @Test func oneOffPurchasesAreInTheTotalsButNotInTheAverageDay() throws {
    let big = try SpendKit.purchase(30_000, on: day(9, 4))
    let ordinary = try SpendKit.purchase(3_000, on: day(9, 8))
    let ledger = SpendKit.ledger([big, ordinary])
    let periods = ComparisonPeriods(
      current: DayRange(day(9, 1), day(9, 30)), baseline: DayRange(day(8, 1), day(8, 31)))
    let marks = OneOffMarks(ids: [big.id])
    let totals = SpendingComparison(ledger: ledger, periods: periods, oneOff: marks)
    #expect(totals.total.current == money(33_000))
    let perDay = SpendingComparison(
      ledger: ledger, periods: periods, choice: .perDay, oneOff: marks)
    #expect(perDay.total.current == money(100))
    let unmarked = SpendingComparison(ledger: ledger, periods: periods, choice: .perDay)
    #expect(unmarked.total.current == money(1_100))
  }

  // MARK: - Places and people

  @Test func placesAndPeopleAreOtherWaysToSplit() throws {
    let cafe = Place(name: "Cafe")
    let anya = Person(name: "Anya")
    let ledger = SpendKit.ledger(
      [
        try SpendKit.purchase(500, on: day(9, 3), place: cafe.id),
        try SpendKit.purchase(200, on: day(9, 4)),
        try SpendKit.purchase(800, on: day(9, 5), person: anya.id),
        try SpendKit.purchase(300, on: day(8, 5), place: cafe.id),
      ], places: [cafe], people: [anya])
    let periods = ComparisonPair.monthToPreviousMonth(MonthKey(year: 2026, month: 9)).periods()
    let places = SpendingComparison(ledger: ledger, periods: periods, dimension: .place)
    #expect(places.rows.map(\.key) == [.place(cafe.id), .noPlace])
    #expect(places.rows[0].current == money(500))
    #expect(places.rows[0].baseline == money(300))
    #expect(places.rows.last?.key.isRemainder == true)
    let people = SpendingComparison(ledger: ledger, periods: periods, dimension: .person)
    #expect(people.rows.map(\.key) == [.person(anya.id)])
    #expect(people.total.current == money(800))
  }

  // MARK: - CSV

  @Test func theCSVHasTheShapeOfAReportAndANameFromThePeriods() throws {
    let ledger = SpendKit.ledger([
      try SpendKit.purchase(1_000, on: day(9, 5), category: SpendKit.food),
      try SpendKit.purchase(250, on: day(9, 6), category: SpendKit.taxi),
      try SpendKit.purchase(900, on: day(9, 5, year: 2025), category: SpendKit.food),
    ])
    let periods = ComparisonPair.monthToSameMonthLastYear(MonthKey(year: 2026, month: 9)).periods()
    let comparison = SpendingComparison(ledger: ledger, periods: periods)
    let names: [ReportKey: String] = [
      .category(SpendKit.food.id): "Food", .category(SpendKit.taxi.id): "Taxi, evening",
    ]
    let data = ComparisonCSV.data(comparison, label: { names[$0] ?? "?" })
    let lines = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    #expect(
      lines[0]
        == "row_type,name,current_rub,current_rub_exact,baseline_rub,baseline_rub_exact,"
        + "delta_rub,delta_rub_exact,share")
    #expect(lines[1] == "item,Food,1000,1000.0000,900,900.0000,100,100.0000,0.8000")
    // A comma in a name is quoted.
    #expect(lines[2].hasPrefix("item,\"Taxi, evening\",250,250.0000,0,0.0000,250,250.0000,"))
    #expect(lines[3].hasPrefix("total,Total,1250,1250.0000,900,900.0000,350,350.0000,1.0000"))
    #expect(lines.count == 4)

    #expect(ComparisonCSV.fileName(for: periods) == "comparison-2026-09-vs-2025-09.csv")
    let quarters = ComparisonPair.quarterToPreviousQuarter(year: 2026, quarter: 2).periods()
    #expect(ComparisonCSV.fileName(for: quarters) == "comparison-2026-Q2-vs-2026-Q1.csv")
    let own = ComparisonPeriods(
      current: DayRange(day(2, 3), day(2, 9)), baseline: DayRange(day(5, 1), day(5, 20)))
    #expect(
      ComparisonCSV.fileName(for: own)
        == "comparison-2026-02-03_2026-02-09-vs-2026-05-01_2026-05-20.csv")
  }

  // MARK: - A year ago

  @Test func withAYearOfHistoryTheMonthIsSetAgainstLastYear() throws {
    var entries = [
      try SpendKit.purchase(10, on: day(8, 20, year: 2025)),
      try SpendKit.purchase(1_000, on: day(9, 3, year: 2025), category: SpendKit.taxi),
      try SpendKit.purchase(2_000, on: day(9, 4, year: 2025), category: SpendKit.food),
      try SpendKit.purchase(800, on: day(9, 3), category: SpendKit.taxi),
      try SpendKit.purchase(2_000, on: day(9, 20), category: SpendKit.food),
    ]
    entries.append(try SpendKit.purchase(100, on: day(2, 1)))
    let ledger = SpendKit.ledger(entries)
    let result = YearAgo.build(
      ledger: ledger, month: MonthKey(year: 2026, month: 9), today: day(10, 14))
    guard case .comparison(let ago) = result else {
      Issue.record("expected a comparison, got \(result)")
      return
    }
    let taxi = try #require(ago.changes.first { $0.key == .category(SpendKit.taxi.id) })
    #expect(taxi.changeBasisPoints == -2_000)  // «на такси на 20 % меньше»
    let food = try #require(ago.changes.first { $0.key == .category(SpendKit.food.id) })
    #expect(food.changeBasisPoints == 0)
  }

  @Test func theMonthNotOverIsComparedByTheSameDaysOfLastYear() throws {
    let ledger = SpendKit.ledger([
      try SpendKit.purchase(10, on: day(8, 20, year: 2025)),
      try SpendKit.purchase(500, on: day(9, 2, year: 2025)),
      try SpendKit.purchase(9_000, on: day(9, 25, year: 2025)),
      try SpendKit.purchase(600, on: day(9, 3)),
    ])
    let result = YearAgo.build(
      ledger: ledger, month: MonthKey(year: 2026, month: 9), today: day(9, 10))
    guard case .comparison(let ago) = result else {
      Issue.record("expected a comparison")
      return
    }
    #expect(ago.comparison.periods.current == DayRange(day(9, 1), day(9, 10)))
    #expect(
      ago.comparison.periods.baseline == DayRange(day(9, 1, year: 2025), day(9, 10, year: 2025)))
    #expect(ago.comparison.total.baseline == money(500))
  }

  @Test func withLessThanAYearTheBlockSaysWhereTheHistoryBegins() throws {
    let ledger = SpendKit.ledger([
      try SpendKit.purchase(100, on: day(3, 14)), try SpendKit.purchase(100, on: day(9, 1)),
    ])
    let result = YearAgo.build(
      ledger: ledger, month: MonthKey(year: 2026, month: 9), today: day(10, 14))
    #expect(result == .notEnoughData(historyStart: MonthKey(year: 2026, month: 3)))
    #expect(
      YearAgo.build(
        ledger: .init(dataset: .empty, calendar: SpendKit.moscow),
        month: MonthKey(year: 2026, month: 9), today: day(10, 14))
        == .notEnoughData(historyStart: nil))
    // A baseline month that was only begun then is not a month to compare with.
    let started = SpendKit.ledger([try SpendKit.purchase(100, on: day(9, 20, year: 2025))])
    #expect(
      YearAgo.build(ledger: started, month: MonthKey(year: 2026, month: 9), today: day(10, 14))
        == .notEnoughData(historyStart: MonthKey(year: 2025, month: 9)))
  }

  // MARK: - The cache

  @Test func aCachedResultLivesUntilTheDataChanges() {
    let cache = AnalysisCache<Int>()
    var computed = 0
    func ask(version: Int) -> Int {
      cache.value(for: "september", datasetVersion: version) {
        computed += 1
        return computed
      }
    }
    #expect(ask(version: 1) == 1)
    #expect(ask(version: 1) == 1)
    #expect(computed == 1)
    #expect(ask(version: 2) == 2)
    #expect(computed == 2)
    #expect(cache.count == 1)
    // A written operation moves the version of the snapshot, and the old result is gone.
    let before = Dataset(entries: [])
    #expect(before.upserting([try! SpendKit.purchase(1, on: day(9, 1))]).version != before.version)
  }
}
