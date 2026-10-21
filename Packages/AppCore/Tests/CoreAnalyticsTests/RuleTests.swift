import CoreAccounting
import CoreCSV
import CoreKit
import Foundation
import Testing

@testable import CoreAnalytics

/// A tiny dataset built in code, for the rules that need one case each.
struct Sketch {
  var entries: [TransactionEntry] = []
  var debts: [Debt] = []
  var goals: [Goal] = []
  let groceries = id(10)
  let salary = id(31)
  let categories = [
    CoreKit.Category(id: id(10), kind: .expense, name: "Groceries", quality: .neutral),
    CoreKit.Category(
      id: id(3), kind: .expense, name: "Loans", quality: .neutral, systemRole: .loans),
    CoreKit.Category(id: id(4), parentId: id(3), kind: .expense, name: "Bank loan"),
    CoreKit.Category(id: id(31), kind: .income, name: "Salary"),
  ]
  private var next = 1000

  mutating func expense(
    _ iso: String, _ amount: String, category: UUID? = id(10), debt: UUID? = nil
  ) {
    add(.expense, iso, amount, category: category, debt: debt)
  }

  mutating func income(_ iso: String, _ amount: String, for month: String? = nil) {
    add(.income, iso, amount, category: salary, periodMonth: month.flatMap(MonthKey.init(iso:)))
  }

  private mutating func add(
    _ kind: TransactionKind, _ iso: String, _ amount: String, category: UUID?, debt: UUID? = nil,
    periodMonth: MonthKey? = nil
  ) {
    next += 1
    let transactionId = id(next)
    let when = CalendarContext.utc.startOfDay(day(iso)).addingTimeInterval(12 * 3600)
    let part = TransactionPart(
      id: id(next + 500_000), transactionId: transactionId, categoryId: category,
      quality: kind.hasQuality ? .neutral : nil, qualitySource: kind.hasQuality ? .category : nil,
      amountE4: money(amount))
    entries.append(
      TransactionEntry(
        transaction: Transaction(
          id: transactionId, kind: kind, occurredAt: when, amountE4: money(amount),
          periodMonth: periodMonth,
          debtId: debt, createdAt: when, updatedAt: when),
        parts: [part]))
  }

  var ledger: Ledger {
    Ledger(
      dataset: Dataset(entries: entries, categories: categories, debts: debts, goals: goals),
      calendar: .utc)
  }
}

@Suite("Rules of the calculations, one case each")
struct RuleTests {

  // MARK: - Overview comparisons

  /// On 31 March the same span of February is the 1st to the 28th, and it takes the 28th.
  @Test func march31IsComparedWithFebruary1To28() {
    var sketch = Sketch()
    sketch.expense("2026-02-28", "100")
    sketch.expense("2026-03-31", "300")
    let summary = OverviewSummary(ledger: sketch.ledger, today: day("2026-03-31"))
    #expect(summary.previousSpan == DayRange(day("2026-02-01"), day("2026-02-28")))
    #expect(summary.expenses.previous == money("100"))
    #expect(summary.expenses.basisPoints == 20_000)
  }

  /// A negative base — refunds outweighed spending — is measured against its size,
  /// so the percent always has the sign of the difference in rubles: from −100 to −200 the
  /// figure fell, −100 %; from −100 to 0 it rose, +100 %. Dividing by the signed base would
  /// call the first a rise.
  @Test func aChangeAgainstANegativeBaseHasTheSignOfTheDifference() {
    let cases: [(current: String, previous: String, bp: Int)] = [
      ("-200", "-100", -10_000), ("0", "-100", 10_000), ("-50", "-100", 5_000),
      ("300", "-100", 40_000),
    ]
    for (current, previous, bp) in cases {
      let change = Change(current: money(current), previous: money(previous))
      #expect(change.basisPoints == bp, "\(previous) → \(current)")
      #expect((change.basisPoints ?? 0).signum() == Int(change.delta.raw.signum()))
    }
  }

