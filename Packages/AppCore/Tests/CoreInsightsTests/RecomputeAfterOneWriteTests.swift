import CoreAccounting
import CoreKit
import CorePlanning
import CoreSample
import Foundation
import Testing

@testable import CoreAnalytics
@testable import CoreInsights
@testable import CoreModel

/// What a write costs the numbers: after one operation is saved on the large synthetic set —
/// about 20 000 operations over two years — the figures built from the ledger are brought up to
/// date from the ones before, and must equal a build from nothing. The budget is 0.3 s in
/// release. Only `make bench` runs the stopwatch (`OHMYMONEY_BENCH=1`); the equality is checked
/// every time, on a smaller set.
@Suite("Recompute after one write")
struct RecomputeAfterOneWriteTests {
  static let calendar = CalendarContext.moscow
  static let today = DateOnly(year: 2026, month: 9, day: 18)

  static func dataset(months: Int, density: Int) -> (set: SampleDataSet, data: Dataset) {
    let set = SampleDataGenerator(seed: 20_260_918).generate(
      months: months, endingOn: today, calendar: calendar, language: "en", density: density)
    let data = Dataset(
      entries: set.entries, links: set.links, categories: set.categories, people: set.people,
      places: set.places, events: set.events, paymentMethods: set.paymentMethods,
      debts: set.debts, goals: set.goals, planning: set.planningBook,
      settings: AnalyticsSettings(cashbackCategoryId: set.cashbackCategoryId))
    return (set, data)
  }

  /// One purchase more, today, like the one before it — a few words, one part.
  static func oneWrite(on data: Dataset) -> Dataset {
    guard
      var entry = data.entries.last(where: {
        $0.transaction.kind == .expense && $0.transaction.externalId == nil
          && $0.parts.allSatisfy { $0.qualitySource != .manual && $0.refundOfPartId == nil }
      })
    else { return data }
    entry.transaction.id = UUID()
    entry.transaction.occurredAt = calendar.startOfDay(today).addingTimeInterval(11 * 3_600)
    for index in entry.parts.indices {
      entry.parts[index].id = UUID()
      entry.parts[index].transactionId = entry.transaction.id
    }
    return data.upserting([entry])
  }

  /// The state the pipeline holds between writes, and the step that brings it to the next.
  struct Figures {
    var ledger: Ledger
    var summary: OverviewSummary
    var planning: PlanningSnapshot
    var accountPlan: AccountMonthPlan
    var examples: [CategoryExample]
    var model: CategoryModel
    var remainder: MonthForecast.Remainder
    var anomalies: AnomalyReport
    var advice: AdviceReport

    /// From nothing: what the first run of the app does.
    static func built(from data: Dataset, today: DateOnly) -> Figures {
      let ledger = Ledger(dataset: data, calendar: calendar)
      let examples = LedgerTraining.examples(of: ledger)
      return Figures(
        ledger: ledger, examples: examples,
        model: CategoryModel.train(on: examples, anchor: today), today: today)
    }

    /// The same figures over `ledger` and the model given.
    init(
      ledger: Ledger, examples: [CategoryExample], model: CategoryModel, today: DateOnly
    ) {
      self.ledger = ledger
      self.examples = examples
      self.model = model
      summary = OverviewSummary(ledger: ledger, today: today)
      planning = PlanningSnapshot.build(
        ledger: ledger, today: today, now: calendar.startOfDay(today).addingTimeInterval(43_200),
        rubPerUnit: [:])
      accountPlan = AccountMonthPlan.build(ledger: ledger, planning: planning)
      remainder = MonthForecast.remainder(
        ledger: ledger, today: today, scheduledOperations: planning.matches.operationIds)
      anomalies = AnomalyRules.build(
        ledger: ledger, events: planning.events, today: today,
        dismissals: ledger.dataset.dismissals,
        options: .standard(ledger.dataset.settings.anomalySensitivity))
      advice = AdviceBook.build(
        planning: planning, ledger: ledger, remainder: remainder, today: today)
    }

    /// After a write: the ledger and the model brought up to date from the ones held, the rest
    /// worked out over them.
    func afterWrite(_ data: Dataset, today: DateOnly) -> Figures {
      let next = ledger.updated(to: data)
      let examples = LedgerTraining.examples(of: next, since: ledger, examples: self.examples)
      var model = self.model
      let byPart = { (list: [CategoryExample]) in
        Dictionary(uniqueKeysWithValues: list.map { ($0.partId, $0) })
      }
      if !model.catchUp(from: byPart(self.examples), to: byPart(examples), limit: 256) {
        model = CategoryModel.train(on: examples, anchor: today)
      }
      return Figures(ledger: next, examples: examples, model: model, today: today)
    }
  }

