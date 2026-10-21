import CoreAccounting
import CoreCSV
import CoreKit
import Foundation
import Testing

@testable import CoreAnalytics

/// Every slice of the core against the answers worked out by hand in
/// `Fixtures/golden-small.json`. The same file is meant to check the future Windows port.
@Suite("Golden set: every slice against the hand-computed answers")
struct GoldenTests {
  let golden: Golden
  let ledger: Ledger
  let today: DateOnly

  let july = Period.month(MonthKey(year: 2026, month: 7))
  let august = Period.month(MonthKey(year: 2026, month: 8))

  init() throws {
    golden = try Golden.load()
    ledger = golden.ledger()
    today = golden.todayDay
  }

  // MARK: - Reading answers

  func amount(_ name: String) throws -> AmountE4 {
    money(try #require(golden.answer(name).amount, "\(name) has no amount"))
  }

  func amounts(_ name: String) throws -> [AmountE4] {
    try #require(golden.answer(name).amounts, "\(name) has no amounts").map(money)
  }

  func nodes(_ name: String) throws -> [Golden.Node] {
    try #require(golden.answer(name).nodes, "\(name) has no nodes")
  }

  func items(_ name: String) throws -> [[String]] {
    try #require(golden.answer(name).items, "\(name) has no items")
  }

  func int(_ name: String) throws -> Int {
    try #require(golden.answer(name).int, "\(name) has no int")
  }

  // MARK: - Totals and Overview

  @Test func monthTotals() throws {
    #expect(ledger.expenses(in: july.range) == (try amount("julyExpenses")))
    #expect(ledger.expenses(in: august.range) == (try amount("augustExpenses")))
    #expect(ledger.income(in: july) == (try amount("julyIncome")))
    #expect(ledger.income(in: august) == (try amount("augustIncome")))
  }

  @Test func overview() throws {
    let summary = OverviewSummary(ledger: ledger, today: today)
    #expect(summary.expenses.current == (try amount("overview.expenses.current")))
    #expect(summary.expenses.previous == (try amount("overview.expenses.previous")))
    #expect(summary.expenses.basisPoints == (try int("overview.expenses.basisPoints")))
    #expect(summary.income.current == (try amount("overview.income.current")))
    #expect(summary.income.previous == (try amount("overview.income.previous")))
    #expect(summary.income.basisPoints == (try int("overview.income.basisPoints")))
    #expect(summary.net == (try amount("overview.net")))
    #expect(summary.topCategories.map(Golden.Node.init) == (try nodes("overview.topCategories")))
    #expect(summary.qualities.map(Golden.Node.init) == (try nodes("overview.qualities")))
    #expect(summary.bad.current == (try amount("overview.bad.current")))
    #expect(summary.bad.previous == (try amount("overview.bad.previous")))
    #expect(summary.bad.basisPoints == (try int("overview.bad.basisPoints")))
    #expect(summary.owedToMe == (try amount("overview.owed")))
    #expect(summary.owedCount == (try int("overview.owedCount")))
    #expect(summary.span == DayRange(day("2026-08-01"), day("2026-08-20")))
    #expect(summary.previousSpan == DayRange(day("2026-07-01"), day("2026-07-20")))
  }

  /// The day header, the bar under a selection and the delete dialog all come from here.
  @Test(arguments: [
    "2026-07-04", "2026-07-05", "2026-07-19", "2026-07-20", "2026-08-09", "2026-08-12",
    "2026-08-14",
  ])
  func rowTotalsOfADay(_ iso: String) throws {
    let ids = Set(ledger.rows(in: DayRange(day(iso), day(iso))).map(\.transactionId))
    let totals = ledger.rowTotals(of: ids)
    #expect(
      [totals.myExpenses, totals.income, totals.forOthers, totals.moneyReturned]
        == (try amounts("rowTotals.\(iso)")))
  }

  // MARK: - Breakdowns and reports

