import CoreAnalytics
import CoreKit

extension AccountMonthPlan {
  /// Balances after recorded future movements, the income and interest still expected on
  /// each account, the usual count losses, the expected spending for others, and unpaid
  /// scheduled and debt payments. Overdue income stays apart and brings no money. The account takes no share of the usual spending: that belongs to the
  /// combined forecast, which cannot tell which account the spending will come from.
  public func knownBalances() -> AccountForecast {
    var known = self
    known.weights = [:]
    known.fallbackKey = nil
    known.aheadSpendingRub = .zero
    for section in known.sections.indices {
      for pair in known.sections[section].keys.indices {
        known.sections[section].keys[pair].spendingWeight = .zero
      }
    }
    return known.forecast(
      remainder: MonthForecast.Remainder(
        p10: .zero, middle: .zero, p90: .zero, lowData: false, computedFor: today,
        daysLeft: today.days(to: through), windowDays: 0))
  }
}
