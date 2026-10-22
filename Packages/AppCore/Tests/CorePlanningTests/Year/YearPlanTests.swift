import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CorePlanning

@Suite("The plan of the year agrees with the payments, income, goals and events of its months")
struct YearPlanTests {
  typealias Fx = CashFx

  static let today = Fx.today  // 2026-09-19
  static let window = YearWindow.rolling(from: today.monthKey)

  /// A book with rent, a salary, a goal and an event, and the inputs the plan reads from it.
  static func inputs(_ fx: CashFx) -> YearPlan.Inputs {
    let ledger = fx.ledger
    let end = Fx.day("2027-08-31")
    let expected = ExpectedIncomeRules.statuses(
      book: fx.book, ledger: ledger, today: today, rubPerUnit: fx.rubPerUnit, through: end)
    let goals = GoalRules.statuses(
      goals: fx.goals, ledger: ledger, today: today, rubPerUnit: fx.rubPerUnit)
    let events = EventPlanning.plans(ledger: ledger, today: today)
    let months = (0..<6).map { today.monthKey.adding(months: -$0 - 1) }
    var income: [MonthKey: AmountE4] = [:]
    for month in months { income[month] = ledger.income(attributedTo: [month]) }
    return YearPlan.Inputs(
      scheduled: fx.scheduled, prices: fx.prices, expected: expected, goals: goals, events: events,
      incomeByMonth: income, historyStart: IncomeEstimate.historyStart(firstDay: ledger.firstDay),
      receivedThisMonth: ledger.income(attributedTo: [today.monthKey], notAfter: today),
      rubPerUnit: fx.rubPerUnit)
  }

  static var book: CashFx {
    var fx = Fx()
    fx.count([(Fx.main, .rub, "100000")], at: Fx.at("2026-09-01", 9))
    fx.scheduled = [Fx.payment(1, "Rent", "30000", day: 5, next: "2026-10-05")]
    fx.expected = [
      ExpectedIncome(
        id: Fx.id(611), name: "Salary", categoryId: Fx.salary, kind: .recurring,
        totalE4: Fx.money("100000"), dueDate: Fx.day("2026-01-10"), freq: .monthly, day: 10)
    ]
    fx.goals = [
      Goal(
        id: Fx.id(700), name: "Trip", targetE4: Fx.money("120000"),
        targetDate: Fx.day("2027-02-20"), monthlyPlanE4: Fx.money("10000"))
    ]
    fx.events = [
      Event(
        id: Fx.id(701), name: "Move", startDate: Fx.day("2027-03-01"),
        endDate: Fx.day("2027-03-10"), budgetE4: Fx.money("50000"))
    ]
    return fx
  }

