import CoreKit
import CorePlanning
import CoreSample
import Foundation
import Testing

@testable import CoreAnalytics

/// What planning costs on the large synthetic set, with its payments, limits and expected
/// income. The planning snapshot is rebuilt with the data after every write, so it has to
/// stay small next to the ledger itself; the suggestions are counted once per run. Only
/// `make bench` runs it, like the other measurements.
@Suite("Performance of planning", .serialized, .enabled(if: Bench.isOn))
struct PlanningPerformanceTests {
  static let set = PerformanceTests.set

  static var dataset: Dataset {
    var dataset = PerformanceTests.dataset
    dataset.planning = set.planningBook
    return dataset
  }

  @Test func thePlanningSnapshot() {
    let ledger = Ledger(dataset: Self.dataset, calendar: Synthetic.calendar)
    let today = Self.set.lastDay
    var payments = 0
    let times = Bench.measure("planning snapshot, \(ledger.dataset.entries.count) operations") {
      payments =
        PlanningSnapshot.build(ledger: ledger, today: today, now: Date(), rubPerUnit: [:])
        .scheduled.count
    }
    #expect(payments > 0)
    #expect(times.median < .milliseconds(150))
  }

  /// The plan of every balance through the end of the month is built with the data after every
  /// write, next to the planning snapshot: it has to stay small beside it, and laying the
  /// forecast over it is a few multiplications.
  @Test func theAccountPlan() {
    let ledger = Ledger(dataset: Self.dataset, calendar: Synthetic.calendar)
    let today = Self.set.lastDay
    let planning = PlanningSnapshot.build(
      ledger: ledger, today: today, now: Date(), rubPerUnit: [:])
    let remainder = MonthForecast.remainder(ledger: ledger, today: today)
    var pairs = 0
    let times = Bench.measure("account plan, \(ledger.dataset.entries.count) operations") {
      pairs =
        AccountMonthPlan.build(ledger: ledger, planning: planning)
        .forecast(remainder: remainder).sections.flatMap(\.lines).count
    }
    #expect(pairs >= 0)
    #expect(times.median < .milliseconds(60))
  }

  @Test func theSuggestions() {
    let ledger = Ledger(dataset: Self.dataset, calendar: Synthetic.calendar)
    let today = Self.set.lastDay
    let planning = PlanningSnapshot.build(
      ledger: ledger, today: today, now: Date(), rubPerUnit: [:])
    let remainder = MonthForecast.remainder(ledger: ledger, today: today)
    var count = 0
    let times = Bench.measure("advice, every rule") {
      count =
        AdviceBook.build(planning: planning, ledger: ledger, remainder: remainder, today: today)
        .items.count
    }
    #expect(count > 0)
    #expect(times.median < .milliseconds(500))
  }
}
