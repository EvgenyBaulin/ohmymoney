import AppCore
import AppKit
import SwiftUI
import XCTest

@testable import OhMyMoney

/// A mistyped amount of the golden set or of a literal in these tests (`money(_:)` of
/// `GoldenSet.swift`, which this bundle compiles too): a failed test that names it.
func reportAmountTypo(_ text: String) {
  XCTFail("«\(text)» is not an amount: write a plain decimal, such as 1250.5")
}

/// The models of the Analytics window: the core's slices turned into what the
/// charts plot — whole rubles rounded once, buckets with their days inside the period, the
/// forecast as lines over the month — and the thresholds under which a block says «Мало
/// данных» instead of drawing empty axes. Pure, so these run off the main actor.
final class AnalyticsModelTests: XCTestCase {
  private let food = CoreKit.Category(kind: .expense, name: "Food")
  private let salary = CoreKit.Category(kind: .income, name: "Salary")

  private let september = MonthKey(year: 2026, month: 9)

  private func day(_ number: Int, of month: MonthKey? = nil) -> DateOnly {
    let month = month ?? september
    return DateOnly(year: month.year, month: month.month, day: number)
  }

  /// One operation of one part in rubles given as a decimal text: «100.5».
  private func entry(
    _ kind: TransactionKind, _ rubles: String, on day: DateOnly, category: UUID? = nil,
    forWhom: ForWhom = .me
  ) -> TransactionEntry {
    let id = UUID()
    let amount = money(rubles)
    let when = CalendarContext.utc.startOfDay(day).addingTimeInterval(12 * 3600)
    return TransactionEntry(
      transaction: Transaction(
        id: id, kind: kind, occurredAt: when, amountE4: amount, createdAt: when, updatedAt: when),
      parts: [
        TransactionPart(
          transactionId: id, categoryId: category ?? (kind == .income ? salary.id : food.id),
          quality: kind.hasQuality ? .neutral : nil,
          qualitySource: kind.hasQuality ? .category : nil, amountE4: amount, forWhom: forWhom)
      ])
  }

  private func ledger(_ entries: [TransactionEntry]) -> Ledger {
    Ledger(dataset: Dataset(entries: entries, categories: [food, salary]), calendar: .utc)
  }

  private func request(
    _ section: AnalyticsSection, _ period: Period, today: DateOnly,
    forecast: ForecastInputs? = nil, anomalies: AnomalyReport? = nil
  ) -> AnalyticsRequest {
    AnalyticsRequest(
      section: section, period: period, today: today, forecast: forecast,
      anomalies: section == .anomalies ? (anomalies ?? AnomalyReport()) : nil)
  }

  // MARK: - Fixtures

  /// An amount these tests write as text is a plain decimal. A typo is a failed test that
  /// names it, never a quiet zero or the number `Decimal(string:)` finds at its start: «1 000»
  /// was 1, «1000 ₽» was 1000, «abc» was 0.
  func testAMistypedAmountIsAFailedTest() {
    for text in ["1 000", "1,000", "1000 ₽", "1e3", ".5", "0.12345", "abc", ""] {
      XCTExpectFailure("«\(text)» is not an amount") {
        _ = entry(.expense, text, on: day(1))
      }
      XCTExpectFailure("«\(text)» is not an amount") { _ = money(text) }
    }
    XCTAssertEqual(entry(.expense, "-1234.5", on: day(1)).transaction.amountE4.raw, -12_345_000)
  }

  // MARK: - Buckets

  /// 1 September 2026 is a Tuesday: the first week bucket runs from the 1st, not from the
  /// Monday before, and the last one stops on the 30th.
  func testAWeekBucketCoversOnlyTheDaysOfThePeriod() {
    let ledger = ledger([
      entry(.expense, "100", on: day(1)), entry(.expense, "50", on: day(7)),
      entry(.expense, "25", on: day(30)),
    ])
    let series = AnalyticsBuilder.timeSeries(
      TimeSeries(ledger: ledger, period: .month(september), step: .week, today: day(30)),
      period: .month(september))

    XCTAssertEqual(series.buckets.first?.start, day(1))
    XCTAssertEqual(series.buckets.first?.end, day(6))
    XCTAssertEqual(series.buckets.first?.value, 100)
    XCTAssertEqual(series.buckets[1].start, day(7))
    XCTAssertEqual(series.buckets[1].end, day(13))
    XCTAssertEqual(series.buckets.last?.start, day(28))
    XCTAssertEqual(series.buckets.last?.end, day(30))
    XCTAssertEqual(series.buckets.last?.value, 25)
    XCTAssertEqual(series.buckets.count, 5)
  }

  /// Whole rubles, half away from zero, rounded once from the exact amount: a
  /// refund of 0,50 is −1 and not −0; a running total is rounded from the exact running
  /// total, never added up from rounded days.
  func testPlottedValuesAreWholeRublesRoundedOnceHalfAwayFromZero() throws {
    let ledger = ledger([
      entry(.expense, "100.5", on: day(1)), entry(.expense, "0.4", on: day(2)),
      entry(.expense, "0.4", on: day(3)), entry(.refund, "0.5", on: day(4)),
    ])
    let days = AnalyticsBuilder.timeSeries(
      TimeSeries(ledger: ledger, period: .month(september), step: .day, today: day(30)),
      period: .month(september))
    XCTAssertEqual(days.buckets.prefix(4).map(\.value), [101, 0, 0, -1])

    let comparison = try XCTUnwrap(
      AnalyticsBuilder.comparison(
        PeriodComparison(ledger: ledger, period: .month(september), today: day(30)),
        period: .month(september)
      ).content)
    XCTAssertEqual(comparison.period, .month(september))
    // 100,5 → 101; 100,9 → 101; 101,3 → 101; 100,8 → 101. Rounded days would give 101,
    // 101, 101, 100.
    XCTAssertEqual(Array(comparison.currentPoints.prefix(4)), [101, 101, 101, 101])

    let node = BreakdownNode(key: .category(food.id), amount: AmountE4(raw: 12_345_000))
    XCTAssertEqual(RankedValue(node).value, 1_235)
    XCTAssertEqual(
      RankedValue(BreakdownNode(key: .uncategorized, amount: AmountE4(raw: -12_345_000))).value,
      -1_235)
  }

  // MARK: - Forecast

  /// 1 000 ₽ a day through the 10th, a remainder of 4 000 / 10 000 / 20 000 and 500 ₽
  /// planned: P50 = 10 000 + 500 + 10 000, P10 = 10 500 + 4 000, P90 = 10 500 + 20 000.
  /// The running total goes day by day to the 10th; from there straight lines reach P50,
  /// P10 and P90 on the 30th, each point rounded from the exact line.
  func testTheForecastRunsFromWhatIsSpentToItsFiguresOnTheLastDay() {
    let today = day(10)
    let ledger = ledger((1...10).map { entry(.expense, "1000", on: day($0)) })
    let remainder = MonthForecast.Remainder(
      p10: AmountE4(whole: 4_000), middle: AmountE4(whole: 10_000),
      p90: AmountE4(whole: 20_000), lowData: false, computedFor: today, daysLeft: 20,
      windowDays: 60)

    let plot = AnalyticsBuilder.forecastPlot(
      ledger: ledger, today: today, planned: AmountE4(whole: 500), remainder: remainder)

    XCTAssertEqual(plot.actual.map(\.day), Array(1...10))
    XCTAssertEqual(plot.actual.map(\.value), (1...10).map { Int64($0) * 1_000 })
    XCTAssertEqual([plot.p10, plot.p50, plot.p90], [14_500, 20_500, 30_500])
    XCTAssertEqual(plot.spent, 10_000)
    XCTAssertEqual(plot.planned, 500)
    XCTAssertEqual(plot.daysLeft, 20)
    XCTAssertEqual(plot.projection.count, 21)
    XCTAssertEqual(plot.projection.first, DayValue(day: 10, value: 10_000))
    XCTAssertEqual(plot.projection[10], DayValue(day: 20, value: 15_250))
    XCTAssertEqual(plot.projection.last, DayValue(day: 30, value: 20_500))
    XCTAssertEqual(plot.band.first, DayBand(day: 10, low: 10_000, high: 10_000))
    XCTAssertEqual(plot.band.last, DayBand(day: 30, low: 14_500, high: 30_500))
    // Half way: 10 000 + 4 500 / 2 and 10 000 + 20 500 / 2.
    XCTAssertEqual(plot.band[10], DayBand(day: 20, low: 12_250, high: 20_250))
    XCTAssertTrue(plot.band.allSatisfy { $0.low <= $0.high })
    XCTAssertTrue(zip(plot.projection, plot.band).allSatisfy { $1.low <= $0.value })
    XCTAssertTrue(zip(plot.projection, plot.band).allSatisfy { $0.value <= $1.high })
  }

  /// On the last day of the month nothing is left: the projection and the band are a point
  /// — what is spent and what is still planned for the day.
  func testOnTheLastDayTheForecastIsAPoint() {
    let today = day(30)
    let ledger = ledger([entry(.expense, "700", on: day(5))])
    let remainder = MonthForecast.Remainder(
      p10: .zero, middle: .zero, p90: .zero, lowData: true, computedFor: today, daysLeft: 0,
      windowDays: 26)

    let plot = AnalyticsBuilder.forecastPlot(
      ledger: ledger, today: today, planned: AmountE4(whole: 300), remainder: remainder)

    XCTAssertEqual(plot.actual.count, 30)
    XCTAssertEqual(plot.actual.last, DayValue(day: 30, value: 700))
    XCTAssertEqual(plot.projection, [DayValue(day: 30, value: 1_000)])
    XCTAssertEqual(plot.band, [DayBand(day: 30, low: 1_000, high: 1_000)])
    XCTAssertTrue(plot.lowData)
  }

  // MARK: - Not enough data

