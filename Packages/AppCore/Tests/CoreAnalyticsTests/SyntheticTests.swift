import CoreAccounting
import CoreKit
import CoreSample
import Foundation
import Testing

@testable import CoreAnalytics

/// One synthetic history the tests run over: a seed and a length.
struct SyntheticCase: Hashable, Sendable, CustomTestStringConvertible {
  let seed: UInt64
  let months: Int

  var testDescription: String { "seed \(seed), \(months) months" }

  /// Several seeds, half a year and two years.
  static let all = [
    SyntheticCase(seed: 20_260_918, months: 6), SyntheticCase(seed: 7, months: 6),
    SyntheticCase(seed: 20_260_918, months: 24), SyntheticCase(seed: 42, months: 24),
  ]
  static let twoYears = SyntheticCase(seed: 20_260_918, months: 24)
}

/// Synthetic histories and the ledgers over them, built once for every test that needs them.
enum Synthetic {
  static let endingOn = DateOnly(year: 2026, month: 9, day: 18)
  /// The app's calendar zone, so a day boundary means what it means in the app.
  static let calendar = CalendarContext.moscow

  static func generate(_ testCase: SyntheticCase, density: Int = 1) -> SampleDataSet {
    SampleDataGenerator(seed: testCase.seed).generate(
      months: testCase.months, endingOn: endingOn, calendar: calendar, language: "en",
      density: density)
  }

  /// What `DatasetRepository.load()` would give for the set once it is in a database.
  static func dataset(_ set: SampleDataSet) -> Dataset {
    Dataset(
      entries: set.entries, links: set.links, categories: set.categories, people: set.people,
      places: set.places, events: set.events, paymentMethods: set.paymentMethods,
      debts: set.debts, goals: set.goals,
      settings: AnalyticsSettings(cashbackCategoryId: set.cashbackCategoryId))
  }

  /// Built lazily and exactly once, whichever test gets there first.
  static let built: [SyntheticCase: (set: SampleDataSet, ledger: Ledger)] = Dictionary(
    uniqueKeysWithValues: SyntheticCase.all.map { testCase in
      let set = generate(testCase)
      return (testCase, (set, Ledger(dataset: dataset(set), calendar: calendar)))
    })

  static func load(_ testCase: SyntheticCase) throws -> (set: SampleDataSet, ledger: Ledger) {
    try #require(built[testCase], "\(testCase.testDescription) is not built")
  }

  /// The months with operations, plus any month income was paid for before the history
  /// began, oldest first.
  static func months(of set: SampleDataSet) -> [MonthKey] {
    let dated = MonthKey.range(set.firstDay.monthKey, through: set.lastDay.monthKey)
    return Array(Set(dated + set.expectations.monthKeys)).sorted()
  }
}

