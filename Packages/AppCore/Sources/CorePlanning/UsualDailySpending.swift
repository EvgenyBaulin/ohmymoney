import CoreAnalytics
import CoreKit
import Foundation

/// Daily spending over the last three months, with a median of complete months for purchase
/// pauses. Empty days count as days, and refunds reduce spending.
public struct UsualDailySpending: Hashable, Sendable {
  public var average: AmountE4?
  public var median: AmountE4?

  public init(ledger: Ledger, today: DateOnly) {
    if let first = ledger.firstDay, first.adding(months: 1) <= today {
      let range = DayRange(max(first, today.adding(months: -3)), today.adding(days: -1))
      let total = AmountE4.sum(
        ledger.rows(in: range)
          .filter { !$0.isGoalContribution && !OverviewSummary.isCountDifference($0) }
          .map(\.contribution))
      average = try? AmountE4(decimal: max(.zero, total).decimal / Decimal(range.dayCount))
    } else {
      average = nil
    }
    let months = SavingsMath.completeMonths(
      before: today.monthKey,
      historyStart: IncomeEstimate.historyStart(firstDay: ledger.firstDay), count: 3)
    guard !months.isEmpty else {
      median = nil
      return
    }
    let amounts = months.map { month in
      max(
        .zero,
        AmountE4.sum(
          ledger.rows(in: DayRange(month.firstDay, month.lastDay))
            .filter { !$0.isGoalContribution && !OverviewSummary.isCountDifference($0) }
            .map(\.contribution)))
    }
    median = IncomeEstimate.median(
      zip(months, amounts).map { month, amount in
        (try? AmountE4(decimal: amount.decimal / Decimal(month.dayCount))) ?? .zero
      })
  }
}