  /// The empty database of a first Release launch: no block of any section draws empty
  /// axes — each says «Мало данных» with its reason; the anomalies and «Качество модели»
  /// have nothing to count.
  func testAnEmptyHistoryHasNotEnoughDataInEveryBlock() throws {
    let empty = ledger([])
    let today = day(18)
    let month = Period.month(september)
    func model(_ section: AnalyticsSection, _ forecast: ForecastInputs? = nil) -> AnalyticsModel {
      AnalyticsBuilder.model(
        request(section, month, today: today, forecast: forecast), ledger: empty)
    }

    let overview = try XCTUnwrap(model(.overview).overview)
    XCTAssertEqual(overview.categories.reason, .noSpending)
    XCTAssertEqual(overview.series.reason, .noSpending)
    XCTAssertEqual(overview.incomeVsExpenses.reason, .noHistory)
    XCTAssertEqual(overview.incomeSources.reason, .noIncome)
    XCTAssertEqual(overview.comparison.reason, .nothingToCompare)
    XCTAssertEqual(overview.weekdays.reason, .noSpending)

    let quality = try XCTUnwrap(model(.quality).quality)
    XCTAssertEqual(quality.shares.reason, .noSpending)
    XCTAssertEqual(quality.badByCategory.reason, .noBadSpending)
    XCTAssertEqual(quality.streaks.reason, .noHistory)
    XCTAssertEqual(quality.goals.reason, .noSpending)

    let others = try XCTUnwrap(model(.others).others)
    XCTAssertEqual(others.totals.reason, .nothingPaidForOthers)
    XCTAssertEqual(others.bySubscription.reason, .noSubscriptionsForOthers)
    XCTAssertEqual(others.byPerson.reason, .nothingPaidForOthers)

    let forWhom = try XCTUnwrap(model(.forWhom).forWhom)
    XCTAssertEqual(forWhom.values.reason, .noSpending)
    XCTAssertEqual(forWhom.people.reason, .noSpending)
    XCTAssertEqual(forWhom.dynamics.reason, .oneMonth)

    let places = try XCTUnwrap(model(.places).places)
    XCTAssertEqual(
      [places.byAmount.reason, places.byPurchases.reason, places.table.reason],
      [.noPlaces, .noPlaces, .noPlaces])
    XCTAssertEqual(places.newPlaces.reason, .noNewPlaces)

    XCTAssertEqual(model(.events).events?.events.reason, .noEvents)
    let methods = try XCTUnwrap(model(.paymentMethods).paymentMethods)
    XCTAssertEqual(methods.spending.reason, .noSpending)
    XCTAssertEqual(methods.table.reason, .noPayments)

    let nothing = MonthForecast.remainder(ledger: empty, today: today)
    let forecast = model(.forecast, ForecastInputs(planned: .zero, remainder: nothing))
    XCTAssertEqual(forecast.forecast?.chart.reason, .noSpendingThisMonth)

    // The anomalies of an empty history: the rules ran and found nothing.
    XCTAssertEqual(model(.anomalies).anomalies?.found.reason, .noAnomalies)
    // «Качество модели» on an empty history: the model has nothing to be right about and
    // there is no past to check a forecast against.
    let measured = try XCTUnwrap(model(.modelQuality).modelQuality)
    XCTAssertEqual(measured.categories.reason, AnalyticsReason.modelNotReady)
    XCTAssertEqual(measured.forecast.reason, AnalyticsReason.noBacktest)
  }

  /// A line needs two points: the 1st of a month has one day to draw; a month has one
  /// month of «for whom»; refunds that outweigh spending leave no bar to draw.
  func testThresholdsOfTheLinesAndBars() throws {
    let ledger = ledger([
      entry(.expense, "300", on: day(1)),
      entry(.expense, "200", on: day(15, of: september.previous)),
    ])
    let first = AnalyticsBuilder.model(
      request(.overview, .month(september), today: day(1)), ledger: ledger)
    XCTAssertEqual(first.overview?.comparison.reason, .oneDay)
    XCTAssertNotNil(first.overview?.categories.content)

    let month = AnalyticsBuilder.model(
      request(.forWhom, .month(september), today: day(18)), ledger: ledger)
    XCTAssertEqual(month.forWhom?.dynamics.reason, .oneMonth)
    let year = AnalyticsBuilder.model(
      request(.forWhom, .year(2026), today: day(18)), ledger: ledger)
    XCTAssertEqual(year.forWhom?.dynamics.content?.months.count, 9)

    let refunded = self.ledger([
      entry(.expense, "100", on: day(2)), entry(.refund, "400", on: day(3)),
    ])
    let negative = AnalyticsBuilder.model(
      request(.overview, .month(september), today: day(18)), ledger: refunded)
    XCTAssertEqual(negative.overview?.categories.reason, .noSpending)
    // The columns still draw: a day of −400 is a figure, not nothing.
    XCTAssertNotNil(negative.overview?.series.content)
  }

  /// «For whom» month by month over the current year stops at the month of today: October
  /// to December have not happened, they are not zeros, and the end of each line is the last
  /// month that has begun. A past year keeps its twelve months; in January the current year
  /// has one month so far.
  func testForWhomLinesStopAtTheMonthOfToday() throws {
    let ledger = ledger([
      entry(.expense, "300", on: day(3)),
      entry(.expense, "200", on: day(15, of: september.previous), forWhom: .partner),
      entry(.expense, "100", on: DateOnly(year: 2025, month: 3, day: 1)),
    ])
    let model = AnalyticsBuilder.model(
      request(.forWhom, .year(2026), today: day(18)), ledger: ledger)
    let dynamics = try XCTUnwrap(model.forWhom?.dynamics.content)
    XCTAssertEqual(dynamics.months.first, MonthKey(year: 2026, month: 1))
    XCTAssertEqual(dynamics.months.last, september)
    XCTAssertTrue(dynamics.series.allSatisfy { $0.points.count == dynamics.months.count })
    XCTAssertEqual(dynamics.series.first { $0.key == .value(.me) }?.points.last, 300)
    XCTAssertEqual(dynamics.series.first { $0.key == .value(.partner) }?.points.last, 0)

    let past = AnalyticsBuilder.model(
      request(.forWhom, .year(2025), today: day(18)), ledger: ledger)
    XCTAssertEqual(past.forWhom?.dynamics.content?.months.count, 12)
    let twelve = AnalyticsBuilder.model(
      request(.forWhom, .twelveMonths(endingWith: september), today: day(18)), ledger: ledger)
    XCTAssertEqual(twelve.forWhom?.dynamics.content?.months.count, 12)

    let january = AnalyticsBuilder.model(
      request(.forWhom, .year(2026), today: DateOnly(year: 2026, month: 1, day: 20)),
      ledger: ledger)
    XCTAssertEqual(january.forWhom?.dynamics.reason, .oneMonthSoFar)
  }

  /// The reason of «Мало данных» is true of what is shown: «Операций пока нет» only for an
  /// empty history; a month of a history that has neither income nor spending says that of
  /// the period, and a period that has not begun says so instead of «one day so far».
  func testTheReasonSpeaksOfThePeriodWhenTheHistoryIsNotEmpty() {
    let ledger = ledger([entry(.expense, "300", on: day(3))])
    let march = AnalyticsBuilder.model(
      request(.overview, .month(MonthKey(year: 2026, month: 3)), today: day(18)), ledger: ledger)
    XCTAssertEqual(march.overview?.incomeVsExpenses.reason, .noIncomeOrSpending)
    let empty = AnalyticsBuilder.model(
      request(.overview, .month(MonthKey(year: 2026, month: 3)), today: day(18)),
      ledger: self.ledger([]))
    XCTAssertEqual(empty.overview?.incomeVsExpenses.reason, .noHistory)
    let october = AnalyticsBuilder.model(
      request(.overview, .month(september.adding(months: 1)), today: day(18)), ledger: ledger)
    XCTAssertEqual(october.overview?.comparison.reason, .notStarted)
  }

  /// «По людям»: spending that names nobody is my own, never a line «Без человека». A period
  /// where nobody is named says so in its own words; a named person's share is still a share of
  /// all my spending.
  func testPeopleListOnlyThePeopleNamed() throws {
    let mine = entry(.expense, "900", on: day(3))
    let none = AnalyticsBuilder.model(
      request(.forWhom, .month(september), today: day(18)), ledger: ledger([mine]))
    XCTAssertEqual(none.forWhom?.people.reason, .noPeople)
    XCTAssertNotNil(none.forWhom?.values.content)

    let anna = Person(name: "Anna", relation: .friend)
    var gift = entry(.expense, "100", on: day(4), forWhom: .friends)
    gift.parts[0].forPersonId = anna.id
    let dataset = Dataset(entries: [mine, gift], categories: [food, salary], people: [anna])
    let named = AnalyticsBuilder.model(
      request(.forWhom, .month(september), today: day(18)),
      ledger: Ledger(dataset: dataset, calendar: .utc))
    let people = try XCTUnwrap(named.forWhom?.people.content)
    XCTAssertEqual(people.map(\.key), [.person(anna.id)])
    XCTAssertEqual(people.first?.share, 1_000)
  }

  // MARK: - Series and stacks

  /// The lines of «for whom»: largest total first, equal totals in the order of the values;
  /// the same input always gives the same lines and styles. With more values than lines,
  /// «others» takes the next free style — never the second line's.
  func testForWhomLinesAreStableAndOthersTakeTheNextStyle() {
    func amounts(_ values: Int64...) -> [AmountE4] { values.map { AmountE4(whole: $0) } }
    let candidates: [(ForWhom, [AmountE4])] = [
      (.me, amounts(100, 100)), (.partner, amounts(300, 0)), (.friends, amounts(50, 150)),
      (.family, amounts(0, 0)), (.other, amounts(10, 5)),
    ]

    let lines = AnalyticsBuilder.dynamicsSeries(candidates)
    XCTAssertEqual(
      lines.map(\.key), [.value(.partner), .value(.me), .value(.friends), .value(.other)])
    XCTAssertEqual(lines.map(\.styleIndex), [0, 1, 2, 3])
    XCTAssertEqual(lines.first?.points, [300, 0])
    XCTAssertEqual(AnalyticsBuilder.dynamicsSeries(candidates), lines)

    let few = AnalyticsBuilder.dynamicsSeries(candidates, limit: 3)
    XCTAssertEqual(few.map(\.key), [.value(.partner), .value(.me), .others])
    XCTAssertEqual(few.last?.points, [60, 155])
    XCTAssertEqual(few.last?.styleIndex, 2)
    XCTAssertNotEqual(
      ChartSeriesStyle.series(2, accent: .system), ChartSeriesStyle.series(1, accent: .system))
  }