  @Test func categoryBreakdowns() throws {
    let expenses = CategoryBreakdown(ledger: ledger, period: july, kind: .expense)
    #expect(expenses.nodes.map(Golden.Node.init) == (try nodes("breakdown.july.expenses")))
    #expect(expenses.total == (try amount("julyExpenses")))
    let income = CategoryBreakdown(ledger: ledger, period: july, kind: .income)
    #expect(income.nodes.map(Golden.Node.init) == (try nodes("breakdown.july.income")))
    #expect(income.total == (try amount("julyIncome")))
    #expect(IncomeSources(ledger: ledger, period: july).total == (try amount("julyIncome")))
  }

  @Test func reportTablesAndGroupings() throws {
    let builder = ReportBuilder(ledger: ledger, today: today)
    let twoLevel = builder.table(.expensesByCategoryAndSubcategory, period: july)
    #expect(
      String(decoding: ReportCSV.data(twoLevel, label: golden.label), as: UTF8.self)
        == (try golden.answer("report.july.expensesByCategoryAndSubcategory.csv").text))

    func grouped(_ kind: ReportTable.Kind, _ grouping: ReportGrouping) -> [Golden.Node] {
      builder.table(kind, period: august, grouping: grouping).rows.map(Self.node)
    }
    #expect(
      grouped(.expensesByCategoryAndSubcategory, .place) == (try nodes("report.august.byPlace")))
    #expect(
      grouped(.expensesByCategoryAndSubcategory, .forWhom) == (try nodes("report.august.byForWhom"))
    )
    #expect(
      grouped(.expensesByCategory, .paymentMethod) == (try nodes("report.august.byPaymentMethod")))
    #expect(grouped(.expensesByCategory, .event) == (try nodes("report.august.byEvent")))

    let oneLevel = builder.table(.expensesByCategory, period: july)
    let roots = try nodes("breakdown.july.expenses").map {
      Golden.Node(key: $0.key, amount: $0.amount, share: $0.share, children: nil)
    }
    #expect(oneLevel.rows.map(Self.node) == roots)
    #expect(oneLevel.total.amount == (try amount("julyExpenses")))
    #expect(oneLevel.total.share == Shares.whole)

    let monthly = builder.table(.monthly, period: .year(2026))
    #expect(
      String(decoding: ReportCSV.data(monthly, label: golden.label), as: UTF8.self)
        == (try golden.answer("report.monthly.2026").text))
    #expect(monthly.rows.map(\.isIncomplete) == (1...12).map { $0 == 8 })
    #expect(monthly.averageMonths == [MonthKey(year: 2026, month: 7)])

    let total = builder.table(.periodTotal, period: july)
    #expect(
      String(decoding: ReportCSV.data(total, label: golden.label), as: UTF8.self)
        == (try golden.answer("report.july.periodTotal").text))
  }

  static func node(_ row: ReportRow) -> Golden.Node {
    Golden.Node(
      key: fixtureKey(row.key), amount: text(row.amount), share: row.share,
      children: row.children.isEmpty ? nil : row.children.map(node))
  }

  // MARK: - Series

  @Test func series() throws {
    let weeks = TimeSeries(ledger: ledger, period: august, step: .week, today: today)
    #expect(
      weeks.points.map { [$0.start.iso, text($0.amount)] } == (try items("series.august.weeks")))
    #expect(weeks.average == (try amount("series.august.weeks.average")))

    let months = TimeSeries(ledger: ledger, period: .year(2026), step: .month, today: today)
    #expect(months.average == (try amount("series.2026.months.expenses.average")))
    #expect(months.points[6].amount == (try amount("julyExpenses")))
    let income = TimeSeries(
      ledger: ledger, period: .year(2026), step: .month, measure: .income, today: today)
    #expect(income.average == (try amount("series.2026.months.income.average")))
    #expect(income.points[7].amount == (try amount("augustIncome")))

    let days = TimeSeries(ledger: ledger, period: august, step: .day, today: today)
    #expect(days.points.count == 31)
    #expect(days.total == (try amount("augustExpenses")))

    let both = IncomeVsExpense(ledger: ledger, period: .year(2026))
    #expect(both.months[6].income == (try amount("julyIncome")))
    #expect(both.months[7].expenses == (try amount("augustExpenses")))
    #expect(both.expenses == (try amount("julyExpenses")) + (try amount("augustExpenses")))
  }

  @Test func comparisonWithThePreviousPeriod() throws {
    let current = PeriodComparison(ledger: ledger, period: august, today: today)
    #expect(!current.isComplete)
    #expect(current.expenses.current == (try amount("overview.expenses.current")))
    #expect(current.expenses.previous == (try amount("overview.expenses.previous")))
    #expect(current.income.current == (try amount("overview.income.current")))
    #expect(current.income.previous == (try amount("overview.income.previous")))
    let cumulative = current.currentCumulative
    #expect(
      [cumulative[0], cumulative[1], cumulative[2], cumulative[19]]
        == (try amounts("comparison.august.cumulative")))
    #expect(current.previousCumulative.last == (try amount("comparison.august.previousLast")))

    let done = PeriodComparison(ledger: ledger, period: july, today: today)
    #expect(done.isComplete)
    #expect(done.previous == Period.month(MonthKey(year: 2026, month: 6)).range)
    #expect(done.expenses.previous == (try amount("comparison.july.previous")))
    #expect(done.expenses.basisPoints == nil)
    #expect(done.income.current == (try amount("julyIncome")))
  }

  @Test func weekdays() throws {
    let profile = WeekdayProfile(ledger: ledger, period: august, today: today)
    #expect(profile.interval == DayRange(day("2026-08-01"), day("2026-08-20")))
    #expect(
      profile.days.map { ["\($0.weekday)", text($0.total), "\($0.occurrences)", text($0.average)] }
        == (try items("weekday.august")))
  }

  // MARK: - Sections

  @Test func goodAndBad() throws {
    let report = QualityReport(ledger: ledger, period: july, today: today)
    #expect(
      report.months.first?.qualities.map(Golden.Node.init) == (try nodes("quality.july.month")))
    #expect(report.badByCategory.map(Golden.Node.init) == (try nodes("quality.july.badByCategory")))
    let streaks = try #require(golden.answer("quality.streaks").amounts)
    #expect(["\(report.currentStreak)", "\(report.bestStreak)"] == streaks)
    let goals = try #require(golden.answer("quality.july.goals").amounts)
    #expect(
      [
        text(report.goals), text(report.rest), "\(report.goalsShare ?? -1)",
        "\(report.restShare ?? -1)",
      ]
        == goals)
  }

  @Test func paidForOthers() throws {
    func figures(_ totals: OthersReport.Totals) -> [AmountE4] {
      [totals.paid, totals.returned, totals.writtenOff, totals.waiting, totals.shortfall]
    }
    let july = OthersReport(ledger: ledger, period: self.july)
    #expect(figures(july.totals) + [july.surplus] == (try amounts("others.july")))
    #expect(
      july.byPerson.map { ["\(number(of: $0.personId ?? UUID()))"] + figures($0.totals).map(text) }
        == (try items("others.july.byPerson")))
    let august = OthersReport(ledger: ledger, period: self.august)
    #expect(figures(august.totals) + [august.surplus] == (try amounts("others.august")))
    // The golden book has no scheduled payments and no `sched:` operation, so there is
    // nothing to slice by one — and the slice has to say so rather than invent a row.
    #expect(august.bySubscription.isEmpty)
    #expect(july.bySubscription.isEmpty)
  }

  @Test func forWhom() throws {
    let report = ForWhomReport(ledger: ledger, period: august)
    let values = try nodes("forWhom.august.values")
    #expect(report.values.map(Golden.Node.init) == values)
    #expect(report.people.map(Golden.Node.init) == (try nodes("forWhom.august.people")))
    #expect(report.months.map(\.month) == [MonthKey(year: 2026, month: 8)])
    let friends = try #require(values.first { $0.key == "for-whom:friends" })
    #expect(report.months[0].amounts[.friends] == money(friends.amount))
  }

  @Test func places() throws {
    func rows(_ period: Period) -> [[String]] {
      PlacesReport(ledger: ledger, period: period).places.map {
        [
          "\(number(of: $0.placeId))", text($0.mySpending), "\($0.purchases)",
          text($0.averageReceipt),
          $0.firstDay.iso, "\($0.isNew)",
        ]
      }
    }
    #expect(rows(july) == (try items("places.july")))
    #expect(rows(august) == (try items("places.august")))
    let report = PlacesReport(ledger: ledger, period: august)
    #expect(report.newPlaces.map { number(of: $0.placeId) } == [54])
    #expect(report.byPurchases.map { number(of: $0.placeId) } == [50, 51, 52, 54])
  }

  /// The answer's nodes are the categories of one event of the list, named here.
  @Test func events() throws {
    func check(_ period: Period, _ name: String, byCategoryOf event: Int) throws {
      let report = EventsReport(ledger: ledger, period: period)
      #expect(
        report.events.map {
          [
            "\(number(of: $0.eventId))", text($0.total), text($0.budget), text($0.budgetLeft),
            $0.lastYearEventId.map { "\(number(of: $0))" } ?? "", text($0.lastYearTotal),
          ]
        } == (try items(name)))
      let item = report.events.first { $0.eventId == id(event) }
      #expect(item?.byCategory.map(Golden.Node.init) == (try nodes(name)))
    }
    try check(august, "events.august", byCategoryOf: 71)
    try check(july, "events.july", byCategoryOf: 72)
  }

  @Test func paymentMethods() throws {
    func rows(_ period: Period) -> [[String]] {
      PaymentMethodsReport(ledger: ledger, period: period).methods.map {
        let key: String
        if case .paymentMethod(let id) = $0.key {
          key = "\(number(of: id))"
        } else {
          key = $0.key.description
        }
        return [
          key, text($0.mySpending), text($0.turnover), text($0.cashback),
          "\($0.cashbackShare ?? -1)",
        ]
      }
    }
    #expect(rows(july) == (try items("paymentMethods.july")))
    #expect(rows(august) == (try items("paymentMethods.august")))
  }

  // MARK: - Transactions filter

  @Test func filters() throws {
    let cases: [(String, EntryFilter)] = [
      ("filter.augustIncome", EntryFilter(period: august, kind: .income)),
      ("filter.julyIncome", EntryFilter(period: july, kind: .income)),
      ("filter.foodOutBad", EntryFilter(categoryId: id(12), quality: .bad)),
      ("filter.cafeReturned", EntryFilter(subcategoryId: id(13), reimbursementStatus: .returned)),
      ("filter.anna", EntryFilter(personId: id(40))),
      ("filter.textSouvenir", EntryFilter(text: "Souvenir")),
      ("filter.textBarNord", EntryFilter(text: "  bar   NORD ")),
      ("filter.travelAugust", EntryFilter(period: august, paymentMethodId: id(61))),
      ("filter.birthday", EntryFilter(eventId: id(71))),
      ("filter.partner", EntryFilter(forWhom: .partner)),
      ("filter.bad", EntryFilter(quality: .bad)),
      ("filter.deleted", EntryFilter(text: "mistake")),
      ("filter.marketJulyExpenses", EntryFilter(period: july, kind: .expense, placeId: id(50))),
    ]
    for (name, filter) in cases {
      let found = filter.apply(to: ledger).map { number(of: $0) }
      #expect(found == (try golden.answer(name).ids), "\(name)")
    }
    let souvenir = EntryFilter(text: "souvenir").apply(to: ledger)
    let totals = ledger.rowTotals(of: souvenir)
    #expect(
      [totals.myExpenses, totals.income, totals.forOthers, totals.moneyReturned]
        == (try amounts("filter.textSouvenir.rowTotals")))
    #expect(EntryFilter.none.apply(to: ledger).count == golden.operations.count - 1)
  }

  // MARK: - Forecast

  @Test func forecast() throws {
    let planned = PlannedPayments(ledger: ledger, today: today, rubPerUnit: golden.rubPerUnit)
    #expect([planned.debts, planned.goals] == (try amounts("forecast.planned")))
    #expect(planned.debtsWithoutRate.isEmpty)
    #expect(PlannedPayments(ledger: ledger, today: today).debtsWithoutRate == [id(93)])

    let remainder = MonthForecast.remainder(ledger: ledger, today: today)
    #expect(
      [remainder.p10, remainder.middle, remainder.p90]
        + [
          AmountE4(whole: Int64(remainder.windowDays)), AmountE4(whole: Int64(remainder.daysLeft)),
        ]
        == (try amounts("forecast.remainder")))
    #expect(!remainder.lowData)
    #expect(remainder.computedFor == today)

    let spent = OverviewSummary(ledger: ledger, today: today).expenses.current
    let forecast = MonthForecast(spent: spent, planned: planned.total, remainder: remainder)
    #expect([forecast.p10, forecast.p50, forecast.p90] == (try amounts("forecast.total")))
  }

  // MARK: - One source for three screens

  /// Expenses of a month: the Overview on its last day, the row of the monthly report, the
  /// month bucket of Analytics, the category table and the sum of the day headers agree.
  /// Income of a month: the Overview rule with the cut-off on the last day of the data, the
  /// report row and the month bucket agree.
  @Test(arguments: [7, 8])
  func overviewAnalyticsAndReportsAgree(_ monthNumber: Int) throws {
    let month = MonthKey(year: 2026, month: monthNumber)
    let overview = OverviewSummary(ledger: ledger, today: month.lastDay)
    let report = ReportBuilder(ledger: ledger, today: today).table(.monthly, period: .year(2026))
    let row = try #require(report.rows.first { $0.key == .month(month) })
    let buckets = TimeSeries(ledger: ledger, period: .year(2026), step: .month, today: today)
    let bucket = try #require(buckets.points.first { $0.start == month.firstDay })
    let table = CategoryBreakdown(ledger: ledger, period: .month(month), kind: .expense)
    let days = Period.month(month).range.days.map { day in
      ledger.rowTotals(of: Set(ledger.rows(in: DayRange(day, day)).map(\.transactionId))).myExpenses
    }
    let expenses = overview.expenses.current
    #expect(row.values[0] == expenses)
    #expect(bucket.amount == expenses)
    #expect(table.total == expenses)
    #expect(AmountE4.sum(days) == expenses)

    let lastDay = try #require(ledger.rows.last?.day)
    let income = ledger.income(attributedTo: [month], notAfter: lastDay)
    let incomeBuckets = TimeSeries(
      ledger: ledger, period: .year(2026), step: .month, measure: .income, today: today)
    #expect(row.values[1] == income)
    #expect(incomeBuckets.points.first { $0.start == month.firstDay }?.amount == income)
    #expect(CategoryBreakdown(ledger: ledger, period: .month(month), kind: .income).total == income)
  }

  /// Cashback by payment method adds up to the cashback line of the income table.
  @Test func cashbackByMethodsIsTheCashbackRow() throws {
    for period in [july, august] {
      let methods = PaymentMethodsReport(ledger: ledger, period: period)
      let income = CategoryBreakdown(ledger: ledger, period: period, kind: .income)
      let cashbackRow = income.nodes.flatMap(\.children).first { $0.key == .category(id(33)) }
      #expect(methods.cashback == cashbackRow?.amount)
    }
  }
}

/// An amount the fixtures write as text — in the golden set, in the literals of these suites —
/// is a plain decimal. A typo is a failed test that names it, never a quiet zero or the number
/// `Decimal(string:)` finds at its start: «1 000» was 1, «1000 ₽» was 1000, «abc» was 0.
@Suite("Amount literals of the analytics fixtures")
struct AmountLiteralTests {
  static let typos = ["1 000", "1,000", "1000 ₽", "1e3", ".5", "0.12345", "abc", ""]

  @Test(arguments: typos)
  func aTypoIsAFailedTest(_ text: String) {
    withKnownIssue { _ = money(text) }
    withKnownIssue { _ = OthersBySubscriptionTests().amount(text) }
  }

  @Test func aPlainDecimalIsTheAmount() {
    #expect(money("-1234.5") == AmountE4(raw: -12_345_000))
    #expect(money("0.0001") == AmountE4(raw: 1))
    #expect(money("50000") == AmountE4(whole: 50_000))
  }
}
