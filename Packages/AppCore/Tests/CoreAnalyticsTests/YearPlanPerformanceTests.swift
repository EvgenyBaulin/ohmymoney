import CoreKit
import CorePlanning
import CoreSample
import Foundation
import Testing

@testable import CoreAnalytics

/// What the year plan costs on the large synthetic set. The history is read from the ledger
/// once per recompute; the seasonality, the forecast of the year and the plan itself are
/// arithmetic on the small tables that come out of it and have to stay far below the ledger
/// read. Only `make bench` runs it, like the other measurements.
@Suite("Performance of the year plan", .serialized, .enabled(if: Bench.isOn))
struct YearPlanPerformanceTests {
  static var dataset: Dataset {
    var dataset = PerformanceTests.dataset
    dataset.planning = PerformanceTests.set.planningBook
    return dataset
  }

  @Test func theHistoryRead() {
    let ledger = Ledger(dataset: Self.dataset, calendar: Synthetic.calendar)
    let today = PerformanceTests.set.lastDay
    var months = 0
    let times = Bench.measure("spending history, \(ledger.dataset.entries.count) operations") {
      months = SpendingHistory(ledger: ledger, today: today).completeMonths().count
    }
    #expect(months > 0)
    #expect(times.median < .milliseconds(150))
  }

  @Test func theSeasonalityForecastAndPlan() {
    let ledger = Ledger(dataset: Self.dataset, calendar: Synthetic.calendar)
    let today = PerformanceTests.set.lastDay
    let history = SpendingHistory(ledger: ledger, today: today)
    let planning = PlanningSnapshot.build(
      ledger: ledger, today: today, now: Date(), rubPerUnit: [:])
    var cells = 0
    let times = Bench.measure("year plan with seasons and forecast") {
      _ = Seasonality.ofTotal(history: history)
      let forecast = YearForecast.build(history: history, from: today.monthKey)
      let expected = ExpectedIncomeRules.statuses(
        book: ledger.dataset.planning, ledger: ledger, today: today, rubPerUnit: [:],
        through: today.monthKey.adding(months: 11).lastDay)
      let plan = YearPlan.build(
        window: .rolling(from: today.monthKey), today: today,
        inputs: YearPlan.Inputs(
          scheduled: ledger.dataset.planning.scheduled, prices: ledger.dataset.planning.prices,
          expected: expected, goals: planning.goals))
      cells = plan.rows.reduce(0) { $0 + $1.cells.count } + forecast.categories.count
    }
    #expect(cells > 0)
    #expect(times.median < .milliseconds(60))
  }
}