  /// Good → neutral → bad from the bottom; a quality without a share has no segment and
  /// leaves no gap.
  func testShareColumnsStackInTheirOrderWithoutGaps() {
    let column = AnalyticsBuilder.shareColumn(
      september,
      [
        BreakdownNode(key: .quality(.good), amount: AmountE4(whole: 250), share: 2_500),
        BreakdownNode(key: .quality(.neutral), amount: AmountE4(whole: -10), share: nil),
        BreakdownNode(key: .quality(.bad), amount: AmountE4(whole: 750), share: 7_500),
      ])
    XCTAssertEqual(column.segments.map(\.quality), [.good, .bad])
    XCTAssertEqual(column.segments.map(\.start), [0, 2_500])
    XCTAssertEqual(column.segments.map(\.end), [2_500, 10_000])
  }

  /// A person's bar: returned → shortfall → written off → waiting, end to end.
  func testAPersonsBarGoesFromReturnedToWaiting() {
    var totals = OthersReport.Totals()
    totals.paid = AmountE4(whole: 1_000)
    totals.returned = AmountE4(whole: 300)
    totals.shortfall = AmountE4(whole: 100)
    totals.writtenOff = .zero
    totals.waiting = AmountE4(whole: 600)
    let stack = AnalyticsBuilder.personStack(personId: nil, totals: totals)
    XCTAssertEqual(stack.segments.map(\.kind), [.returned, .shortfall, .waiting])
    XCTAssertEqual(stack.segments.map(\.start), [0, 300, 400])
    XCTAssertEqual(stack.segments.last?.end, 1_000)
    XCTAssertEqual(stack.paid, 1_000)
  }

  /// «Прогноз» has a second card, the balances at the end of the month: the plan of the data
  /// with the forecast's remainder over it, the total of the summary included; «Мало данных»
  /// while no account was ever counted; and the measurement waits for it too.
  func testTheForecastSectionBuildsTheBalancesBlock() throws {
    let main = PaymentMethod(name: "Main", currency: .rub, isDefault: true)
    let today = day(19)
    let spent = entry(.expense, "3000", on: day(12))
    var entries = [spent]
    entries[0].transaction.paymentMethodId = main.id
    let counted = CalendarContext.utc.startOfDay(day(10))
    let reconciliation = Reconciliation(
      date: day(10), reconciledAt: counted, actualTotalRubE4: .zero, kind: .accounts)
    let count = ReconciledBalance(
      reconciliationId: reconciliation.id, accountId: main.id, currency: .rub,
      actualE4: money("50000"))
    func plan(counts: Bool) -> (Ledger, AccountMonthPlan) {
      let dataset = Dataset(
        entries: entries, categories: [food, salary], paymentMethods: [main],
        planning: counts
          ? PlanningBook(reconciliations: [reconciliation], reconciledBalances: [count])
          : .empty)
      let ledger = Ledger(dataset: dataset, calendar: .utc)
      let planning = PlanningSnapshot.build(
        ledger: ledger, today: today, now: CalendarContext.utc.startOfDay(today),
        rubPerUnit: [:])
      return (ledger, AccountMonthPlan.build(ledger: ledger, planning: planning))
    }
    let remainder = MonthForecast.Remainder(
      p10: money("1000"), middle: money("2000"), p90: money("4000"), lowData: false,
      computedFor: today, daysLeft: 11, windowDays: 90)

    let (ledger, countedPlan) = plan(counts: true)
    let model = AnalyticsBuilder.model(
      request(
        .forecast, .month(september), today: today,
        forecast: ForecastInputs(planned: .zero, remainder: remainder, accounts: countedPlan)),
      ledger: ledger)
    let forecast = try XCTUnwrap(model.forecast?.accounts.content)
    XCTAssertEqual(
      forecast.inSummaryTotalRub,
      AccountForecast.Band(low: money("43000"), middle: money("45000"), high: money("46000")))
    XCTAssertTrue(model.blockIDs.contains(AnalyticsBlock.accountBalances.rawValue))
    XCTAssertEqual(model.blockIDs.count, 2)

    let (bare, uncounted) = plan(counts: false)
    let none = AnalyticsBuilder.model(
      request(
        .forecast, .month(september), today: today,
        forecast: ForecastInputs(planned: .zero, remainder: remainder, accounts: uncounted)),
      ledger: bare)
    XCTAssertEqual(none.forecast?.accounts.reason, .noCountedBalance)
  }

  /// A tenge account counted on a first launch with no rate cached yet: the balances block does
  /// not say no account was counted — it shows the account with «нет курса» and lists the
  /// currency left out.
  @MainActor
  func testACountedAccountWithoutARateIsShownNotCalledUncounted() throws {
    let tenge = CurrencyCode("KZT")
    let kaspi = PaymentMethod(name: "Kaspi", currency: tenge, isDefault: true)
    let today = day(19)
    let reconciliation = Reconciliation(
      date: day(10), reconciledAt: CalendarContext.utc.startOfDay(day(10)),
      actualTotalRubE4: .zero, kind: .accounts)
    let count = ReconciledBalance(
      reconciliationId: reconciliation.id, accountId: kaspi.id, currency: tenge,
      actualE4: money("150000"))
    let dataset = Dataset(
      categories: [food, salary], paymentMethods: [kaspi],
      planning: PlanningBook(reconciliations: [reconciliation], reconciledBalances: [count]))
    let ledger = Ledger(dataset: dataset, calendar: .utc)
    let planning = PlanningSnapshot.build(
      ledger: ledger, today: today, now: CalendarContext.utc.startOfDay(today), rubPerUnit: [:])
    let plan = AccountMonthPlan.build(ledger: ledger, planning: planning)
    let remainder = MonthForecast.Remainder(
      p10: money("1000"), middle: money("2000"), p90: money("4000"), lowData: false,
      computedFor: today, daysLeft: 11, windowDays: 90)

    let model = AnalyticsBuilder.model(
      request(
        .forecast, .month(september), today: today,
        forecast: ForecastInputs(planned: .zero, remainder: remainder, accounts: plan)),
      ledger: ledger)
    let forecast = try XCTUnwrap(
      model.forecast?.accounts.content, "\(String(describing: model.forecast?.accounts.reason))")
    XCTAssertEqual(forecast.sections.flatMap(\.lines).map(\.status), [.noRate(tenge)])
    XCTAssertNil(forecast.inSummaryTotalRub)

    let environment = AppEnvironment()
    let before = environment.language.choice
    environment.language.choice = .russian
    defer { environment.language.choice = before }
    let lines = AccountBalancesForecastText.rows(forecast, environment).compactMap { row in
      if case .line(let line) = row.kind { return line }
      return nil
    }
    XCTAssertEqual(lines.map(\.name), ["Kaspi"])
    XCTAssertEqual(lines.first?.end, "нет курса")
    XCTAssertTrue(
      AccountBalancesForecastText.notes(forecast, environment).contains {
        $0.symbol == "exclamationmark.circle" && $0.text == "Без курса, не учтено: KZT"
      }, "\(AccountBalancesForecastText.notes(forecast, environment))")
  }

  /// Every block of a section is awaited by the measurement; an event adds its own.
  func testTheMeasurementWaitsForEveryChartOfTheSection() {
    let ledger = ledger([entry(.expense, "100", on: day(3))])
    let overview = AnalyticsBuilder.model(
      request(.overview, .month(september), today: day(18)), ledger: ledger)
    XCTAssertEqual(overview.blockIDs.count, 6)
    XCTAssertEqual(Set(overview.blockIDs).count, 6)
    // The sections of 2.1 count what they show themselves and have no chart to wait for; so does
    // «Доход и сбережения» (`IncomeSavingsPage`, from the whole snapshot): their models keep the
    // request only and the measurement has no block of the builder to wait for.
    for section in AnalyticsSection.allCases where !section.isSpending && section != .incomeSavings
    {
      let model = AnalyticsBuilder.model(
        request(section, .month(september), today: day(18)), ledger: ledger)
      XCTAssertFalse(model.blockIDs.isEmpty, "\(section)")
      // No section names a later milestone any more: the last placeholder card, «По подпискам
      // за других», is computed since 21.09.
      XCTAssertNil(section.plannedFor, "\(section)")
    }
    // «За других» draws three cards, and the measurement waits for all three.
    let others = AnalyticsBuilder.model(
      request(.others, .month(september), today: day(18)), ledger: ledger)
    XCTAssertEqual(others.blockIDs.count, 3)
    XCTAssertEqual(Set(others.blockIDs).count, 3)
  }
}

/// The period of the toolbar: steps, kinds, what «Текущий» does, and the text it is kept as.
final class AnalyticsPeriodTests: XCTestCase {
  private let today = DateOnly(year: 2026, month: 9, day: 18)

  func testTheStoredTextComesBackAsTheSamePeriod() {
    for kind in AnalyticsPeriod.Kind.allCases {
      let period = AnalyticsPeriod(kind: kind, month: MonthKey(year: 2025, month: 11))
      XCTAssertEqual(AnalyticsPeriod(storage: period.storage), period)
    }
    XCTAssertEqual(
      AnalyticsPeriod(kind: .twelveMonths, month: MonthKey(year: 2026, month: 9)).storage,
      "twelveMonths:2026-09")
    XCTAssertNil(AnalyticsPeriod(storage: ""))
    XCTAssertNil(AnalyticsPeriod(storage: "week:2026-09"))
    XCTAssertNil(AnalyticsPeriod(storage: "month:September"))
  }

