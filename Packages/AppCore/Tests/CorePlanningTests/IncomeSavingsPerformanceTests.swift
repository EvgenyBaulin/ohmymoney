import CoreAnalytics
import CoreKit
import CoreSample
import Foundation
import Testing

@testable import CorePlanning

/// What «Доход и сбережения» costs on the large synthetic set (about 20 000 operations over two
/// years). The plan fixes no figure of its own, so the budgets follow the neighbouring
/// calculations of the planning book: each figure well under the 150 ms of the planning
/// snapshot, since the Analytics section works all of them out at once on every recompute. Only
/// `make bench` runs these (release build, `OHMYMONEY_BENCH=1`).
@Suite(
  "Performance of income and savings", .serialized,
  .enabled(if: ProcessInfo.processInfo.environment["OHMYMONEY_BENCH"] == "1"))
struct IncomeSavingsPerformanceTests {
  static let calendar = CalendarContext.moscow
  static let set = SampleDataGenerator(seed: 20_260_918).generate(
    months: SampleDataGenerator.largeSetMonths,
    endingOn: DateOnly(year: 2026, month: 9, day: 18), calendar: calendar, language: "en",
    density: SampleDataGenerator.largeSetDensity)
  static let ledger = Ledger(
    dataset: Dataset(
      entries: set.entries, links: set.links, categories: set.categories, people: set.people,
      places: set.places, events: set.events, paymentMethods: set.paymentMethods,
      debts: set.debts, goals: set.goals, planning: set.planningBook,
      settings: AnalyticsSettings(cashbackCategoryId: set.cashbackCategoryId)),
    calendar: calendar)
  static let today = set.lastDay

  static func measure(_ label: String, runs: Int = 5, _ work: () -> Void) -> Duration {
    work()
    let clock = ContinuousClock()
    var times = (0..<runs).map { _ in clock.measure(work) }
    times.sort()
    let median = times[runs / 2]
    print("bench · \(label): median \(median)")
    return median
  }

  @Test func theSavingsRateByMonth() {
    var months = 0
    let median = Self.measure("savings rate, 24 months, \(Self.ledger.rows.count) rows") {
      months = SavingsNorm.series(count: 24, ledger: Self.ledger, today: Self.today).count
    }
    #expect(months >= 12)
    #expect(median < .milliseconds(100))
  }

  @Test func theBasketsOfAMonth() {
    let month = Self.today.monthKey.previous
    let income = Self.ledger.income(attributedTo: [month])
    var lines = 0
    let median = Self.measure("budget baskets, one month") {
      lines =
        BudgetBaskets.fit(
          month: month, ledger: Self.ledger, today: Self.today, income: income,
          proportions: .rule503020
        ).lines.count
    }
    #expect(lines == 3)
    #expect(median < .milliseconds(50))
  }

  @Test func theStabilityAndTheTrend() {
    var state = IncomeStability.State.notEnoughData(months: 0)
    var trend = SpendingFollowsIncome.State.notEnoughData
    let median = Self.measure("income stability and spending trend") {
      state = IncomeStability.build(ledger: Self.ledger, before: Self.today.monthKey).state
      trend = SpendingFollowsIncome.build(ledger: Self.ledger, today: Self.today).state
    }
    #expect(state == .ready)
    #expect(trend == .ready)
    #expect(median < .milliseconds(150))
  }

  @Test func theSalaryEffect() {
    let median = Self.measure("salary effect") {
      _ = SalaryEffect.build(ledger: Self.ledger, statuses: [], today: Self.today)
    }
    #expect(median < .milliseconds(100))
  }

  /// The history of the health over the whole two years: twenty-four recomputations.
  @Test func theHealthHistory() {
    let months = MonthKey.range(
      Self.today.monthKey.adding(months: -23), through: Self.today.monthKey)
    var points = 0
    let median = Self.measure("financial health history, 24 months") {
      points =
        FinancialHealth.series(months: months) { month in
          let parts = FinancialHealth.ledgerParts(ledger: Self.ledger, asOf: month)
          return HealthInputs(
            cushionMonths: 3, debtLoad: nil, savingsRateBp: parts.savingsRateBp,
            overdueCount: 0, stability: parts.stability)
        }.count
    }
    #expect(points == 24)
    #expect(median < .milliseconds(500))
  }
}
