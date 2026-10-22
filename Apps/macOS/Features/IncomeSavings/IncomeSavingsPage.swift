import AppCore
import Foundation

/// Everything the section «Доход и сбережения» of Analytics shows, counted once for the data on
/// screen: the savings norm by month, the baskets of the latest complete month against the
/// owner's proportions, the obligatory share, the cushion in days, the stability of income, the
/// line «spending follows income», the salary effect and the financial health with its history.
///
/// Every part is the core's own result (`IncomeSavingsFacade`), so the numbers of the cards, the
/// tiles and the breakdown sheet are the same ones; the page only gathers them.
struct IncomeSavingsPage: Sendable {
  /// How many months the norm series and the history of the health run over.
  static let months = 12

  /// The last twelve months ending with the current one, oldest first.
  var series: [SavingsNormMonth]
  /// The month laid out in the baskets: the latest complete month with an income, else the
  /// current one.
  var fit: BudgetFit
  var obligatory: ObligatoryShare
  var cushion: CushionDays
  var stability: IncomeStability
  var trend: SpendingFollowsIncome
  var salary: SalaryEffect
  var health: FinancialHealth
  var healthSeries: [FinancialHealth.Point]
  var settings: IncomeSavingsSettings
  /// The day the page was counted for.
  var today: DateOnly

  /// The month the headline norm is taken from: the latest complete month that had an income;
  /// the current month when there is none yet.
  var headline: SavingsNormMonth? {
    series.last { !$0.isPartial && $0.state == .ready } ?? series.last
  }

  /// The months of the history of the health, oldest first, ending with the month of `today`.
  static func healthMonths(today: DateOnly) -> [MonthKey] {
    MonthKey.range(today.monthKey.adding(months: -(months - 1)), through: today.monthKey)
  }

  /// Counts the page off the main thread through the façade (cached per version of the data).
  static func load(
    _ snapshot: DataSnapshot, analysis: AnalysisFacade
  ) async throws -> IncomeSavingsPage {
    let income = analysis.incomeSavings
    let series = try await income.savingsSeries(snapshot, count: months)
    let basketMonth =
      series.last { !$0.isPartial && $0.state == .ready }?.month ?? snapshot.today.monthKey
    let fit = try await income.budgetFit(snapshot, month: basketMonth)
    let obligatory = try await income.obligatoryShare(snapshot)
    let cushion = try await income.cushionDays(snapshot)
    let stability = try await income.stability(snapshot)
    let trend = try await income.spendingFollowsIncome(snapshot)
    let salary = try await income.salaryEffect(snapshot)
    let health = try await income.health(snapshot)
    let healthSeries = try await income.healthSeries(
      snapshot, months: healthMonths(today: snapshot.today))
    return IncomeSavingsPage(
      series: series, fit: fit, obligatory: obligatory, cushion: cushion,
      stability: stability, trend: trend, salary: salary, health: health,
      healthSeries: healthSeries, settings: snapshot.dataset.incomeSavings,
      today: snapshot.today)
  }
}