  func testStepsMoveByAMonthAYearOrAMonthOfTwelve() {
    let month = AnalyticsPeriod.current(today: today)
    XCTAssertEqual(month.stepped(by: -1).month, MonthKey(year: 2026, month: 8))
    XCTAssertEqual(month.with(kind: .year).stepped(by: -1).period, .year(2025))
    let twelve = month.with(kind: .twelveMonths)
    XCTAssertEqual(
      twelve.period.range,
      DayRange(DateOnly(year: 2025, month: 10, day: 1), MonthKey(year: 2026, month: 9).lastDay))
    XCTAssertEqual(twelve.stepped(by: -1).month, MonthKey(year: 2026, month: 8))
  }

  /// Nothing lies after the period that holds today; «Текущий» comes back to it.
  func testForwardStopsAtTodayAndCurrentComesBack() {
    let current = AnalyticsPeriod.current(today: today)
    XCTAssertFalse(current.canStepForward(today: today))
    XCTAssertTrue(current.isCurrent(today: today))
    let earlier = current.stepped(by: -3)
    XCTAssertTrue(earlier.canStepForward(today: today))
    XCTAssertFalse(earlier.isCurrent(today: today))
    XCTAssertTrue(earlier.with(kind: .year).isCurrent(today: today))
    XCTAssertEqual(AnalyticsPeriod.current(.year, today: today).period, .year(2026))

    // Twelve months slide by a month, but not past the month of today: the window ending in
    // October would be eleven months that have not come.
    let twelve = current.with(kind: .twelveMonths)
    XCTAssertFalse(twelve.canStepForward(today: today))
    XCTAssertTrue(twelve.stepped(by: -1).canStepForward(today: today))
    XCTAssertFalse(current.with(kind: .year).canStepForward(today: today))
    XCTAssertTrue(
      AnalyticsPeriod(kind: .year, month: MonthKey(year: 2025, month: 12))
        .canStepForward(today: today))
  }

  /// «Прогноз» and «Качество модели» do not depend on the period: the toolbar is inactive on
  /// both, and the window pins their request to the month of today, so stepping the toolbar
  /// elsewhere never measures the model again.
  func testTheForecastAndTheModelQualityDoNotFollowThePeriod() {
    XCTAssertFalse(AnalyticsSection.forecast.followsThePeriod)
    XCTAssertFalse(AnalyticsSection.modelQuality.followsThePeriod)
    XCTAssertFalse(AnalyticsSection.incomeSavings.followsThePeriod)
    let others = AnalyticsSection.allCases.filter {
      $0 != .forecast && $0 != .modelQuality && $0 != .incomeSavings
    }
    XCTAssertTrue(others.allSatisfy(\.followsThePeriod))
  }

  /// A year chosen in the popover, or reached by a step from December, is anchored on the
  /// last month of it that has begun: seen as a month or as twelve months it is never a
  /// month that has not come. A past year is anchored on its December, so its twelve months
  /// are the year itself.
  func testAYearNeverOpensAMonthThatHasNotCome() {
    let september = MonthKey(year: 2026, month: 9)
    let chosen = AnalyticsPeriod.year(2026, today: today)
    XCTAssertEqual(chosen.period, .year(2026))
    XCTAssertEqual(chosen.with(kind: .month).period, .month(september))
    XCTAssertEqual(chosen.with(kind: .twelveMonths).period, .twelveMonths(endingWith: september))

    let past = AnalyticsPeriod.year(2024, today: today)
    XCTAssertEqual(past.with(kind: .twelveMonths).period.range, Period.year(2024).range)

    let december = AnalyticsPeriod(kind: .year, month: MonthKey(year: 2025, month: 12))
    XCTAssertEqual(december.clamped(to: today), december)
    XCTAssertEqual(december.stepped(by: 1).clamped(to: today).month, september)
    XCTAssertEqual(AnalyticsPeriod(storage: "month:2026-12")?.clamped(to: today).month, september)
  }
}

/// The step of «По дням / неделям / месяцам» chosen by hand, across a change of the period.
final class SeriesStepChoiceTests: XCTestCase {
  private func steps(preferring preferred: TimeSeries.Step) -> SeriesSteps {
    let empty = { (step: TimeSeries.Step) in TimeSeriesModel(step: step, buckets: [], average: nil)
    }
    return SeriesSteps(
      day: empty(.day), week: empty(.week), month: empty(.month), preferred: preferred)
  }

  /// «Месяцы» chosen on a year drew one column once the toolbar went to a month: a step is
  /// chosen for periods of its shape — one month, or several — and the other shape opens on
  /// its own preferred step, or on the one chosen for it before.
  func testAStepChosenOnAYearDoesNotFollowToAMonth() {
    let year = steps(preferring: .month)
    let month = steps(preferring: .day)
    var choice = SeriesStepChoice()
    XCTAssertEqual(choice.step(for: month), .day)
    choice.choose(.month, for: year)
    XCTAssertEqual(choice.step(for: year), .month)
    XCTAssertEqual(choice.step(for: month), .day, "a month in one column")
    choice.choose(.week, for: month)
    XCTAssertEqual(choice.step(for: month), .week, "the next month keeps its weeks")
    XCTAssertEqual(choice.step(for: year), .month, "and the year its months")
    choice.choose(.week, for: year)
    XCTAssertEqual(choice.step(for: year), .week)
  }
}

/// How series are told apart without colour: every line has a shape and a pattern of its own,
/// every segment a symbol and words.
@MainActor
final class ChartStyleTests: XCTestCase {
  func testNoTwoSeriesShareAShapeOrAPattern() {
    let styles = ChartSeriesStyle.ordered(accent: .system)
    XCTAssertEqual(styles.count, 5)
    XCTAssertEqual(Set(styles.map(\.symbol)).count, styles.count)
    XCTAssertEqual(Set(styles.map(\.dash)).count, styles.count)
    XCTAssertEqual(styles.map(\.symbol), [.circle, .square, .triangle, .diamond, .pentagon])
    XCTAssertEqual(styles.first?.dash, [])
    XCTAssertEqual(styles.first?.tint, .accent)
    // The accent is the main series' alone.
    XCTAssertEqual(styles.filter { $0.tint == .accent }.count, 1)
    XCTAssertEqual(ChartSeriesStyle.series(0, accent: .system), styles[0])
    XCTAssertEqual(ChartSeriesStyle.series(99, accent: .system), styles[4])

    XCTAssertNotEqual(ChartSeriesStyle.current.symbol, ChartSeriesStyle.previous.symbol)
    XCTAssertNotEqual(ChartSeriesStyle.current.dash, ChartSeriesStyle.previous.dash)
    XCTAssertNotEqual(ChartSeriesStyle.current.dash, ChartSeriesStyle.projection.dash)
    XCTAssertNotEqual(ChartSeriesStyle.current.symbol, ChartSeriesStyle.projection.symbol)
  }

  func testEverySegmentHasASymbolAndWordsOfItsOwn() {
    let environment = AppEnvironment()
    environment.language.choice = .russian
    let qualities = Quality.allCases.map { AnalyticsText.qualityStyle($0, environment) }
    XCTAssertEqual(Set(qualities.map(\.systemImage)).count, 3)
    XCTAssertEqual(qualities.map(\.label), ["Хорошие", "Обычные", "Плохие"])
    let statuses = OthersSegment.allCases.map { AnalyticsText.othersStyle($0, environment) }
    XCTAssertEqual(Set(statuses.map(\.systemImage)).count, 4)
    XCTAssertEqual(statuses.map(\.label), ["Вернули", "Недостача", "Списано", "Ждёт"])
    let income = AnalyticsText.incomeStyle(environment)
    let expenses = AnalyticsText.expensesStyle(environment)
    XCTAssertNotEqual(income.systemImage, expenses.systemImage)
    XCTAssertEqual([income.label, expenses.label], ["Доходы", "Расходы"])
  }

  /// On a person's bar the shortfall and the waiting money stand side by side: their
  /// colours are not two greys, and a segment too narrow for its symbol and figure is named
  /// with them at the end of its bar — a narrow segment reads without colour too.
  func testNarrowSegmentsOfAPersonAreNamedAtTheEndOfTheBar() {
    let environment = AppEnvironment()
    environment.language.choice = .russian
    let statuses = OthersSegment.allCases.map { AnalyticsText.othersStyle($0, environment) }
    let greys: Set<ChartTint> = [.gray, .secondary]
    XCTAssertLessThanOrEqual(statuses.filter { greys.contains($0.tint) }.count, 1)
    XCTAssertEqual(Set(statuses.map(\.tint)).count, statuses.count)

    func segment(_ kind: OthersSegment, _ start: Int64, _ end: Int64) -> ChartSegment {
      ChartSegment(
        id: kind.rawValue, style: AnalyticsText.othersStyle(kind, environment), start: start,
        end: end, text: String(end - start), spokenValue: String(end - start))
    }
    let wide = ChartStack(
      id: "a", axisLabel: "A", spokenLabel: "A", segments: [segment(.waiting, 0, 10_000)])
    let narrow = ChartStack(
      id: "b", axisLabel: "B", spokenLabel: "B",
      segments: [segment(.returned, 0, 3_000), segment(.shortfall, 3_000, 4_000)])
    let lone = ChartStack(
      id: "c", axisLabel: "C", spokenLabel: "C", segments: [segment(.waiting, 0, 1_000)])
    XCTAssertEqual(StackedRowChart.unlabelled(wide, top: 10_000), [])
    XCTAssertEqual(StackedRowChart.unlabelled(narrow, top: 10_000).map(\.id), ["shortfall"])
    XCTAssertEqual(StackedRowChart.unlabelled(lone, top: 10_000).map(\.id), ["waiting"])
  }