  @Test func everyRowAddsUpToItsSources() throws {
    let plan = YearPlan.build(
      window: Self.window, today: Self.today, inputs: Self.inputs(Self.book))
    #expect(plan.months.count == 12 && plan.months.first == MonthKey(year: 2026, month: 9))
    // Rent from October through August: 11 due dates.
    let payments = try #require(plan.row(.payments))
    #expect(payments.total == Fx.money("330000"))
    #expect(plan.cell(.payments, MonthKey(year: 2026, month: 9))?.items.isEmpty == true)
    let october = try #require(plan.cell(.payments, MonthKey(year: 2026, month: 10)))
    #expect(
      october.items.first?.sourceId == Fx.id(1) && october.items.first?.day == Fx.day("2026-10-05"))
    // The salary: September's is overdue and still waited for, so twelve times 100 000, none a guess.
    let income = try #require(plan.row(.income))
    #expect(income.total == Fx.money("1200000"))
    #expect(
      income.cells.allSatisfy { !$0.isEstimate && $0.items.allSatisfy { $0.state == .planned } })
    // The goal: ten thousand a month from September through February.
    let goals = try #require(plan.row(.goals))
    #expect(goals.total == Fx.money("60000"))
    #expect(plan.cell(.goals, MonthKey(year: 2027, month: 3))?.items.isEmpty == true)
    #expect(plan.cell(.goals, MonthKey(year: 2027, month: 2))?.total == Fx.money("10000"))
    // The event: its budget in the month it starts.
    #expect(plan.cell(.bigSpends, MonthKey(year: 2027, month: 3))?.total == Fx.money("50000"))
    #expect(plan.row(.bigSpends)?.total == Fx.money("50000"))
    for month in plan.months {
      let parts = YearPlanRowKind.allCases.map { plan.cell($0, month)?.total ?? .zero }
      #expect(plan.balance[month] == parts[0] - parts[1] - parts[2] - parts[3])
    }
    #expect(plan.withoutRate.isEmpty)
  }

  @Test func theMonthsMatchThePlanningOfTheSameMonths() {
    // The same payments, month by month, as the account plan counts them through each month's end.
    let fx = Self.book
    let plan = YearPlan.build(window: Self.window, today: Self.today, inputs: Self.inputs(fx))
    var running = AmountE4.zero
    for month in plan.months {
      running += plan.cell(.payments, month)?.total ?? .zero
      let through = fx.plan(until: month.lastDay.iso)
      #expect(through.scheduled == running)
    }
  }

  @Test func incomeWithoutAnExpectationIsAGuessFromTheMedianOfSixMonths() throws {
    var fx = Fx()
    fx.count([(Fx.main, .rub, "100000")], at: Fx.at("2026-02-01", 9))
    for (index, amount) in ["60000", "80000", "80000", "90000", "100000", "70000"].enumerated() {
      fx.add(.income, amount, at: Fx.at("2026-0\(index + 3)-01", 10), category: Fx.salary)
    }
    let plan = YearPlan.build(window: Self.window, today: Self.today, inputs: Self.inputs(fx))
    let income = try #require(plan.row(.income))
    // Median of 60, 70, 80, 80, 90, 100 thousand is 80 000.
    #expect(income.cells.allSatisfy { $0.total == Fx.money("80000") && $0.isEstimate })
    #expect(income.cells.allSatisfy { $0.items.first?.state == .estimate })
    #expect(plan.balance[MonthKey(year: 2027, month: 1)] == Fx.money("80000"))
  }

  @Test func whatCameThisMonthCountsAndTheGuessFillsUpToIt() throws {
    var fx = Fx()
    fx.count([(Fx.main, .rub, "100000")], at: Fx.at("2026-02-01", 9))
    for month in 3...8 {
      fx.add(.income, "80000", at: Fx.at("2026-0\(month)-01", 10), category: Fx.salary)
    }
    fx.add(.income, "30000", at: Fx.at("2026-09-05", 10), category: Fx.salary)
    let plan = YearPlan.build(window: Self.window, today: Self.today, inputs: Self.inputs(fx))
    let september = try #require(plan.cell(.income, MonthKey(year: 2026, month: 9)))
    #expect(Set(september.items.map(\.state)) == [.received, .estimate])
    #expect(september.items.count == 2)
    #expect(september.total == Fx.money("80000"))
  }

  @Test func aYearWithAnEmptyBookIsEmpty() {
    let plan = YearPlan.build(window: Self.window, today: Self.today, inputs: YearPlan.Inputs())
    #expect(plan.rows.allSatisfy { $0.total == .zero })
    #expect(plan.balance.values.allSatisfy { $0 == .zero })
  }

  @Test func theCalendarYearLeavesPastMonthsEmpty() {
    let plan = YearPlan.build(
      window: .calendar(year: 2026), today: Self.today, inputs: Self.inputs(Self.book))
    #expect(plan.months.first == MonthKey(year: 2026, month: 1) && plan.months.count == 12)
    #expect(
      (1...8).allSatisfy { month in
        YearPlanRowKind.allCases.allSatisfy {
          plan.cell($0, MonthKey(year: 2026, month: month))?.items.isEmpty == true
        }
      })
    // Rent from October through December.
    #expect(plan.row(.payments)?.total == Fx.money("90000"))
  }

  @Test func aPaymentInADollarWithoutARateIsListedNotGuessed() {
    var fx = Self.book
    fx.scheduled.append(Fx.payment(4, "Domain", "20", day: 23, next: "2026-10-23", currency: .eur))
    let plan = YearPlan.build(window: Self.window, today: Self.today, inputs: Self.inputs(fx))
    #expect(plan.withoutRate == [Fx.id(4)])
    #expect(plan.row(.payments)?.total == Fx.money("330000"))
  }

  @Test func aGoalNeverTakesMoreThanItStillNeeds() throws {
    var fx = Self.book
    fx.goals = [
      Goal(
        id: Fx.id(700), name: "Trip", targetE4: Fx.money("25000"),
        targetDate: Fx.day("2027-02-20"), monthlyPlanE4: Fx.money("10000"))
    ]
    let plan = YearPlan.build(window: Self.window, today: Self.today, inputs: Self.inputs(fx))
    let goals = try #require(plan.row(.goals))
    #expect(goals.total == Fx.money("25000"))
    #expect(
      goals.cells.prefix(3).map(\.total) == [
        Fx.money("10000"), Fx.money("10000"), Fx.money("5000"),
      ])
  }

  @Test func addingToAMonthOffersTheFourKindsAndAUsefulDay() {
    let plan = YearPlan.build(window: Self.window, today: Self.today, inputs: YearPlan.Inputs())
    let now = plan.addActions(for: Self.today.monthKey, today: Self.today)
    #expect(now.suggestedDay == Self.today && now.actions.count == 4)
    #expect(
      plan.addActions(for: MonthKey(year: 2027, month: 2), today: Self.today).suggestedDay
        == Fx.day("2027-02-01"))
  }
}

