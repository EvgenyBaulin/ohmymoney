import CoreAccounting
import CoreKit
import CoreSample
import Foundation
import Testing

@testable import CoreAnalytics

/// How long the numbers take on the large synthetic set: about 20 000 operations over two
/// years. Only `make bench` runs it — in release, with `OHMYMONEY_BENCH=1`; `make test-core` and
/// `make verify` skip it, since a debug build says nothing about the 500 ms target.
/// Serialized, so one measurement never shares the machine with another. Each measurement is
/// one warm-up and five runs; the output carries times and counts only, never an amount.
@Suite("Performance", .serialized, .enabled(if: Bench.isOn))
struct PerformanceTests {
  static let set = SampleDataGenerator(seed: 20_260_918).generate(
    months: SampleDataGenerator.largeSetMonths, endingOn: Synthetic.endingOn,
    calendar: Synthetic.calendar, language: "en",
    density: SampleDataGenerator.largeSetDensity)
  static let dataset = Synthetic.dataset(set)

  @Test func buildingTheLedger() {
    let dataset = Self.dataset
    var rows = 0
    let times = Bench.measure("ledger build, \(dataset.entries.count) operations") {
      rows = Ledger(dataset: dataset, calendar: Synthetic.calendar).rows.count
    }
    #expect(rows > dataset.entries.count)
    #expect(times.median < .milliseconds(500))
  }

  /// The money on every account and currency — the latest count of each and every movement
  /// after it — on the large set with its accounts, as the snapshot works it out after every
  /// change: one pass over the operations, the transfers and the journals. The target is under
  /// 50 ms.
  @Test func buildingTheBalancesOfTheAccounts() {
    let set = Self.set.withAccounts(
      seed: 20_260_918, calendar: Synthetic.calendar, language: "en")
    let debts = Dictionary(uniqueKeysWithValues: set.debts.map { ($0.id, $0) })
    let tree = CategoryTree(set.categories)
    let now = Synthetic.calendar.startOfDay(Synthetic.calendar.adding(days: 1, to: set.lastDay))
    var keys = 0
    let times = Bench.measure(
      "account balances, \(set.entries.count) operations, \(set.transfers.count) transfers"
    ) {
      keys =
        AccountBalances.build(
          entries: set.entries, transfers: set.transfers, debtEntries: set.debtEntries,
          debts: debts, reconciliations: set.reconciliations, balances: set.reconciledBalances,
          accounts: set.paymentMethods, tree: tree, now: now, calendar: Synthetic.calendar
        ).keys.count
    }
    #expect(keys == set.accountExpectations.count)
    #expect(times.median < .milliseconds(50))
  }

  /// Every slice the Analytics window shows for the last twelve months, from a built
  /// ledger — what a change of period costs. The target is under 500 ms.
  @Test func everyAnalyticsSectionForTwelveMonths() {
    let ledger = Ledger(dataset: Self.dataset, calendar: Synthetic.calendar)
    let today = Self.set.lastDay
    let period = Period.twelveMonths(endingWith: today.monthKey)
    var checksum: Int64 = 0
    let times = Bench.measure("analytics, every section, 12 months") {
      checksum = AnalyticsWindow.everySection(ledger: ledger, period: period, today: today)
    }
    #expect(checksum != 0)
    #expect(times.median < .milliseconds(500))
  }

  /// Expected and received cashback of twelve months when every account prices its purchases
  /// by rules — «everything else» always and one category in every month —, as Analytics and
  /// «Оборот и кэшбэк» ask for it. The target is under 150 ms.
  @Test func cashbackOfTwelveMonths() {
    var dataset = Self.dataset
    let today = Self.set.lastDay
    let period = Period.twelveMonths(endingWith: today.monthKey)
    let category = dataset.categories.first { $0.kind == .expense && $0.systemRole == nil }?.id
    let one = CashbackPercent(e4: 10_000)!
    let five = CashbackPercent(e4: 50_000)!
    for account in dataset.paymentMethods {
      dataset.cashbackRules.append(CashbackRule(accountId: account.id, percent: one))
      for month in period.months {
        dataset.cashbackRules.append(
          CashbackRule(accountId: account.id, categoryId: category, month: month, percent: five))
      }
    }
    let ledger = Ledger(dataset: dataset, calendar: Synthetic.calendar)
    var cells = 0
    let times = Bench.measure("cashback, 12 months, \(dataset.cashbackRules.count) rules") {
      cells = CashbackReport(ledger: ledger, period: period).cells.count
    }
    #expect(cells > 0)
    #expect(times.median < .milliseconds(150))
  }

  /// The same after a change of data: the ledger is built anew, then every section. It
  /// fits in the same 500 ms.
  @Test func ledgerAndEveryAnalyticsSection() {
    let dataset = Self.dataset
    let today = Self.set.lastDay
    let period = Period.twelveMonths(endingWith: today.monthKey)
    var checksum: Int64 = 0
    let times = Bench.measure("ledger + analytics, every section, 12 months") {
      let ledger = Ledger(dataset: dataset, calendar: Synthetic.calendar)
      checksum = AnalyticsWindow.everySection(ledger: ledger, period: period, today: today)
    }
    #expect(checksum != 0)
    #expect(times.median < .milliseconds(500))
  }
}

/// Everything the sections of the Analytics window build for one period: the
/// overview charts, good and bad, paid for others, for whom, places, events, payment methods
/// and the forecast. It returns a figure of each, so none of the work can be optimised away.
enum AnalyticsWindow {
  static func everySection(ledger: Ledger, period: Period, today: DateOnly) -> Int64 {
    var sum: Int64 = 0
    // Overview.
    sum &+= CategoryBreakdown(ledger: ledger, period: period, kind: .expense).total.raw
    for step in TimeSeries.Step.allCases {
      for measure in SeriesMeasure.allCases {
        sum &+=
          TimeSeries(
            ledger: ledger, period: period, step: step, measure: measure, today: today
          ).total.raw
      }
    }
    sum &+= IncomeVsExpense(ledger: ledger, period: period).expenses.raw
    sum &+= IncomeSources(ledger: ledger, period: period).total.raw
    sum &+= PeriodComparison(ledger: ledger, period: period, today: today).expenses.current.raw
    sum &+= WeekdayProfile(ledger: ledger, period: period, today: today).days[0].total.raw
    // Good vs bad.
    let quality = QualityReport(ledger: ledger, period: period, today: today)
    sum &+= quality.goals.raw &+ Int64(quality.bestStreak)
    // Paid for others, for whom, places, events, payment methods.
    sum &+= OthersReport(ledger: ledger, period: period).totals.paid.raw
    sum &+= Int64(ForWhomReport(ledger: ledger, period: period).people.count)
    sum &+= Int64(PlacesReport(ledger: ledger, period: period).places.count)
    sum &+= Int64(EventsReport(ledger: ledger, period: period).events.count)
    sum &+= PaymentMethodsReport(ledger: ledger, period: period).cashback.raw
    // The forecast: what is spent, what is planned and the rest of the month.
    let spent = OverviewSummary(ledger: ledger, today: today).expenses.current
    let planned = PlannedPayments(ledger: ledger, today: today, rubPerUnit: [.usd: 95])
    let remainder = MonthForecast.remainder(ledger: ledger, today: today)
    sum &+= MonthForecast(spent: spent, planned: planned.total, remainder: remainder).p50.raw
    return sum
  }
}

/// One warm-up and five measured runs on `ContinuousClock`; prints the median and the
/// maximum.
enum Bench {
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