  /// 5 % good under 95 % bad: with no neutral between them the order no longer says which
  /// quality the short segment is, so it is named above its column with its symbol and
  /// percent, and the chart makes room for the busiest column.
  func testShortShareSegmentsAreNamedAboveTheirColumn() {
    let environment = AppEnvironment()
    environment.language.choice = .russian
    func segment(_ quality: Quality, _ start: Int64, _ end: Int64) -> ChartSegment {
      ChartSegment(
        id: quality.rawValue, style: AnalyticsText.qualityStyle(quality, environment),
        start: start, end: end, text: "\(end - start)", spokenValue: "\(end - start)")
    }
    func column(_ month: String, _ segments: [ChartSegment]) -> ChartStack {
      ChartStack(id: month, axisLabel: month, spokenLabel: month, segments: segments)
    }
    let tall = column(
      "2026-07",
      [segment(.good, 0, 4_000), segment(.neutral, 4_000, 7_000), segment(.bad, 7_000, 10_000)])
    let goodIsShort = column("2026-08", [segment(.good, 0, 500), segment(.bad, 500, 10_000)])
    let twoShort = column(
      "2026-09",
      [segment(.good, 0, 300), segment(.neutral, 300, 1_299), segment(.bad, 1_299, 10_000)])
    let justTallEnough = column(
      "2026-06", [segment(.good, 0, 1_000), segment(.bad, 1_000, 10_000)])

    XCTAssertEqual(StackedShareChart.unlabelled(tall), [])
    XCTAssertEqual(StackedShareChart.unlabelled(justTallEnough), [])
    XCTAssertEqual(StackedShareChart.unlabelled(goodIsShort).map(\.id), ["good"])
    XCTAssertEqual(StackedShareChart.unlabelled(twoShort).map(\.id), ["good", "neutral"])
    let named = StackedShareChart.unlabelled(twoShort)
    XCTAssertEqual(Set(named.map(\.style.systemImage)).count, named.count)
    XCTAssertTrue(named.allSatisfy { !$0.text.isEmpty })

    XCTAssertEqual(StackedShareChart.namedAbove([tall, justTallEnough]), 0)
    XCTAssertEqual(StackedShareChart.namedAbove([tall, goodIsShort]), 1)
    XCTAssertEqual(StackedShareChart.namedAbove([tall, goodIsShort, twoShort]), 2)
    XCTAssertEqual(StackedShareChart.namedAbove([]), 0)
  }

  func testAnAxisWritesAFewLabelsAndABarSaysItsState() {
    XCTAssertEqual(ChartAxis.thinned(Array(1...5), limit: 8), [1, 2, 3, 4, 5])
    XCTAssertEqual(ChartAxis.thinned(Array(1...31), limit: 8), [1, 5, 9, 13, 17, 21, 25, 29])
    XCTAssertEqual(AnalyticsText.dayTicks(count: 30), [1, 5, 10, 15, 20, 25, 30])
    // The 30th would crowd the 31st: the last day stands alone.
    XCTAssertEqual(AnalyticsText.dayTicks(count: 31), [1, 5, 10, 15, 20, 25, 31])
    XCTAssertEqual(AnalyticsText.dayTicks(count: 1), [1])

    var bar = RankedBar(id: "a", label: "Food", value: 1, caption: "", spokenValue: "")
    XCTAssertEqual(RankedBarChart.axisName(bar), "Food")
    bar.isExpandable = true
    XCTAssertEqual(RankedBarChart.axisName(bar), "▸ Food")
    bar.isExpanded = true
    XCTAssertEqual(RankedBarChart.axisName(bar), "▾ Food")
  }
}

/// The words of the window follow the language of the moment: switching it while the window
/// is open redraws the axes, the months, the weeks and the figures.
@MainActor
final class AnalyticsWordsTests: XCTestCase {
  private var environment: AppEnvironment!

  override func setUp() async throws {
    environment = AppEnvironment()
  }

  private let space = "\u{00A0}"

  func testSwitchingTheLanguageChangesTheAxesAndTheTitles() {
    let period = AnalyticsPeriod(kind: .month, month: MonthKey(year: 2026, month: 9))

    environment.language.choice = .russian
    XCTAssertEqual(AnalyticsText.title(of: period, environment), "Сентябрь 2026")
    XCTAssertEqual(environment.money.axis(1_234_567), "1.2\(space)млн\(space)₽")
    XCTAssertEqual(environment.money.axis(12_400), "12,400\(space)₽")
    XCTAssertEqual(environment.dates.shortWeekday(1), "Пн")
    XCTAssertEqual(environment.dates.shortWeekday(7), "Вс")
    XCTAssertEqual(AnalyticsText.t("analytics.section.quality", environment), "Хорошие и плохие")

    environment.language.choice = .english
    XCTAssertEqual(AnalyticsText.title(of: period, environment), "September 2026")
    XCTAssertEqual(environment.money.axis(1_234_567), "1.2M\(space)₽")
    XCTAssertEqual(environment.money.axis(-2_500_000), "\u{2212}2.5M\(space)₽")
    XCTAssertEqual(environment.money.axis(12_400), "12,400\(space)₽")
    XCTAssertEqual(environment.dates.shortWeekday(1), "Mon")
    XCTAssertEqual(
      AnalyticsText.title(of: period.with(kind: .twelveMonths), environment),
      "Oct 2025 – Sep 2026")
    XCTAssertEqual(AnalyticsText.title(of: period.with(kind: .year), environment), "2026")
  }

  /// A week is named by its days inside the period, in the language of the window.
  func testAWeekIsNamedByItsDays() {
    let bucket = TimeBucket(
      start: DateOnly(year: 2026, month: 9, day: 1), end: DateOnly(year: 2026, month: 9, day: 6),
      value: 100)
    environment.language.choice = .russian
    let russian = AnalyticsText.bucketLabels(bucket, step: .week, spansYears: false, environment)
    XCTAssertTrue(russian.axis.contains("1") && russian.axis.contains("6"), russian.axis)
    XCTAssertTrue(russian.axis.contains("сент"), russian.axis)
    environment.language.choice = .english
    let english = AnalyticsText.bucketLabels(bucket, step: .week, spansYears: false, environment)
    XCTAssertTrue(english.axis.contains("Sep"), english.axis)
    XCTAssertNotEqual(russian.axis, english.axis)

    let month = TimeBucket(
      start: DateOnly(year: 2026, month: 1, day: 1), end: DateOnly(year: 2026, month: 1, day: 31),
      value: 0)
    XCTAssertEqual(
      AnalyticsText.bucketLabels(month, step: .month, spansYears: true, environment).axis,
      "Jan 26")
    XCTAssertEqual(
      AnalyticsText.bucketLabels(month, step: .month, spansYears: false, environment).spoken,
      "January 2026")
  }

  /// A running total over a month is labelled by its days; over a year by the first day of
  /// each month, by name — never 365 numbers.
  func testALongRunningTotalIsLabelledByMonths() {
    environment.language.choice = .english
    let year = DayRange(
      DateOnly(year: 2026, month: 1, day: 1), DateOnly(year: 2026, month: 12, day: 31))
    let ticks = AnalyticsText.spanTicks(year, environment)
    XCTAssertEqual(ticks.count, 12)
    XCTAssertEqual(ticks[1], "Jan")
    XCTAssertEqual(ticks[32], "Feb")
    XCTAssertEqual(ticks[335], "Dec")
    let month = DayRange(
      DateOnly(year: 2026, month: 9, day: 1), DateOnly(year: 2026, month: 9, day: 18))
    XCTAssertEqual(AnalyticsText.spanTicks(month, environment).keys.sorted(), [1, 5, 10, 15, 18])
  }

  /// The day axis of «Расходы по времени»: a month has the 1st, every fifth
  /// and the last day; a year or twelve months the 1st of each month, by its name — not
  /// every 37th day with no month.
  func testTheDayAxisIsLabelledByDaysOfAMonthOrByMonths() {
    environment.language.choice = .english
    let ledger = Ledger(dataset: .empty, calendar: .utc)
    let today = DateOnly(year: 2026, month: 9, day: 18)
    func series(_ period: Period, _ step: TimeSeries.Step) -> TimeSeriesModel {
      AnalyticsBuilder.timeSeries(
        TimeSeries(ledger: ledger, period: period, step: step, today: today), period: period)
    }

    let month = AnalyticsText.columnTicks(
      series(.month(MonthKey(year: 2026, month: 9)), .day), environment)
    XCTAssertEqual(
      month.keys.sorted(),
      [1, 5, 10, 15, 20, 25, 30].map { DateOnly(year: 2026, month: 9, day: $0).iso })
    XCTAssertEqual(month["2026-09-05"], "5")
    XCTAssertEqual(month["2026-09-30"], "30")

    let year = AnalyticsText.columnTicks(series(.year(2026), .day), environment)
    XCTAssertEqual(year.count, 12)
    XCTAssertEqual(year["2026-01-01"], "Jan")
    XCTAssertEqual(year["2026-02-01"], "Feb")
    XCTAssertEqual(year["2026-12-01"], "Dec")

    let twelve = AnalyticsText.columnTicks(
      series(.twelveMonths(endingWith: MonthKey(year: 2026, month: 9)), .day), environment)
    XCTAssertEqual(twelve.count, 12)
    XCTAssertEqual(twelve["2025-10-01"], "Oct 25")
    XCTAssertEqual(twelve["2026-09-01"], "Sep 26")

    // Weeks and months of a year are labelled by months too; a month keeps its weeks.
    let weeks = AnalyticsText.columnTicks(series(.year(2026), .week), environment)
    XCTAssertEqual(weeks.count, 12)
    XCTAssertEqual(weeks["2026-01-01"], "Jan")
    XCTAssertEqual(weeks["2026-02-02"], "Feb")
    let months = AnalyticsText.columnTicks(series(.year(2026), .month), environment)
    XCTAssertEqual(months.count, 12)
    XCTAssertEqual(months["2026-03-01"], "Mar")
    let weeksOfAMonth = AnalyticsText.columnTicks(
      series(.month(MonthKey(year: 2026, month: 9)), .week), environment)
    XCTAssertEqual(weeksOfAMonth.count, 5)
    XCTAssertTrue(weeksOfAMonth["2026-09-01"]?.contains("Sep") == true)
  }