@Suite("The history of spending from a ledger")
struct SpendingHistoryLedgerTests {
  typealias Fx = CashFx

  /// Two years of groceries, December twice as dear, and a goal contribution that is not spending.
  @Test func decemberIsFoundInALedger() throws {
    var fx = Fx()
    fx.count([(Fx.main, .rub, "1000000")], at: Fx.at("2024-09-01", 8))
    var month = MonthKey(year: 2024, month: 9)
    while month <= MonthKey(year: 2026, month: 8) {
      let amount = month.month == 12 ? "20000" : "10000"
      fx.add(.expense, amount, at: Fx.at(month.firstDay.iso, 12))
      month = month.next
    }
    fx.add(.expense, "5000", at: Fx.at("2025-05-10", 12), category: Fx.tripGoal, goal: Fx.id(900))
    let history = SpendingHistory(ledger: fx.ledger, today: Fx.today)
    #expect(history.lastCompleteMonth == MonthKey(year: 2026, month: 8))
    #expect(history.firstMonth == MonthKey(year: 2024, month: 9))
    #expect(history.total[MonthKey(year: 2025, month: 5)] == Fx.money("10000"))
    #expect(history.series(of: Fx.groceries)[MonthKey(year: 2025, month: 12)] == Fx.money("20000"))
    let seasonality = try #require(Seasonality.ofTotal(history: history).seasonality)
    #expect(seasonality.basis == .twoYears)
    #expect(seasonality.expensiveMonths.map(\.month) == [12])
    // The current month is not complete and stays out.
    fx.add(.expense, "777", at: Fx.at("2026-09-02", 12))
    #expect(
      SpendingHistory(ledger: fx.ledger, today: Fx.today).total[MonthKey(year: 2026, month: 9)]
        == nil)
  }

  @Test func theForecastFromALedgerKeepsTheSeason() throws {
    var fx = Fx()
    fx.count([(Fx.main, .rub, "1000000")], at: Fx.at("2024-09-01", 8))
    var month = MonthKey(year: 2024, month: 9)
    while month <= MonthKey(year: 2026, month: 8) {
      fx.add(.expense, month.month == 12 ? "20000" : "10000", at: Fx.at(month.firstDay.iso, 12))
      month = month.next
    }
    let history = SpendingHistory(ledger: fx.ledger, today: Fx.today)
    let forecast = YearForecast.build(history: history, from: MonthKey(year: 2026, month: 9))
    let row = try #require(forecast.category(Fx.groceries))
    #expect(
      row.months[3].month == MonthKey(year: 2026, month: 12)
        && row.months[3].usual == Fx.money("20000"))
    #expect(row.months[0].usual == Fx.money("10000"))
    #expect(forecast.usualTotal == Fx.money("130000"))
  }
}