  /// With nothing last month there is no percent — only the difference in rubles.
  @Test func anEmptyPreviousMonthGivesNoPercent() {
    var sketch = Sketch()
    sketch.expense("2026-09-05", "500")
    sketch.income("2026-09-05", "1000")
    let summary = OverviewSummary(ledger: sketch.ledger, today: day("2026-09-18"))
    #expect(summary.expenses.basisPoints == nil)
    #expect(summary.expenses.delta == money("500"))
    #expect(summary.income.basisPoints == nil)
    #expect(summary.bad.basisPoints == nil)
    #expect(
      summary.qualities.allSatisfy { $0.key != .quality(.neutral) || $0.share == Shares.whole })
    let empty = OverviewSummary(ledger: Sketch().ledger, today: day("2026-09-18"))
    #expect(empty.qualities.allSatisfy { $0.share == nil })
    #expect(empty.topCategories.isEmpty)
  }

  /// The card lists the five largest buckets. Money without a category takes its place by
  /// its size: the tables put it last, but a card that hid the largest bucket behind five
  /// smaller ones would understate where the money went.
  @Test func uncategorizedSpendingTakesItsPlaceInTheTopByItsSize() {
    var sketch = Sketch()
    let roots = (60..<66).map { id($0) }
    let extra = roots.enumerated().map { index, root in
      CoreKit.Category(id: root, kind: .expense, name: "Root \(index)", quality: .neutral)
    }
    for (index, root) in roots.enumerated() {
      sketch.expense("2026-09-0\(index + 1)", "\(100 + index)", category: root)
    }
    sketch.expense("2026-09-10", "500", category: nil)
    let ledger = Ledger(
      dataset: Dataset(entries: sketch.entries, categories: sketch.categories + extra),
      calendar: .utc)

    let top = OverviewSummary(ledger: ledger, today: day("2026-09-18")).topCategories

    #expect(
      top.map(\.key) == [.uncategorized] + roots.reversed().prefix(4).map(ReportKey.category))
    // The shares are still of every bucket, so the five do not add up to 100 %.
    #expect(top.first?.share == 4_484)
  }

  /// Salary for September that arrives on 3 October: the Overview of 30 September does not
  /// see money that has not arrived; the September row of Reports does.
  @Test func incomeForThePreviousMonthArrivingOnThe3rd() {
    var sketch = Sketch()
    sketch.income("2026-10-03", "50000", for: "2026-09")
    let ledger = sketch.ledger
    let onThe30th = day("2026-09-30")
    #expect(OverviewSummary(ledger: ledger, today: onThe30th).income.current == .zero)
    let report = ReportBuilder(ledger: ledger, today: onThe30th).table(
      .monthly, period: .year(2026))
    let september = report.rows.first { $0.key == .month(MonthKey(year: 2026, month: 9)) }
    #expect(september?.values[1] == money("50000"))
    let october = OverviewSummary(ledger: ledger, today: day("2026-10-05"))
    #expect(october.income.current == .zero)
    #expect(october.income.previous == .zero)
    // The day chart takes it by date, in October.
    let days = TimeSeries(
      ledger: ledger, period: .month(MonthKey(year: 2026, month: 10)), step: .day, measure: .income,
      today: day("2026-10-05"))
    #expect(days.total == money("50000"))
  }

  /// A span of days that cuts a month takes income by date as a whole, and
  /// so does every monthly bucket of it — the month lying whole inside too. Mixing the two
  /// rules counted an advance dated in July for August twice and cashback dated in August
  /// for July in neither.
  @Test func aSpanCuttingAMonthTakesEveryMonthlyBucketsIncomeByDate() {
    var sketch = Sketch()
    sketch.income("2026-07-28", "50000", for: "2026-08")
    sketch.income("2026-08-01", "150", for: "2026-07")
    let ledger = sketch.ledger
    let period = Period.days(DayRange(day("2026-07-15"), day("2026-08-31")))
    let expected = ledger.income(in: period)
    #expect(expected == money("50150"))

    let series = TimeSeries(
      ledger: ledger, period: period, step: .month, measure: .income, today: day("2026-09-01"))
    #expect(series.points.map(\.amount) == [money("50000"), money("150")])
    #expect(series.total == expected)
    let months = IncomeVsExpense(ledger: ledger, period: period)
    #expect(months.months.map(\.income) == [money("50000"), money("150")])
    #expect(months.income == expected)
    #expect(IncomeSources(ledger: ledger, period: period).total == expected)

    // A period of whole months keeps the month the income is for, bucket by bucket.
    let whole = Period.days(DayRange(day("2026-07-01"), day("2026-08-31")))
    let attributed = TimeSeries(
      ledger: ledger, period: whole, step: .month, measure: .income, today: day("2026-09-01"))
    #expect(attributed.points.map(\.amount) == [money("150"), money("50000")])
    #expect(IncomeVsExpense(ledger: ledger, period: whole).income == ledger.income(in: whole))
  }

  /// Income taken by the month it is for can belong to a month before the first operation's
  /// date: the book starts on 1 September and August's salary arrives on the 3rd. August is
  /// then a month of the history — it is in the total, and the average takes it too, as the
  /// Reports' monthly average does: (80 000 + 100 000) / 2.
  @Test func incomeForAMonthBeforeTheFirstOperationIsInTheAverage() {
    var sketch = Sketch()
    sketch.expense("2026-09-01", "500")
    sketch.income("2026-09-03", "80000", for: "2026-08")
    sketch.income("2026-09-25", "100000")
    let ledger = sketch.ledger
    let series = TimeSeries(
      ledger: ledger, period: .year(2026), step: .month, measure: .income,
      today: day("2026-09-30"))
    #expect(series.points[7].amount == money("80000"))
    #expect(series.total == money("180000"))
    #expect(series.average == money("90000"))

    // Spending has no such month: August holds nothing and stays out.
    let spending = TimeSeries(
      ledger: ledger, period: .year(2026), step: .month, today: day("2026-09-30"))
    #expect(spending.average == money("500"))
    // By date, the salary is September's, and so is the whole history.
    let daily = TimeSeries(
      ledger: ledger, period: .month(MonthKey(year: 2026, month: 9)), step: .week,
      measure: .income, today: day("2026-09-30"))
    #expect(daily.total == money("180000"))
  }

  // MARK: - Events

  /// Last year's event of the series with no operation at all says nothing about what it
  /// cost — «no data», not «0 spent» — while one whose purchase came back in full did cost
  /// nothing, and says so.
  @Test func lastYearsEventWithoutOperationsHasNoTotal() {
    let birthdays = id(9_000)
    let trips = id(9_001)
    let events = [
      Event(
        id: id(9_010), name: "Birthday", kind: .birthday, startDate: day("2025-06-10"),
        endDate: day("2025-06-10"), seriesId: birthdays),
      Event(
        id: id(9_011), name: "Birthday", kind: .birthday, startDate: day("2026-06-10"),
        endDate: day("2026-06-10"), seriesId: birthdays),
      Event(
        id: id(9_020), name: "Trip", kind: .trip, startDate: day("2025-07-01"),
        endDate: day("2025-07-05"), seriesId: trips),
      Event(
        id: id(9_021), name: "Trip", kind: .trip, startDate: day("2026-07-01"),
        endDate: day("2026-07-05"), seriesId: trips),
    ]
    func entry(
      _ number: Int, _ kind: TransactionKind, _ iso: String, _ amount: String, event: UUID
    ) -> TransactionEntry {
      let when = CalendarContext.utc.startOfDay(day(iso)).addingTimeInterval(12 * 3600)
      return TransactionEntry(
        transaction: Transaction(
          id: id(number), kind: kind, occurredAt: when, amountE4: money(amount),
          createdAt: when, updatedAt: when),
        parts: [
          TransactionPart(
            id: id(number + 1), transactionId: id(number), categoryId: id(10),
            quality: kind.hasQuality ? .neutral : nil,
            qualitySource: kind.hasQuality ? .category : nil, amountE4: money(amount),
            eventId: event)
        ])
    }
    let entries = [
      entry(9_100, .expense, "2026-06-10", "3000", event: id(9_011)),
      entry(9_110, .expense, "2025-07-02", "800", event: id(9_020)),
      entry(9_120, .refund, "2025-07-09", "800", event: id(9_020)),
      entry(9_130, .expense, "2026-07-02", "1500", event: id(9_021)),
    ]
    let ledger = Ledger(
      dataset: Dataset(entries: entries, categories: Sketch().categories, events: events),
      calendar: .utc)
    let report = EventsReport(ledger: ledger, period: .year(2026))
    let birthday = report.events.first { $0.eventId == id(9_011) }
    #expect(birthday?.lastYearEventId == id(9_010))
    #expect(birthday?.lastYearTotal == nil)
    let trip = report.events.first { $0.eventId == id(9_021) }
    #expect(trip?.lastYearEventId == id(9_020))
    #expect(trip?.lastYearTotal == .zero)
  }

  // MARK: - Reports

  /// The book starts in September; on 15 November the average is (September + October) / 2
  /// and November, incomplete, stays out of it.
  @Test func theAverageRunsFromTheFirstMonthWithOperations() {
    var sketch = Sketch()
    sketch.expense("2026-09-10", "3000")
    sketch.expense("2026-10-10", "5000")
    sketch.expense("2026-11-10", "100000")
    let table = ReportBuilder(ledger: sketch.ledger, today: day("2026-11-15"))
      .table(.monthly, period: .year(2026))
    #expect(
      table.averageMonths == [MonthKey(year: 2026, month: 9), MonthKey(year: 2026, month: 10)])
    #expect(table.average?.values[0] == money("4000"))
    #expect(table.rows[10].isIncomplete)
    #expect(table.rows[11].values == [nil, nil, nil])
    #expect(table.total.values[0] == money("108000"))

    var fresh = Sketch()
    fresh.expense("2026-11-10", "700")
    let early = ReportBuilder(ledger: fresh.ledger, today: day("2026-11-15"))
      .table(.monthly, period: .year(2026))
    #expect(early.average == nil)
    #expect(early.averageMonths.isEmpty)
    #expect(early.hasData)
  }

  /// On 28 September an advance for October has arrived and a payment is entered ahead for
  /// 5 October. Every table of the year counts the whole year, so the monthly table shows
  /// October with what is booked for it — not over, out of the average —
  /// and its «Итого» is the period total and the total of every category table.
  @Test func theYearTablesAgreeWhenSomethingIsBookedAhead() throws {
    var sketch = Sketch()
    sketch.expense("2026-09-10", "3000")
    sketch.income("2026-09-28", "50000", for: "2026-10")
    sketch.expense("2026-10-05", "10000")
    let builder = ReportBuilder(ledger: sketch.ledger, today: day("2026-09-28"))
    let year = Period.year(2026)
    let monthly = builder.table(.monthly, period: year)

    let september = monthly.rows[8]
    #expect(september.values == [money("3000"), .zero, money("-3000")])
    #expect(september.isIncomplete)
    let october = monthly.rows[9]
    #expect(october.key == .month(MonthKey(year: 2026, month: 10)))
    #expect(october.values == [money("10000"), money("50000"), money("40000")])
    #expect(october.isIncomplete)
    // Nothing is booked for November yet: a dash, as before.
    #expect(monthly.rows[10].values == [nil, nil, nil])
    // The book starts in September: no month of it is complete, so there is no average.
    #expect(monthly.average == nil)

    let expenses = monthly.total.values[0]
    let income = monthly.total.values[1]
    #expect(monthly.total.values == [money("13000"), money("50000"), money("37000")])
    let periodTotal = builder.table(.periodTotal, period: year)
    #expect(periodTotal.rows.map(\.values) == [[income], [expenses]])
    #expect(periodTotal.total.values == [monthly.total.values[2]])
    #expect(builder.table(.incomeByCategory, period: year).total.amount == income)
    for grouping in ReportGrouping.allCases {
      for kind in [ReportTable.Kind.expensesByCategory, .expensesByCategoryAndSubcategory] {
        #expect(
          builder.table(kind, period: year, grouping: grouping).total.amount == expenses,
          "\(kind) \(grouping)")
      }
    }
  }

  @Test func threeEqualBucketsMakeExactly10000BasisPoints() {
    let shares = Shares.basisPoints([money("100"), money("100"), money("100")])
    #expect(shares == [3334, 3333, 3333])
    #expect(shares.compactMap { $0 }.reduce(0, +) == Shares.whole)
    // A negative bucket gets no share and is not part of the base.
    #expect(Shares.basisPoints([money("300"), money("-50"), money("100")]) == [7500, nil, 2500])
    #expect(Shares.basisPoints([money("-1"), .zero]) == [nil, nil])
    #expect(Shares.basisPoints([]) == [])
  }

  /// Buckets whose total leaves `Int64` — stored amounts beyond the input limit —
  /// still get their shares instead of trapping the Overview on every open.
  @Test func bucketsTooLargeToAddUpStillGetTheirShares() {
    let huge = AmountE4(raw: 6_000_000_000_000_000_000)
    #expect(Shares.basisPoints([huge, huge]) == [5000, 5000])
    let shares = Shares.basisPoints([AmountE4(raw: .max), huge, money("100"), money("-5")])
    #expect(shares.compactMap { $0 }.reduce(0, +) == Shares.whole)
    #expect(shares[3] == nil)
  }

  /// In every two-level table a parent is the sum of its children and the table adds up
  /// to its total — for every grouping.
  @Test(arguments: ReportGrouping.allCases)
  func childrenAddUpToTheirParent(_ grouping: ReportGrouping) throws {
    let golden = try Golden.load()
    let builder = ReportBuilder(ledger: golden.ledger(), today: golden.todayDay)
    for month in [7, 8] {
      let period = Period.month(MonthKey(year: 2026, month: month))
      let table = builder.table(
        .expensesByCategoryAndSubcategory, period: period, grouping: grouping)
      for row in table.rows where !row.children.isEmpty {
        #expect(AmountE4.sum(row.children.compactMap(\.amount)) == row.amount)
        #expect(row.type == .subtotal)
      }
      #expect(AmountE4.sum(table.rows.compactMap(\.amount)) == table.total.amount)
      #expect(table.rows.compactMap(\.share).reduce(0, +) == Shares.whole)
    }
  }

  /// Closing the loan and archiving a category rename nothing in the past: July keeps its
  /// totals and its breakdown.
  @Test func closingADebtAndArchivingACategoryKeepThePast() throws {
    let golden = try Golden.load()
    let before = golden.ledger()
    var dataset = golden.dataset()
    for index in dataset.debts.indices { dataset.debts[index].closed = true }
    for index in dataset.categories.indices
    where [id(12), id(13), id(3)].contains(dataset.categories[index].id) {
      dataset.categories[index].archived = true
    }
    let after = Ledger(dataset: dataset, calendar: .utc)
    let july = Period.month(MonthKey(year: 2026, month: 7))
    #expect(after.expenses(in: july.range) == before.expenses(in: july.range))
    #expect(
      CategoryBreakdown(ledger: after, period: july, kind: .expense)
        == CategoryBreakdown(ledger: before, period: july, kind: .expense))
  }

  /// The CSV reads back with the same shape on every row, and summing the item rows gives
  /// the total — subtotals are never counted twice.
  @Test(arguments: [
    ReportTable.Kind.expensesByCategoryAndSubcategory, .expensesByCategory, .incomeByCategory,
    .monthly,
  ])
  func csvItemsAddUpToTheTotal(_ kind: ReportTable.Kind) throws {
    let golden = try Golden.load()
    let builder = ReportBuilder(ledger: golden.ledger(), today: golden.todayDay)
    for grouping in ReportGrouping.allCases {
      let table = builder.table(
        kind, period: .month(MonthKey(year: 2026, month: 7)), grouping: grouping)
      let data = ReportCSV.data(table, label: golden.label)
      #expect(data.first != 0xEF, "no byte-order mark")
      let rows = try CSVReader.rows(from: data)
      let header = try #require(rows.first)
      #expect(rows.allSatisfy { $0.count == header.count })
      let exact = try #require(header.firstIndex { $0.hasSuffix("_rub_exact") })
      // A month of the year still to come is an empty cell, not a zero: it adds nothing.
      let items = rows.dropFirst().filter { $0[0] == "item" && !$0[exact].isEmpty }
        .map { money($0[exact]) }
      let total = try #require(rows.last { $0[0] == "total" })
      #expect(AmountE4.sum(items) == money(total[exact]))
      #expect(rows.dropFirst().allSatisfy { ReportRow.RowType(rawValue: $0[0]) != nil })
    }
  }

  @Test func csvAmountsAndShares() {
    #expect(ReportCSV.exact(money("1234.5")) == "1234.5000")
    #expect(ReportCSV.exact(money("-0.25")) == "-0.2500")
    #expect(ReportCSV.exact(.zero) == "0.0000")
    #expect(money("0.5").wholeRubles == 1)
    #expect(money("-0.5").wholeRubles == -1)
    #expect(money("2.4999").wholeRubles == 2)
    #expect(ReportCSV.share(2573) == "0.2573")
    #expect(ReportCSV.share(Shares.whole) == "1.0000")
    #expect(ReportCSV.share(nil) == "")
  }

  // MARK: - Forecast

  /// The forecast's arithmetic weekday is `DateOnly.weekday` on every day, those before
  /// 1 January 1970 (negative day numbers) included: 1…7, Monday first.
  @Test func theForecastsWeekdayIsTheCalendarsOnEitherSideOf1970() {
    var sketch = Sketch()
    sketch.expense("2026-09-02", "100")
    let spending = VariableSpending(ledger: sketch.ledger)
    let wrong = (-800...800).filter { number in
      spending.weekday(of: number) != DateOnly(dayNumber: number).weekday
    }
    #expect(wrong.isEmpty, "\(wrong.count) days, the first \(wrong.first ?? 0)")
    #expect(spending.weekday(of: day("1969-12-29").dayNumber) == 1)
  }

  /// A loan still to be paid this month is planned; once paid this month, or closed, it is
  /// not.
  @Test func aLoanIsPlanned() {
    var sketch = Sketch()
    let loan = Debt(
      id: id(90), direction: .iOwe, type: .loan, name: "Loan", monthlyPaymentE4: money("7000"),
      paymentDay: 25, paymentsAreExpenses: true, origin: .existing)
    sketch.debts = [loan]
    sketch.expense("2026-08-25", "7000", category: id(4), debt: loan.id)
    let today = day("2026-09-20")
    #expect(PlannedPayments(ledger: sketch.ledger, today: today).debts == money("7000"))
    #expect(PlannedPayments(ledger: sketch.ledger, today: day("2026-09-25")).debts == .zero)

    sketch.expense("2026-09-02", "7000", category: id(4), debt: loan.id)
    #expect(PlannedPayments(ledger: sketch.ledger, today: today).debts == .zero)

    var closed = Sketch()
    closed.debts = [loan]
    closed.debts[0].closed = true
    #expect(PlannedPayments(ledger: closed.ledger, today: today).total == .zero)

    var goal = Sketch()
    goal.goals = [
      Goal(id: id(80), name: "Goal", targetE4: money("1000"), monthlyPlanE4: money("300"))
    ]
    #expect(PlannedPayments(ledger: goal.ledger, today: today).goals == money("300"))
  }

  /// «День платежа позже сегодняшнего» is the day the payment is due: a loan paid
  /// «on the 31st» is due on 30 September (clipped to the month, as `DebtSchedule` and
  /// `Recurrence.clipped` have it), so on the 30th it is due today, not later this month.
  @Test func aPaymentDayPastTheMonthsEndIsDueOnItsLastDay() {
    var sketch = Sketch()
    let loan = Debt(
      id: id(90), direction: .iOwe, type: .loan, name: "Loan", monthlyPaymentE4: money("7000"),
      paymentDay: 31, paymentsAreExpenses: true, origin: .existing)
    sketch.debts = [loan]
    #expect(PlannedPayments(ledger: sketch.ledger, today: day("2026-09-29")).debts == money("7000"))
    #expect(PlannedPayments(ledger: sketch.ledger, today: day("2026-09-30")).debts == .zero)
    #expect(PlannedPayments(ledger: sketch.ledger, today: day("2026-10-30")).debts == money("7000"))
    #expect(PlannedPayments(ledger: sketch.ledger, today: day("2027-02-28")).debts == .zero)
  }

  /// Money borrowed on the loan through the entry line — an income that points at the debt,
  /// written in its journal as `borrowed` — does not pay the month (third review, 19.09): the
  /// 7 000 of the 25th is still planned.
  @Test func moneyBorrowedOnALoanDoesNotPayTheMonth() {
    var sketch = Sketch()
    let loan = Debt(
      id: id(90), direction: .iOwe, type: .loan, name: "Loan", monthlyPaymentE4: money("7000"),
      paymentDay: 25, paymentsAreExpenses: true, origin: .existing)
    sketch.debts = [loan]
    let when = CalendarContext.utc.startOfDay(day("2026-09-10")).addingTimeInterval(12 * 3600)
    let borrowed = TransactionEntry(
      transaction: Transaction(
        id: id(700), kind: .income, occurredAt: when, amountE4: money("50000"), debtId: loan.id,
        createdAt: when, updatedAt: when),
      parts: [
        TransactionPart(
          id: id(701), transactionId: id(700), categoryId: sketch.salary,
          amountE4: money("50000"))
      ])
    let journal = [
      DebtEntry(
        id: id(702), debtId: loan.id, date: day("2026-09-10"), amountE4: money("50000"),
        kind: .borrowed, transactionId: id(700))
    ]
    let ledger = Ledger(
      dataset: Dataset(
        entries: sketch.entries + [borrowed], categories: sketch.categories, debts: [loan],
        planning: PlanningBook(debtEntries: journal)),
      calendar: .utc)
    #expect(PlannedPayments(ledger: ledger, today: day("2026-09-20")).debts == money("7000"))
  }

  /// A debt payment and a line in a system category are my spending but never variable
  /// spending: the first is planned, the second is the app's own. Each is checked on its own —
  /// the payment is filed under an ordinary category, the charge in Loans has no debt — over
  /// thirty days of 1 000, a window long enough that counting either would move the mean.
  @Test func debtPaymentsAndSystemCategoriesAreNotVariable() {
    var sketch = Sketch()
    sketch.debts = [
      Debt(
        id: id(90), direction: .iOwe, type: .loan, name: "Loan", monthlyPaymentE4: money("7000"),
        paymentDay: 25, paymentsAreExpenses: true, origin: .existing)
    ]
    let today = day("2026-09-20")
    for offset in 1...30 {
      sketch.expense(today.adding(days: -offset).iso, "1000")
    }
    sketch.expense("2026-09-05", "7000", debt: id(90))
    sketch.expense("2026-09-06", "5000", category: id(4))
    let ledger = sketch.ledger
    // 1–19 September at 1 000 a day, plus both: they leave the forecast, not the month.
    #expect(
      ledger.expenses(in: Period.month(MonthKey(year: 2026, month: 9)).range) == money("31000"))

    let remainder = MonthForecast.remainder(ledger: ledger, today: today)
    #expect(remainder.windowDays == 30)
    #expect(remainder.daysLeft == 10)
    #expect(!remainder.lowData)
    // 30 000 / 30 days × 10 days left. With the payment counted it would be 37 000 / 30 × 10,
    // with the charge 35 000 / 30 × 10.
    #expect(remainder.middle == money("10000"))
    #expect(remainder.p10 == money("10000"))
    #expect(remainder.p90 == money("10000"))
  }

  /// Forty days of history are divided by forty, not by ninety.
  @Test func aFortyDayHistoryIsDividedByForty() {
    var sketch = Sketch()
    let today = day("2026-09-10")
    for offset in 1...40 {
      sketch.expense(today.adding(days: -offset).iso, "1000")
    }
    let remainder = MonthForecast.remainder(ledger: sketch.ledger, today: today)
    #expect(remainder.windowDays == 40)
    #expect(remainder.daysLeft == 20)
    #expect(remainder.middle == money("20000"))
    #expect(remainder.p10 == money("20000"))
    #expect(remainder.p90 == money("20000"))
    #expect(!remainder.lowData)
  }

  /// 89 days of 1 000 and one day of 100 000, one day left. One day out of ninety does not
  /// move the median of any weekday, so the forecast stays at 1 000 — the whole reason the
  /// the rule asks for quantiles and not for an average. The mean would
  /// have said 2 100: a hundred times one day, spread over a day that will not repeat.
  @Test func anOutlierDoesNotDragTheForecast() {
    var sketch = Sketch()
    let today = day("2026-09-29")
    for offset in 1...90 {
      sketch.expense(today.adding(days: -offset).iso, offset == 45 ? "100000" : "1000")
    }
    let remainder = MonthForecast.remainder(ledger: sketch.ledger, today: today)
    #expect(remainder.daysLeft == 1)
    #expect(remainder.windowDays == 90)
    #expect(remainder.middle == money("1000"))
    #expect(remainder.p10 == money("1000"))
    #expect(remainder.p90 == money("1000"))
    // The old window mean is still there and still says 2 100; the backtest is what chose
    // between them, and it chose the weekdays.
    let mean = MonthForecast.remainder(ledger: sketch.ledger, today: today, method: .window)
    #expect(mean.middle == money("2100"))
    let spent = money("5000")
    let forecast = MonthForecast(spent: spent, planned: .zero, remainder: remainder)
    #expect(forecast.p10 <= forecast.p50)
    #expect(forecast.p50 <= forecast.p90)
    #expect(forecast.p10 >= spent)
    #expect(forecast.p50 == money("6000"))
    #expect(forecast.p90 == money("6000"))
  }

  /// Less than 28 days of history: a straight line from the month so far, ±50 %.
  @Test func littleHistoryGivesAStraightLineWithAWideInterval() {
    var sketch = Sketch()
    sketch.expense("2026-09-01", "3000")
    sketch.expense("2026-09-10", "2000")
    let remainder = MonthForecast.remainder(ledger: sketch.ledger, today: day("2026-09-10"))
    #expect(remainder.lowData)
    #expect(remainder.windowDays == 9)
    // (3000 + 2000) / 10 days × 20 days left.
    #expect(remainder.middle == money("10000"))
    #expect(remainder.p10 == money("5000"))
    #expect(remainder.p90 == money("15000"))
  }

  /// On the last day of the month nothing is left: the interval is a point.
  @Test func theLastDayOfTheMonthIsAPoint() {
    var sketch = Sketch()
    sketch.expense("2026-09-01", "3000")
    let remainder = MonthForecast.remainder(ledger: sketch.ledger, today: day("2026-09-30"))
    #expect(remainder.daysLeft == 0)
    let forecast = MonthForecast(spent: money("3000"), planned: money("100"), remainder: remainder)
    #expect(forecast.p10 == money("3100"))
    #expect(forecast.p50 == money("3100"))
    #expect(forecast.p90 == money("3100"))
  }

  @Test func quantilesAndRollingSums() {
    let sample = [Decimal(4), 1, 3, 2]
    #expect(Quantile.value(sample, Decimal(1) / 2) == Decimal(string: "2.5"))
    #expect(Quantile.value(sample, Decimal(1) / 10) == Decimal(string: "1.3"))
    #expect(Quantile.value(sample, 1) == 4)
    #expect(Quantile.value([], Decimal(1) / 2) == nil)
    #expect(MonthForecast.rollingSums([1, 2, 3], length: 2) == [3, 5])
    // Shorter than a run: the runs wrap around, one starting at each day.
    #expect(MonthForecast.rollingSums([1, 2, 3], length: 4) == [7, 8, 9])
  }

  // MARK: - Dataset and selection

  @Test func writesAreLaidOverTheSnapshot() {
    var sketch = Sketch()
    sketch.expense("2026-09-01", "100")
    sketch.expense("2026-09-02", "20")
    let dataset = Dataset(entries: [sketch.entries[0]], categories: sketch.categories, version: 7)
    let added = sketch.entries[1]
    var edited = sketch.entries[0]
    edited.transaction.amountE4 = money("150")
    edited.parts[0].amountE4 = money("150")
    edited.parts[0].amountRubE4 = money("150")
    edited.transaction.amountRubE4 = money("150")
    let written = dataset.upserting([edited, added])
    #expect(written.version == 8)
    #expect(written.entries.count == 2)
    let ledger = Ledger(dataset: written, calendar: .utc)
    #expect(ledger.expenses(in: Period.month(MonthKey(year: 2026, month: 9)).range) == money("170"))
    let removed = written.removing([edited.id])
    #expect(removed.version == 9)
    #expect(removed.entries.map(\.id) == [added.id])
    #expect(dataset.upserting([]).version == 7)
  }

  /// «Money back: waiting» looks at purchases only. A friend's ticket that came back in a
  /// refund is written the way the app writes any part paid for somebody else — with the
  /// status `expected` stored — yet nobody waits for it: the money went back to the card.
  @Test func theStatusFilterLooksAtPurchasesOnly() {
    let friend = id(40)
    func owed(_ kind: TransactionKind, _ iso: String, number: Int) -> TransactionEntry {
      let when = CalendarContext.utc.startOfDay(day(iso)).addingTimeInterval(12 * 3600)
      let transactionId = id(number)
      return TransactionEntry(
        transaction: Transaction(
          id: transactionId, kind: kind, occurredAt: when, amountE4: money("700"),
          createdAt: when, updatedAt: when),
        parts: [
          TransactionPart(
            id: id(number + 1), transactionId: transactionId, categoryId: id(10),
            amountE4: money("700"), forWhom: .friends, reimbursable: true,
            debtorPersonId: friend, reimbursementStatus: .expected)
        ])
    }
    let purchase = owed(.expense, "2026-09-01", number: 2000)
    let refund = owed(.refund, "2026-09-05", number: 2010)
    let ledger = Ledger(
      dataset: Dataset(entries: [purchase, refund], categories: Sketch().categories),
      calendar: .utc)

    #expect(EntryFilter(reimbursementStatus: .expected).apply(to: ledger) == [purchase.id])
    // The person filter still finds both: the refund is about the friend all the same.
    #expect(Set(EntryFilter(personId: friend).apply(to: ledger)) == [purchase.id, refund.id])
    // The table reads a part's cells from its row.
    #expect(ledger.row(ofPart: id(2001))?.transactionId == purchase.id)
    #expect(ledger.row(ofPart: id(2011))?.kind == .refund)
    #expect(ledger.row(ofPart: id(9999)) == nil)
  }

  /// Select everything, then narrow the filter: only what is still visible stays selected.
  @Test func aSelectionNarrowsToWhatIsVisible() throws {
    let golden = try Golden.load()
    let ledger = golden.ledger()
    var selection = Set(EntryFilter.none.apply(to: ledger))
    let visible = EntryFilter(kind: .income).apply(to: ledger)
    selection.formIntersection(visible)
    #expect(selection == Set(visible))
    #expect(ledger.rowTotals(of: selection).myExpenses == .zero)
    #expect(ledger.rowTotals(of: selection).income == ledger.rowTotals(of: visible).income)
  }

  /// Days before the first operation are not counted as days without spending.
  @Test func weekdaysCountOnlyDaysTheHistoryCovers() {
    var sketch = Sketch()
    sketch.expense("2026-09-14", "700")
    let profile = WeekdayProfile(
      ledger: sketch.ledger, period: .month(MonthKey(year: 2026, month: 9)),
      today: day("2026-09-20"))
    #expect(profile.interval == DayRange(day("2026-09-14"), day("2026-09-20")))
    #expect(profile.days.map(\.occurrences) == [1, 1, 1, 1, 1, 1, 1])
    #expect(profile.days[0].average == money("700"))
  }
}