  /// The examples from a ledger are those from its dataset: the ledger only lends its index.
  @Test func examplesFromALedgerAreExamplesFromItsDataset() {
    let (_, data) = Self.dataset(months: 6, density: 1)
    let ledger = Ledger(dataset: data, calendar: Self.calendar)
    #expect(
      LedgerTraining.examples(of: ledger)
        == LedgerTraining.examples(of: data, calendar: Self.calendar))
  }

  /// The examples worked out from the ones before are the same examples, in any order: after a
  /// written, an edited, a refiled and a removed operation in turn, and for a ledger built whole.
  @Test func examplesFollowTheOperationsThatChanged() throws {
    let (_, data) = Self.dataset(months: 6, density: 1)
    var ledger = Ledger(dataset: data, calendar: Self.calendar)
    var examples = LedgerTraining.examples(of: ledger)
    var current = data
    func sorted(_ list: [CategoryExample]) -> [String] {
      list.map { "\($0.partId.uuidString) \($0.categoryId.uuidString) \($0.query.text)" }.sorted()
    }

    let plain = current.entries.filter {
      $0.transaction.kind == .expense && $0.transaction.externalId == nil
        && $0.parts.allSatisfy { $0.qualitySource != .manual && $0.refundOfPartId == nil }
    }
    let other = try #require(
      current.categories.first { $0.kind == .expense && $0.systemRole == nil })
    var steps: [(String, (Dataset) -> Dataset)] = [
      ("written", { Self.oneWrite(on: $0) }),
      (
        "refiled",
        { data in
          var entry = plain[plain.count / 2]
          entry.parts[0].categoryId = other.id
          entry.parts[0].categorySource = .manual
          entry.parts[0].note = "a new note"
          return data.upserting([entry])
        }
      ),
      ("removed", { $0.removing([plain[plain.count / 3].id]) }),
    ]
    steps.append(("written again", { Self.oneWrite(on: $0) }))
    for (name, step) in steps {
      current = step(current)
      let next = ledger.updated(to: current)
      #expect(next.change?.parent == ledger.identity, "\(name) is worked out from the one before")
      examples = LedgerTraining.examples(of: next, since: ledger, examples: examples)
      #expect(
        sorted(examples) == sorted(LedgerTraining.examples(of: current, calendar: Self.calendar)),
        "\(name)")
      ledger = next
    }
    // A ledger built whole is no child of the one before: the whole pass.
    let whole = Ledger(dataset: current, calendar: Self.calendar)
    #expect(
      sorted(LedgerTraining.examples(of: whole, since: ledger, examples: []))
        == sorted(examples))
  }

  @Test func theFiguresAfterAWriteEqualAFullBuild() {
    let (_, data) = Self.dataset(months: 6, density: 1)
    let held = Figures.built(from: data, today: Self.today)
    let next = Self.oneWrite(on: data)
    #expect(next.entries.count == data.entries.count + 1)
    #expect(held.ledger.delta(to: next) != nil, "the write takes the quick path")

    let quick = held.afterWrite(next, today: Self.today)
    let full = Figures.built(from: next, today: Self.today)

    #expect(quick.ledger.rows == full.ledger.rows)
    #expect(quick.model == full.model)
    #expect(quick.summary == full.summary)
    #expect(quick.planning == full.planning)
    #expect(quick.accountPlan == full.accountPlan)
    #expect(quick.remainder == full.remainder)
    #expect(quick.anomalies == full.anomalies)
    #expect(quick.advice == full.advice)
  }
}

/// The budget of one write on the large set — only `make bench` runs it (`OHMYMONEY_BENCH=1`);
/// the name carries «Performance» because that is what the bench target filters on.
@Suite("Recompute after one write, time budget", .serialized, .enabled(if: InsightsBench.isOn))
struct RecomputePerformanceTests {
  @Test
  func theBudgetOfOneWriteOnTheLargeSet() {
    let (_, data) = RecomputeAfterOneWriteTests.dataset(
      months: SampleDataGenerator.largeSetMonths, density: SampleDataGenerator.largeSetDensity)
    let held = RecomputeAfterOneWriteTests.Figures.built(
      from: data, today: RecomputeAfterOneWriteTests.today)
    let next = RecomputeAfterOneWriteTests.oneWrite(on: data)
    var rows = 0
    let quick = InsightsBench.measure("recompute after one write, \(data.entries.count) operations")
    {
      rows = held.afterWrite(next, today: RecomputeAfterOneWriteTests.today).ledger.rows.count
    }
    InsightsBench.measure("recompute from nothing, \(data.entries.count) operations") {
      rows =
        RecomputeAfterOneWriteTests.Figures.built(
          from: next, today: RecomputeAfterOneWriteTests.today
        ).ledger.rows.count
    }
    #expect(rows > 0)
    #expect(quick.median < .milliseconds(300))
  }
}