  /// With nothing before, the change under the comparison names the period before as it is
  /// — a month, a year, twelve months — never «last month» for a year.
  func testAChangeWithoutABaseNamesThePeriodBefore() {
    let september = MonthKey(year: 2026, month: 9)
    let noBase = Change(current: AmountE4(whole: 1_000), previous: .zero)
    environment.language.choice = .russian
    func words(_ period: Period, _ change: Change = noBase) -> String {
      AnalyticsText.changeWords(change, period: period, environment)
    }
    XCTAssertTrue(words(.month(september)).hasSuffix("в прошлом месяце данных нет"))
    XCTAssertTrue(words(.year(2026)).hasSuffix("в прошлом году данных нет"))
    XCTAssertTrue(
      words(.twelveMonths(endingWith: september)).hasSuffix(
        "в предыдущие 12 месяцев данных нет"))
    environment.language.choice = .english
    XCTAssertTrue(words(.year(2026)).hasSuffix("no data last year"), words(.year(2026)))
    let withBase = Change(current: AmountE4(whole: 1_500), previous: AmountE4(whole: 1_000))
    XCTAssertTrue(words(.year(2026), withBase).hasSuffix("%"), words(.year(2026), withBase))
  }

  /// The lines of «for whom» are told apart by their value, not by their words: two values
  /// named alike in the Settings stay two lines. Each line ends with its name.
  func testForWhomLinesAreKeyedByTheirValueAndNamedAtTheirEnd() {
    environment.language.choice = .russian
    let model = DynamicsModel(
      months: [MonthKey(year: 2026, month: 8), MonthKey(year: 2026, month: 9)],
      series: [
        DynamicsSeries(key: .value(.partner), styleIndex: 0, points: [100, 200], total: 300),
        DynamicsSeries(key: .others, styleIndex: 1, points: [10, 0], total: 10),
      ])
    let lines = AnalyticsText.dynamicsLines(model, environment)
    XCTAssertEqual(lines.map(\.id), [DynamicsKey.value(.partner).id, DynamicsKey.others.id])
    XCTAssertNotEqual(DynamicsKey.value(.other).id, DynamicsKey.others.id)
    XCTAssertEqual(lines.map(\.endText), lines.map(\.label))
    XCTAssertEqual(lines.last?.label, "Прочие")
    XCTAssertEqual(lines.first?.points.last?.valueText, "200\(space)₽")
  }

  /// Every reason of «Мало данных» has its words in both languages.
  func testEveryReasonHasItsWords() {
    for choice in [AppLanguage.Choice.russian, .english] {
      environment.language.choice = choice
      for reason in AnalyticsReason.allCases {
        let words = AnalyticsText.t(reason.key, environment)
        XCTAssertFalse(words.isEmpty || words == reason.key, "\(choice) \(reason)")
      }
    }
  }

  /// The header of a section: an incomplete period says through which day and what it is
  /// compared with; a completed one only what it is compared with.
  func testTheHeaderSaysHowFarThePeriodGoesAndWhatItIsComparedWith() {
    environment.language.choice = .russian
    let today = DateOnly(year: 2026, month: 9, day: 18)
    let current = AnalyticsHeader(period: .month(MonthKey(year: 2026, month: 9)), today: today)
    let line = AnalyticsText.header(current, title: "Сентябрь 2026", environment)
    XCTAssertTrue(line.hasPrefix("Сентябрь 2026 · неполный, по 18 сентября · сравнение с "), line)
    let done = AnalyticsHeader(period: .month(MonthKey(year: 2026, month: 8)), today: today)
    let doneLine = AnalyticsText.header(done, title: "Август 2026", environment)
    XCTAssertFalse(doneLine.contains("неполный"), doneLine)
    XCTAssertTrue(doneLine.contains("сравнение с"), doneLine)
    let future = AnalyticsHeader(period: .month(MonthKey(year: 2026, month: 10)), today: today)
    XCTAssertEqual(AnalyticsText.header(future, title: "Октябрь 2026", environment), "Октябрь 2026")
  }

  /// «Качество модели» measures the whole history up to today: its line names no period of
  /// the toolbar, nothing incomplete and nothing it is compared with.
  func testTheModelQualityHeaderSaysTheWholeHistory() {
    let today = DateOnly(year: 2026, month: 9, day: 18)
    let request = AnalyticsRequest(
      section: .modelQuality, period: .year(2025), today: today)
    let model = AnalyticsBuilder.model(request, ledger: Ledger(dataset: .empty, calendar: .utc))

    environment.language.choice = .russian
    let line = AnalyticsText.sectionHeader(
      .modelQuality, title: "2025", model: model, environment)
    XCTAssertEqual(line, "Вся история · по 18 сентября")
    environment.language.choice = .english
    XCTAssertEqual(
      AnalyticsText.sectionHeader(.modelQuality, title: "2025", model: model, environment),
      "Whole history · through September 18")
  }

  /// Numbers in the words take the plural of the language.
  func testCountsTakeTheirPluralForms() {
    environment.language.choice = .russian
    XCTAssertEqual(AnalyticsText.format("analytics.purchases", environment, 1), "1 покупка")
    XCTAssertEqual(AnalyticsText.format("analytics.purchases", environment, 3), "3 покупки")
    XCTAssertEqual(AnalyticsText.format("analytics.purchases", environment, 5), "5 покупок")
    XCTAssertEqual(
      AnalyticsText.format("analytics.streak.best", environment, 21), "лучшая — 21 день")
    XCTAssertEqual(
      AnalyticsText.format("analytics.places.more", environment, 12), "и ещё 12 мест")
    environment.language.choice = .english
    XCTAssertEqual(AnalyticsText.format("analytics.purchases", environment, 1), "1 purchase")
    XCTAssertEqual(
      AnalyticsText.format("analytics.streak.current", environment, 2), "current — 2 days")
  }

  /// A line of a bar chart: an archived name is marked; the lines without a name have words.
  func testNamesOfTheLines() {
    environment.language.choice = .english
    let old = CoreKit.Category(kind: .expense, name: "Hobby", archived: true)
    let names = AnalyticsNames(dataset: Dataset(categories: [old]))
    XCTAssertEqual(
      AnalyticsText.name(of: .category(old.id), names, environment), "Hobby (archived)")
    XCTAssertEqual(AnalyticsText.name(of: .uncategorized, names, environment), "Uncategorized")
    XCTAssertEqual(
      AnalyticsText.name(of: .noSubcategory, names, environment), "(no subcategory)")
    XCTAssertEqual(AnalyticsText.name(of: .noPaymentMethod, names, environment), "Not specified")

    let bars = AnalyticsText.bars(
      [
        RankedValue(
          key: .category(old.id), value: 900, share: 9_000,
          children: [RankedValue(key: .noSubcategory, value: 900, share: 9_000)]),
        RankedValue(key: .uncategorized, value: -50),
      ], names: names, expanded: [.category(old.id)], environment)
    XCTAssertEqual(bars.map(\.isChild), [false, true, false])
    XCTAssertTrue(bars[0].isExpandable && bars[0].isExpanded)
    XCTAssertEqual(bars[0].caption, "900\(space)₽ · 90%")
    XCTAssertEqual(bars[2].caption, "\u{2212}50\(space)₽")
    XCTAssertEqual(Set(bars.map(\.id)).count, 3)
  }
}

/// The measurement of `--measure`: from a change to the first `task` of every chart of the
/// model that came for it, on a clock the test moves by hand.
@MainActor
final class AnalyticsMeasurementTests: XCTestCase {
  private var instant = ContinuousClock.now

  private func measurement(enabled: Bool = true) -> AnalyticsMeasurement {
    AnalyticsMeasurement(isEnabled: enabled) { [unowned self] in self.instant }
  }

  func testItEndsWhenEveryChartOfTheModelHasAppeared() {
    let measurement = measurement()
    measurement.begin("overview month")
    instant += .milliseconds(120)
    measurement.modelArrived(serial: 7, blocks: ["a", "b"])
    measurement.blockAppeared("a", serial: 7)
    XCTAssertTrue(measurement.isWaiting)
    // A chart of an older model is not the one awaited.
    instant += .milliseconds(30)
    measurement.blockAppeared("b", serial: 6)
    XCTAssertTrue(measurement.isWaiting)
    instant += .milliseconds(50)
    measurement.blockAppeared("b", serial: 7)
    XCTAssertFalse(measurement.isWaiting)
    XCTAssertEqual(measurement.last?.label, "overview month")
    XCTAssertEqual(measurement.last?.milliseconds, 200)
  }

  /// A model that arrives while nothing is measured — a light refresh — is not a measurement,
  /// and a new change restarts the clock.
  func testOnlyAChangeStartsTheClock() {
    let measurement = measurement()
    measurement.modelArrived(serial: 1, blocks: ["a"])
    measurement.blockAppeared("a", serial: 1)
    XCTAssertNil(measurement.last)

    measurement.begin("places year")
    instant += .milliseconds(500)
    measurement.begin("places month")
    instant += .milliseconds(40)
    measurement.modelArrived(serial: 2, blocks: [])
    XCTAssertEqual(measurement.last?.milliseconds, 40)
    XCTAssertEqual(measurement.last?.label, "places month")
    // A second model for the same change does not measure again.
    measurement.modelArrived(serial: 3, blocks: ["a"])
    XCTAssertFalse(measurement.isWaiting)
  }

  /// Another stored text of the same section and period is not a change: nothing new is
  /// computed, so the clock does not start to wait for a model that never comes.
  func testTheSameSectionAndPeriodDoNotStartTheClockAgain() {
    let measurement = measurement()
    let year = AnalyticsRequest.Subject(section: .forWhom, period: .year(2026))
    measurement.begin("forWhom year", for: year)
    measurement.modelArrived(serial: 1, blocks: [])
    XCTAssertNotNil(measurement.last)
    measurement.begin("forWhom year", for: year)
    XCTAssertFalse(measurement.isWaiting)
    measurement.begin(
      "forWhom month",
      for: AnalyticsRequest.Subject(
        section: .forWhom, period: .month(MonthKey(year: 2026, month: 9))))
    XCTAssertTrue(measurement.isWaiting)
    // Back to the year is a change again.
    measurement.modelArrived(serial: 2, blocks: [])
    measurement.begin("forWhom year", for: year)
    XCTAssertTrue(measurement.isWaiting)
  }