/// Every slice of the core against what the generator knows it wrote: the known
/// answers are kept by the generator itself, never through `MyExpensesRule` or the ledger,
/// so a rule broken in the core cannot agree with itself here.
@Suite("Synthetic history: every slice equals what the generator wrote")
struct SyntheticTests {
  @Test(arguments: SyntheticCase.all)
  func everyMonthIsWhatTheGeneratorWrote(_ testCase: SyntheticCase) throws {
    let (set, ledger) = try Synthetic.load(testCase)
    let builder = ReportBuilder(ledger: ledger, today: set.lastDay)
    var monthlyTables: [Int: ReportTable] = [:]
    var qualityReports: [Int: QualityReport] = [:]

    for month in Synthetic.months(of: set) {
      let known = set.expectations[month]
      let period = Period.month(month)
      let label = "\(testCase.testDescription), \(month.iso)"

      // My expenses, by date.
      #expect(ledger.expenses(in: period.range) == known.myExpenses, "\(label): my expenses")
      #expect(
        OverviewSummary(ledger: ledger, today: month.lastDay).expenses.current == known.myExpenses,
        "\(label): Overview on the last day")
      let categories = CategoryBreakdown(ledger: ledger, period: period, kind: .expense)
      #expect(amounts(categories.nodes) == byRoot(known), "\(label): by category")
      // The spending tables of the Reports window build their lines on their own path.
      for kind in Self.spendingTables {
        let report = builder.table(kind, period: period)
        #expect(amounts(report.rows) == byRoot(known), "\(label): \(kind.rawValue)")
      }
      let quality =
        qualityReports[month.year]
        ?? QualityReport(ledger: ledger, period: .year(month.year), today: set.lastDay)
      qualityReports[month.year] = quality
      let qualities = try #require(quality.months.first { $0.month == month })
      #expect(amounts(qualities.qualities) == byQuality(known), "\(label): by quality")

      // Paid for others, by the purchase.
      let others = OthersReport(ledger: ledger, period: period)
      #expect(figures(others.totals) == figures(known.forOthers), "\(label): for others")
      #expect(others.surplus == known.surplus, "\(label): surplus")

      // Income, by the month it is for.
      #expect(ledger.income(in: period) == known.income, "\(label): income")
      let methods = PaymentMethodsReport(ledger: ledger, period: period)
      var cashback: [UUID: AmountE4] = [:]
      for method in methods.methods where !method.cashback.isZero {
        guard case .paymentMethod(let id) = method.key else { continue }
        cashback[id] = method.cashback
      }
      #expect(cashback == known.cashbackByMethod.filter { !$0.value.isZero }, "\(label): cashback")

      // The row of the monthly report.
      let table =
        monthlyTables[month.year] ?? builder.table(.monthly, period: .year(month.year))
      monthlyTables[month.year] = table
      let row = try #require(table.rows.first { $0.key == .month(month) })
      #expect(
        row.values == [known.myExpenses, known.income, known.income - known.myExpenses],
        "\(label): monthly report")
    }
  }

  /// Expenses of a month: the day headers, the Overview on the last day, the monthly report,
  /// the month bucket of Analytics, «income against expenses», the category breakdown and
  /// every spending table of Reports, whatever it is grouped by, agree. Income of a month:
  /// the Overview rule with the cut-off on the last day of the history, the report row, the
  /// bucket and the income table agree. A year is its months.
  @Test(arguments: SyntheticCase.all)
  func overviewAnalyticsAndReportsAgree(_ testCase: SyntheticCase) throws {
    let (set, ledger) = try Synthetic.load(testCase)
    let builder = ReportBuilder(ledger: ledger, today: set.lastDay)
    let months = Synthetic.months(of: set)

    for year in Set(months.map(\.year)).sorted() {
      let monthly = builder.table(.monthly, period: .year(year))
      let expenses = TimeSeries(
        ledger: ledger, period: .year(year), step: .month, today: set.lastDay)
      let income = TimeSeries(
        ledger: ledger, period: .year(year), step: .month, measure: .income, today: set.lastDay)
      let versus = IncomeVsExpense(ledger: ledger, period: .year(year))

      for month in months where month.year == year {
        let label = "\(testCase.testDescription), \(month.iso)"
        let row = try #require(monthly.rows.first { $0.key == .month(month) })
        let spent = OverviewSummary(ledger: ledger, today: month.lastDay).expenses.current
        let days = Period.month(month).range.days.map { day in
          ledger.rowTotals(of: Set(ledger.rows(in: DayRange(day, day)).map(\.transactionId)))
            .myExpenses
        }
        #expect(AmountE4.sum(days) == spent, "\(label): day headers")
        #expect(row.values[0] == spent, "\(label): report row")
        #expect(expenses.points.first { $0.start == month.firstDay }?.amount == spent, "\(label)")
        #expect(versus.months.first { $0.month == month }?.expenses == spent, "\(label)")
        #expect(
          CategoryBreakdown(ledger: ledger, period: .month(month), kind: .expense).total == spent,
          "\(label): category breakdown")
        expectSpendingTables(builder, period: .month(month), toAddUpTo: spent, label)

        let received = ledger.income(attributedTo: [month], notAfter: set.lastDay)
        #expect(row.values[1] == received, "\(label): income row")
        #expect(income.points.first { $0.start == month.firstDay }?.amount == received, "\(label)")
        #expect(versus.months.first { $0.month == month }?.income == received, "\(label)")
        #expect(
          CategoryBreakdown(ledger: ledger, period: .month(month), kind: .income).total
            == received, "\(label): income table")
      }

      let known = months.filter { $0.year == year }.map { set.expectations[$0] }
      let spentInYear = AmountE4.sum(known.map(\.myExpenses))
      let receivedInYear = AmountE4.sum(known.map(\.income))
      #expect(ledger.expenses(in: Period.year(year).range) == spentInYear, "\(year): expenses")
      #expect(ledger.income(in: .year(year)) == receivedInYear, "\(year): income")
      #expect(
        monthly.total.values == [spentInYear, receivedInYear, receivedInYear - spentInYear],
        "\(year): monthly total")
      let total = builder.table(.periodTotal, period: .year(year))
      #expect(total.rows.map(\.amount) == [receivedInYear, spentInYear], "\(year): period total")
      #expect(
        CategoryBreakdown(ledger: ledger, period: .year(year), kind: .expense).total
          == spentInYear, "\(year): category breakdown")
      expectSpendingTables(builder, period: .year(year), toAddUpTo: spentInYear, "\(year)")
    }

    // On the last day of the history the Overview sees the whole of its month.
    let last = set.lastDay.monthKey
    let overview = OverviewSummary(ledger: ledger, today: set.lastDay)
    #expect(overview.expenses.current == set.expectations[last].myExpenses)
    #expect(overview.income.current == set.expectations[last].income)
  }

  /// The same seed gives the same history and the same answers, byte for byte.
  @Test func theSameSeedGivesTheSameHistoryAndAnswers() throws {
    let first = Synthetic.generate(SyntheticCase.twoYears)
    let second = Synthetic.generate(SyntheticCase.twoYears)
    #expect(first.entries == second.entries)
    #expect(first.links == second.links)
    #expect(first.events == second.events)
    #expect(first.debts == second.debts)
    #expect(first.debtEntries == second.debtEntries)
    #expect(first.expectations == second.expectations)
    let one = OverviewSummary(
      ledger: Ledger(dataset: Synthetic.dataset(first), calendar: Synthetic.calendar),
      today: first.lastDay)
    let other = OverviewSummary(
      ledger: Ledger(dataset: Synthetic.dataset(second), calendar: Synthetic.calendar),
      today: second.lastDay)
    #expect(one == other)

    let otherSeed = Synthetic.generate(SyntheticCase(seed: 42, months: 24))
    #expect(otherSeed.entries != first.entries)
    #expect(otherSeed.expectations != first.expectations)
  }

  // MARK: - Comparing

  private static let spendingTables: [ReportTable.Kind] = [
    .expensesByCategory, .expensesByCategoryAndSubcategory,
  ]

  /// Both spending tables of Reports, under every grouping, end at the same total, and every
  /// line with lines under it is their sum.
  private func expectSpendingTables(
    _ builder: ReportBuilder, period: Period, toAddUpTo spent: AmountE4, _ label: String
  ) {
    for grouping in ReportGrouping.allCases {
      for kind in Self.spendingTables {
        let table = builder.table(kind, period: period, grouping: grouping)
        let name = "\(label): \(kind.rawValue) by \(grouping.rawValue)"
        #expect(table.total.amount == spent, "\(name)")
        for row in table.rows where !row.children.isEmpty {
          #expect(AmountE4.sum(row.children.compactMap(\.amount)) == row.amount, "\(name)")
        }
      }
    }
  }

  private func amounts(_ nodes: [BreakdownNode]) -> [ReportKey: AmountE4] {
    Dictionary(
      nodes.filter { !$0.amount.isZero }.map { ($0.key, $0.amount) },
      uniquingKeysWith: { first, _ in first })
  }

  private func amounts(_ rows: [ReportRow]) -> [ReportKey: AmountE4] {
    Dictionary(
      rows.compactMap { row in row.amount.flatMap { $0.isZero ? nil : (row.key, $0) } },
      uniquingKeysWith: { first, _ in first })
  }

  private func byRoot(_ known: SampleExpectations.Month) -> [ReportKey: AmountE4] {
    var result: [ReportKey: AmountE4] = [:]
    for (root, amount) in known.byRootCategory where !amount.isZero {
      result[root.map(ReportKey.category) ?? .uncategorized] = amount
    }
    return result
  }

  private func byQuality(_ known: SampleExpectations.Month) -> [ReportKey: AmountE4] {
    var result: [ReportKey: AmountE4] = [:]
    for (quality, amount) in known.byQuality where !amount.isZero {
      result[.quality(quality)] = amount
    }
    return result
  }

  private func figures(_ totals: OthersReport.Totals) -> [AmountE4] {
    [totals.paid, totals.returned, totals.writtenOff, totals.waiting, totals.shortfall]
  }

  private func figures(_ known: SampleExpectations.ForOthers) -> [AmountE4] {
    [known.paid, known.returned, known.writtenOff, known.waiting, known.shortfall]
  }
}
