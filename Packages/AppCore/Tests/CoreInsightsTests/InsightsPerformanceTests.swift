import CoreAccounting
import CoreAnalytics
import CoreKit
import CorePlanning
import CoreSample
import Foundation
import Testing

@testable import CoreInsights
@testable import CoreModel

/// The time budgets of the category model and the anomalies on the large synthetic set —
/// about 20 000 operations over two years. Only `make bench` runs these: a debug build says
/// nothing about a millisecond target, and `make verify` must not wait on them.
///
/// The budgets were fixed up front, not fitted to a run. A build that misses one is not slow
/// by accident — something started doing work per operation that used to be done once.
@Suite("Time budgets of the model and the anomalies", .serialized, .enabled(if: InsightsBench.isOn))
struct InsightsPerformanceTests {
  static let calendar = CalendarContext.moscow
  static let set = SampleDataGenerator(seed: 20_260_918).generate(
    months: SampleDataGenerator.largeSetMonths,
    endingOn: DateOnly(year: 2026, month: 9, day: 18), calendar: calendar, language: "en",
    density: SampleDataGenerator.largeSetDensity)
  static let dataset = Dataset(
    entries: set.entries, links: set.links, categories: set.categories, people: set.people,
    places: set.places, events: set.events, paymentMethods: set.paymentMethods,
    debts: set.debts, goals: set.goals, planning: set.planningBook,
    settings: AnalyticsSettings(cashbackCategoryId: set.cashbackCategoryId))

  @Test func preparingTheExamples() {
    var count = 0
    let times = InsightsBench.measure("model examples, \(Self.dataset.entries.count) operations") {
      count = LedgerTraining.examples(of: Self.dataset, calendar: Self.calendar).count
    }
    #expect(count > 0)
    #expect(times.median < .milliseconds(150))
  }

  @Test func trainingFromNothing() {
    let examples = LedgerTraining.examples(of: Self.dataset, calendar: Self.calendar)
    let anchor = Self.set.lastDay
    var classes = 0
    let times = InsightsBench.measure("model training, \(examples.count) examples") {
      classes = CategoryModel.train(on: examples, anchor: anchor).readiness.isOn ? 1 : 0
    }
    #expect(classes == 1, "the large set does not turn the model on")
    #expect(times.median < .milliseconds(400))
  }

  /// One suggestion, and one correction — `unlearn` plus `learn`, which is what the entry
  /// line does when the owner picks another category.
  @Test func askingAndCorrecting() {
    let examples = LedgerTraining.examples(of: Self.dataset, calendar: Self.calendar)
    let anchor = Self.set.lastDay
    let model = CategoryModel.train(on: examples, anchor: anchor)
    let candidates = Self.dataset.categories.filter { $0.kind == .expense }.map(\.id)
    guard let example = examples.last else { return #expect(Bool(false), "no examples") }

    let asked = InsightsBench.measure("model prediction", runs: 101) {
      _ = model.predict(example.query, among: candidates)
    }
    #expect(asked.median < .milliseconds(5))

    var corrected = model
    let fixing = InsightsBench.measure("model correction", runs: 101) {
      corrected.unlearn(example)
      corrected.learn(example)
    }
    #expect(fixing.median < .milliseconds(20))
  }

  /// «Качество модели» is not a step of the pipeline: it is measured when the section is
  /// opened, which is why it may take longer than a step — but not longer than a page of a
  /// report reasonably can.
  @Test func theModelQualityReport() {
    let ledger = Ledger(dataset: Self.dataset, calendar: Self.calendar)
    let today = Self.set.lastDay
    var examples = 0
    let times = InsightsBench.measure("model quality, both halves", runs: 3) {
      examples = ModelQuality.build(ledger: ledger, today: today).categories.examples
    }
    #expect(examples > 0)
    #expect(times.median < .milliseconds(3_000))
  }

  @Test func theBacktestAlone() {
    let ledger = Ledger(dataset: Self.dataset, calendar: Self.calendar)
    let today = Self.set.lastDay
    var origins = 0
    let times = InsightsBench.measure("forecast backtest, 180 origins") {
      origins = ForecastBacktest.run(ledger: ledger, today: today).lines.first?.metrics.origins ?? 0
    }
    #expect(origins > 0)
    #expect(times.median < .milliseconds(1_000))
  }

  @Test func theSevenRules() {
    let ledger = Ledger(dataset: Self.dataset, calendar: Self.calendar)
    let today = Self.set.lastDay
    let events = EventPlanning.build(ledger: ledger, today: today)
    var found = -1
    let times = InsightsBench.measure("anomalies, seven rules, \(ledger.rows.count) rows") {
      found = AnomalyRules.build(ledger: ledger, events: events, today: today).all.count
    }
    #expect(found >= 0)
    #expect(times.median < .milliseconds(250))
  }
}

/// The same five runs and one warm-up as `CoreAnalyticsTests`; copied rather than shared
/// because a test target cannot import another one.
enum InsightsBench {
  static var isOn: Bool { ProcessInfo.processInfo.environment["OHMYMONEY_BENCH"] == "1" }

  struct Times {
    let median: Duration
    let max: Duration
  }

  @discardableResult
  static func measure(_ label: String, runs: Int = 5, _ work: () -> Void) -> Times {
    work()
    let clock = ContinuousClock()
    var times = (0..<runs).map { _ in clock.measure(work) }
    times.sort()
    let result = Times(median: times[runs / 2], max: times[runs - 1])
    print("bench · \(label): median \(text(result.median)), max \(text(result.max))")
    return result
  }

  /// Milliseconds with one decimal, in integers only.
  static func text(_ duration: Duration) -> String {
    let (seconds, attoseconds) = duration.components
    let tenths = seconds * 10_000 + attoseconds / 100_000_000_000_000
    return "\(tenths / 10).\(tenths % 10) ms"
  }
}