  func testWithoutTheArgumentNothingIsMeasured() {
    let measurement = measurement(enabled: false)
    measurement.begin("overview month")
    measurement.modelArrived(serial: 1, blocks: [])
    XCTAssertFalse(measurement.isWaiting)
    XCTAssertNil(measurement.last)
  }
}

/// Which model the cards show, and the models kept for the way back.
@MainActor
final class AnalyticsStoreTests: XCTestCase {
  private let today = DateOnly(year: 2026, month: 9, day: 18)
  private let at = Date(timeIntervalSince1970: 0)

  private func request(
    _ period: Period, _ section: AnalyticsSection = .overview
  )
    -> AnalyticsRequest
  {
    AnalyticsRequest(section: section, period: period, today: today, forecast: nil)
  }

  private func model(_ request: AnalyticsRequest) -> AnalyticsModel {
    AnalyticsBuilder.model(request, ledger: Ledger(dataset: .empty, calendar: .utc))
  }

  func testTheCardsShowTheStateOfTheDataFirst() {
    let september = request(.month(MonthKey(year: 2026, month: 9)))
    let shown = model(september)
    let ready = BlockState<Int>.ready(1, at: at)
    XCTAssertEqual(
      AnalyticsStore.state(
        for: september, data: BlockState<Int>.calculating, forecast: nil, model: shown, at: at
      ).phase, .calculating)
    XCTAssertEqual(
      AnalyticsStore.state(
        for: september, data: BlockState<Int>.failed(messageKey: "compute.failed.data"),
        forecast: nil, model: shown, at: at
      ).phase, .failed)
    XCTAssertEqual(
      AnalyticsStore.state(for: september, data: ready, forecast: nil, model: shown, at: at)
        .phase, .ready)
    XCTAssertEqual(
      AnalyticsStore.state(
        for: september, data: ready, forecast: .failed(messageKey: "compute.failed.forecast"),
        model: shown, at: at
      ).phase, .failed)
  }

  /// Another period or section never shows this one's model; the same request keeps it
  /// while a newer one is computed.
  func testAModelIsShownOnlyForWhatItWasComputedFor() {
    let september = request(.month(MonthKey(year: 2026, month: 9)))
    let august = request(.month(MonthKey(year: 2026, month: 8)))
    let places = request(.month(MonthKey(year: 2026, month: 9)), .places)
    let ready = BlockState<Int>.ready(1, at: at)
    let shown = model(september)
    XCTAssertEqual(
      AnalyticsStore.state(for: august, data: ready, forecast: nil, model: shown, at: at).phase,
      .calculating)
    XCTAssertEqual(
      AnalyticsStore.state(for: places, data: ready, forecast: nil, model: shown, at: at).phase,
      .calculating)
    XCTAssertEqual(
      AnalyticsStore.state(for: september, data: ready, forecast: nil, model: nil, at: nil).phase,
      .calculating)
  }

  /// Going back is instant within a generation of the data; a new generation drops the
  /// older models, and beyond the capacity the one used longest ago goes.
  func testTheCacheKeepsTheNewestGenerationOnly() {
    var cache = ModelCache<Int>()
    cache.capacity = 2
    let september = request(.month(MonthKey(year: 2026, month: 9)))
    let august = request(.month(MonthKey(year: 2026, month: 8)))
    let july = request(.month(MonthKey(year: 2026, month: 7)))
    cache.store(1, for: .init(request: september, generation: 4))
    cache.store(2, for: .init(request: august, generation: 4))
    XCTAssertEqual(cache.model(for: .init(request: september, generation: 4)), 1)
    XCTAssertNil(cache.model(for: .init(request: september, generation: 5)))
    cache.store(3, for: .init(request: july, generation: 4))
    XCTAssertNil(cache.model(for: .init(request: august, generation: 4)))
    XCTAssertEqual(cache.count, 2)
    cache.store(4, for: .init(request: july, generation: 5))
    XCTAssertEqual(cache.count, 1)
    XCTAssertNil(cache.model(for: .init(request: september, generation: 4)))
  }

  /// With `--measure` the cache is bypassed: every change is a first build.
  func testMeasuringBypassesTheCache() {
    XCTAssertTrue(AnalyticsStore(measurement: AnalyticsMeasurement(isEnabled: true)).bypassesCache)
    XCTAssertFalse(
      AnalyticsStore(measurement: AnalyticsMeasurement(isEnabled: false)).bypassesCache)
  }
}

/// One source for three windows, on the hand-computed golden set of the core,
/// in whole rubles. Spending: the month bucket Analytics draws is Overview's month to
/// date on the last day of the month and the month's row of the Reports year. Income: the
/// month of Analytics is the Reports row and Overview's rule — income for the month, dated
/// by the cut-off — with the cut-off of the plan, the last day of the data; Overview on the
/// last day of the month itself has not yet seen income for the month that arrives after
/// it, so there the two differ by exactly that income.
final class AnalyticsConsistencyTests: XCTestCase {
  func testTheAnalyticsMonthIsOverviewsMonthToDateAndTheReportsRow() throws {
    let url = try XCTUnwrap(
      Bundle(for: Self.self).url(forResource: "golden-small", withExtension: "json"),
      "golden-small.json is missing from the test bundle")
    let golden = try Golden.decode(Data(contentsOf: url))
    let dataset = golden.dataset()
    let ledger = Ledger(dataset: dataset, calendar: .utc)
    let today = golden.todayDay
    let year = AnalyticsBuilder.model(
      AnalyticsRequest(section: .overview, period: .year(2026), today: today, forecast: nil),
      ledger: ledger)
    let steps = try XCTUnwrap(year.overview?.series.content)
    let pairs = try XCTUnwrap(year.overview?.incomeVsExpenses.content)
    let report = ReportBuilder(ledger: ledger, today: today).table(.monthly, period: .year(2026))
    let lastDayOfData = try XCTUnwrap(ledger.rows.last?.day)

    for number in [7, 8] {
      let month = MonthKey(year: 2026, month: number)
      // Overview as the app builds it, on the last day of the month.
      let overview = DataSnapshot.build(
        dataset: dataset, calendar: .utc, today: month.lastDay, context: SnapshotContext(),
        version: DataVersion(load: 0)
      ).summary
      let row = try XCTUnwrap(report.rows.first { $0.key == .month(month) })
      let bucket = try XCTUnwrap(steps.month.buckets.first { $0.start == month.firstDay })
      let pair = try XCTUnwrap(pairs.first { $0.month == month })

      let expenses = overview.expenses.current.wholeRubles
      XCTAssertNotEqual(expenses, 0, "month \(number) has spending in the golden set")
      XCTAssertEqual(bucket.value, expenses, "month \(number)")
      XCTAssertEqual(pair.expenses, expenses, "month \(number)")
      XCTAssertEqual(row.values[0]?.wholeRubles, expenses, "month \(number)")

      let income = ledger.income(attributedTo: [month], notAfter: lastDayOfData).wholeRubles
      XCTAssertEqual(pair.income, income, "month \(number)")
      XCTAssertEqual(row.values[1]?.wholeRubles, income, "month \(number)")
      // Overview on the last day of the month: the cashback of 150 dated 1 August for July
      // (operation 123 of the golden set) has not arrived yet; August has no such income.
      let arrivedLater: Int64 = number == 7 ? 150 : 0
      XCTAssertEqual(
        overview.income.current.wholeRubles, income - arrivedLater, "month \(number)")
    }
    // Only the month's own words differ between the windows: the golden answers hold.
    XCTAssertEqual(
      steps.month.buckets.first { $0.start == MonthKey(year: 2026, month: 7).firstDay }?.value,
      money(try XCTUnwrap(golden.expected["julyExpenses"]?.amount)).wholeRubles)
  }
}

/// Every section drawn off screen from the golden set, as the window draws it: Swift Charts
/// takes every mark and scale (a mark of the wrong type on an axis stops the app), and the
/// hook of `--measure` sees the first `task` of every chart of the section — the path
/// `make bench-app` times.
@MainActor
final class AnalyticsRenderingTests: XCTestCase {
  func testEverySectionDrawsAndReportsEveryChart() throws {
    // Swift Charts once wrote «Custom UnitPoint values are not supported in AxisValueLabel's
    // anchor property» while drawing off screen (18.09). No axis of ours sets an anchor, and
    // 353 tests in a row never heard it again — so the check stays as a guard rather than as
    // evidence of anything.
    let probe = LogProbe()
    let quiet = [LogProbe.Message.customUnitPoint]
    let before = probe.counts(of: quiet)
    let url = try XCTUnwrap(
      Bundle(for: Self.self).url(forResource: "golden-small", withExtension: "json"))
    let golden = try Golden.decode(Data(contentsOf: url))
    let ledger = golden.ledger()
    let today = golden.todayDay
    let environment = AppEnvironment()
    environment.language.choice = .russian
    let inputs = ForecastInputs(
      planned: PlannedPayments(ledger: ledger, today: today, rubPerUnit: golden.rubPerUnit).total,
      remainder: MonthForecast.remainder(ledger: ledger, today: today))

    for section in AnalyticsSection.allCases {
      for period in [Period.year(2026), .month(today.monthKey)] {
        let store = AnalyticsStore(measurement: AnalyticsMeasurement(isEnabled: true))
        let request = AnalyticsRequest(
          section: section, period: section.followsThePeriod ? period : .month(today.monthKey),
          today: today, forecast: section == .forecast ? inputs : nil)
        let model = AnalyticsBuilder.model(request, ledger: ledger)
        store.measurement.begin("\(section.rawValue)")
        store.deliver(model)

        let host = NSHostingView(
          rootView: AnalyticsSectionView(
            section: section, title: section.rawValue, state: .ready(model, at: Date()),
            retry: {}
          )
          .appDependencies(.forTests(environment))
          .environment(store)
          .frame(width: 1_100, height: 760))
        let window = NSWindow(
          contentRect: NSRect(x: 0, y: 0, width: 1_100, height: 760), styleMask: [.titled],
          backing: .buffered, defer: false)
        window.contentView = host
        let deadline = Date().addingTimeInterval(5)
        repeat {
          host.layoutSubtreeIfNeeded()
          host.display()
          RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        } while store.measurement.isWaiting && Date() < deadline
        window.contentView = nil

        if model.blockIDs.isEmpty {
          XCTAssertNotNil(store.measurement.last, "\(section)")
        } else {
          XCTAssertFalse(
            store.measurement.isWaiting, "\(section) \(period): a chart never appeared")
          XCTAssertNotNil(store.measurement.last, "\(section) \(period)")
        }
      }
    }
    probe.assertQuiet(about: quiet, comparedWith: before, "drawing every section")
  }
}

