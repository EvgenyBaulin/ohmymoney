import CoreAnalytics
import CoreKit
import Foundation

/// What «Хватит ли?» takes as the monthly spending when it tells «подождать до …»: the median
/// of my expenses over the last three full months before the current one.
///
/// A month's figure is the ledger's «мои расходы» (`LedgerRow.contribution`: my spending minus
/// refunds, a part for somebody else only once written off) without what is no spending of
/// mine: the difference of a reconciliation, and goal contributions — the plans of the goals
/// are taken off separately, so counting them here would take them twice. Transfers are not
/// ledger rows at all.
public struct AffordSpending: Hashable, Sendable {
  /// Full months the median needs.
  public static let monthsNeeded = 3

  /// The median of the months, in rubles; `nil` with fewer than `monthsNeeded` full months of
  /// history — the caller falls back to the obligatory spending.
  public var medianRub: AmountE4?
  /// The full months found, up to `monthsNeeded`.
  public var fullMonths: Int

  public init(medianRub: AmountE4?, fullMonths: Int) {
    self.medianRub = medianRub
    self.fullMonths = fullMonths
  }

  public static let none = AffordSpending(medianRub: nil, fullMonths: 0)

  public static func build(ledger: Ledger, today: DateOnly) -> AffordSpending {
    let months = SavingsMath.completeMonths(
      before: today.monthKey, historyStart: ledger.firstDay?.monthKey, count: monthsNeeded)
    guard months.count >= monthsNeeded else {
      return AffordSpending(medianRub: nil, fullMonths: months.count)
    }
    let counts = ledger.dataset.planning.settings.limitlessCategoryIds
    let totals = months.map { month -> AmountE4 in
      AmountE4.sum(
        ledger.rows(in: DayRange(month.firstDay, month.lastDay))
          .filter {
            !$0.isGoalContribution
              && !OverviewSummary.isCountDifference($0, countCategories: counts)
          }
          .map(\.contribution))
    }
    return AffordSpending(medianRub: IncomeEstimate.median(totals), fullMonths: months.count)
  }
}