/// «Оборот и кэшбэк» with the cards' rules, and «Кэшбэк по месяцам»: the expected cashback
/// beside the received, a line per card under an account with several, and each month's
/// difference received − expected worked out exactly and rounded once. Both accounts round the
/// cashback of a purchase to the kopeck, so the sums below are the exact ones.
final class AnalyticsCashbackTests: XCTestCase {
  private let calendar = CalendarContext.utc
  private let september = MonthKey(year: 2026, month: 9)
  private let kopecks = CashbackRounding(precision: .cents)
  private lazy var tBank = PaymentMethod(
    name: "Т-Банк", kind: .card, currency: .rub, cashbackRounding: kopecks)
  private lazy var sber = PaymentMethod(
    name: "Сбер", kind: .card, currency: .rub, isDefault: true, cashbackRounding: kopecks)
  private let cafes = CoreKit.Category(kind: .expense, name: "Кафе")
  private let cashback = CoreKit.Category(kind: .income, name: "Кэшбэк")
  private lazy var black = PaymentCard(accountId: tBank.id, name: "Black")
  private lazy var virtual = PaymentCard(accountId: tBank.id, name: "Virtual", sort: 1)

  private func operation(
    _ kind: TransactionKind, _ amount: String, card: UUID?, account: UUID? = nil, day: Int = 12,
    period: MonthKey? = nil
  ) -> TransactionEntry {
    let at = calendar.noon(of: DateOnly(year: 2026, month: 9, day: day))
    let transaction = Transaction(
      kind: kind, occurredAt: at, amountE4: money(amount), paymentMethodId: account ?? tBank.id,
      periodMonth: period, createdAt: at, updatedAt: at, cardId: card)
    return TransactionEntry(
      transaction: transaction,
      parts: [
        TransactionPart(
          transactionId: transaction.id, categoryId: kind == .income ? cashback.id : cafes.id,
          quality: kind == .income ? nil : .neutral,
          qualitySource: kind == .income ? nil : .category, amountE4: money(amount))
      ])
  }

  /// Black: 10 % on 350 → 35.00 and 1 % on 1,234.56 → 12.35; Virtual: 7 % on 1,000 → 70.00;
  /// Сбер: 0.5 % on 60 → 0.30. Received: 25 on Black, by September.
  private var ledger: Ledger {
    let rules = [
      CashbackRule(
        accountId: tBank.id, cardId: black.id, categoryId: cafes.id, month: september,
        percent: CashbackPercent(e4: 100_000)!),
      CashbackRule(accountId: tBank.id, cardId: black.id, percent: CashbackPercent(e4: 10_000)!),
      CashbackRule(
        accountId: tBank.id, cardId: virtual.id, percent: CashbackPercent(e4: 70_000)!),
      CashbackRule(accountId: sber.id, percent: CashbackPercent(e4: 5_000)!),
    ]
    let tea = CoreKit.Category(kind: .expense, name: "Аптека")
    var pharmacy = operation(.expense, "1234.56", card: black.id, day: 14)
    pharmacy.parts[0].categoryId = tea.id
    return Ledger(
      dataset: Dataset(
        entries: [
          operation(.expense, "350", card: black.id),
          pharmacy,
          operation(.expense, "1000", card: virtual.id, day: 15),
          operation(.expense, "60", card: nil, account: sber.id, day: 16),
          operation(.income, "25", card: black.id, day: 20, period: september),
        ],
        categories: [cafes, cashback, tea], paymentMethods: [sber, tBank],
        settings: AnalyticsSettings(cashbackCategoryId: cashback.id), cards: [black, virtual],
        cashbackRules: rules),
      calendar: calendar)
  }

  func testTheMethodsTableHasExpectedAndReceived() throws {
    let model = AnalyticsBuilder.paymentMethods(ledger: ledger, period: .month(september))
    let rows = try XCTUnwrap(model.table.content)
    let tRow = try XCTUnwrap(rows.first { $0.key == .paymentMethod(tBank.id) })
    XCTAssertEqual(tRow.expectedCashback, 117, "35.00 + 12.35 + 70.00 = 117.35")
    XCTAssertEqual(tRow.cashback, 25)
    XCTAssertEqual(tRow.cards.map(\.cardId), [black.id, virtual.id])
    XCTAssertEqual(tRow.cards.map(\.expected), [47, 70])
    XCTAssertEqual(tRow.cards.map(\.received), [25, 0])
    let sRow = try XCTUnwrap(rows.first { $0.key == .paymentMethod(sber.id) })
    XCTAssertEqual(sRow.expectedCashback, 0, "0.30 is under a ruble")
    XCTAssertTrue(sRow.cards.isEmpty, "one line: no card rows under it")
  }

  /// September of «Т-Банк»: expected 117.35, received 25 → −92.35, shown −92; every account:
  /// 117.65 expected → −92.65, shown −93. Black alone: 47.35 against 25 → −22.35, −22.
  func testCashbackMonthsDifferenceIsReceivedMinusExpected() throws {
    let model = AnalyticsBuilder.paymentMethods(ledger: ledger, period: .month(september))
    let months = try XCTUnwrap(model.cashbackMonths.content)
    XCTAssertEqual(months.choices.first, .all)
    XCTAssertTrue(months.choices.contains(.account(tBank.id)))
    XCTAssertTrue(months.choices.contains(.card(black.id)))
    XCTAssertEqual(months.cardAccounts[black.id], tBank.id)
    let tMonth = try XCTUnwrap(months.months[.account(tBank.id)]?.first)
    XCTAssertEqual(tMonth.month, september)
    XCTAssertEqual([tMonth.expected, tMonth.received, tMonth.difference], [117, 25, -92])
    let all = try XCTUnwrap(months.months[.all]?.first)
    XCTAssertEqual([all.expected, all.received, all.difference], [118, 25, -93])
    let card = try XCTUnwrap(months.months[.card(black.id)]?.first)
    XCTAssertEqual([card.expected, card.received, card.difference], [47, 25, -22])
  }

  /// VoiceOver hears a line of either table once, from its first cell: the month or the name,
  /// then every figure after the header of its column — which one is expected, which received
  /// and which the difference. A share never worked out is not said.
  @MainActor
  func testCashbackLinesAreSpokenWithTheirHeaders() throws {
    let environment = AppEnvironment()
    environment.language.choice = .russian
    let money = environment.money
    let model = AnalyticsBuilder.paymentMethods(ledger: ledger, period: .month(september))
    let all = try XCTUnwrap(model.cashbackMonths.content?.months[.all]?.first)
    let month = AnalyticsText.cashbackMonthLine(all, environment)
    XCTAssertEqual(month.first, environment.dates.monthTitle(september))
    XCTAssertEqual(month.figures, [money.rubles(118), money.rubles(25), money.signedRubles(-93)])
    XCTAssertEqual(
      month.spoken,
      "\(month.first), ожидаемый кэшбэк \(money.rubles(118)), полученный кэшбэк "
        + "\(money.rubles(25)), разница \(money.signedRubles(-93))")

    let names = AnalyticsNames(dataset: ledger.dataset)
    let rows = try XCTUnwrap(model.table.content)
    let tRow = try XCTUnwrap(rows.first { $0.key == .paymentMethod(tBank.id) })
    let account = AnalyticsText.methodLine(tRow, names, environment)
    XCTAssertEqual(account.first, "Т-Банк")
    XCTAssertEqual(account.figures.count, 5)
    XCTAssertEqual(account.figures[2], "≈\u{00A0}" + money.rubles(117))
    XCTAssertTrue(account.spoken.hasPrefix("Т-Банк, мои траты "), account.spoken)
    XCTAssertTrue(
      account.spoken.contains(
        ", ожидаемый кэшбэк ≈\u{00A0}\(money.rubles(117)), полученный кэшбэк \(money.rubles(25)), "
          + "фактическая доля "), account.spoken)

    let black = AnalyticsText.cardMethodLine(tRow.cards[0], names, environment)
    XCTAssertEqual(black.first, "Black")
    XCTAssertEqual(black.figures.count, 4, "a card has no share of its own")
    XCTAssertTrue(black.spoken.hasPrefix("Black, мои траты "), black.spoken)
    XCTAssertTrue(
      black.spoken.hasSuffix(
        ", ожидаемый кэшбэк ≈\u{00A0}\(money.rubles(47)), полученный кэшбэк \(money.rubles(25))"),
      black.spoken)

    var noShare = tRow
    noShare.cashbackShare = nil
    XCTAssertFalse(
      AnalyticsText.methodLine(noShare, names, environment).spoken.contains("доля"),
      "a share never worked out is said as a dash")
  }

  /// No rules and no cashback received: «Мало данных», saying where rules are set.
  func testCashbackMonthsWithoutRulesSaySo() {
    let bare = Ledger(
      dataset: Dataset(
        entries: [operation(.expense, "350", card: nil)], categories: [cafes, cashback],
        paymentMethods: [tBank]),
      calendar: calendar)
    let model = AnalyticsBuilder.paymentMethods(ledger: bare, period: .month(september))
    XCTAssertEqual(model.cashbackMonths.reason, .noCashbackRules)
  }
}
