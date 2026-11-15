import CoreAnalytics
import CoreKit

extension AccountMonthPlan {
  /// Balances after recorded future movements and unpaid scheduled and debt payments.
  /// Expected income, interest and spending patterns belong to the combined forecast:
  /// without future transfers they cannot predict where the money will be held.
  public func knownBalances() -> AccountForecast {
    var known = self
    known.weights = [:]
    known.fallbackKey = nil
    known.aheadSpendingRub = .zero
    for section in known.sections.indices {
      for pair in known.sections[section].keys.indices {
        known.sections[section].keys[pair].income = .zero
        known.sections[section].keys[pair].interest = .zero
        known.sections[section].keys[pair].reconcileLoss = .zero
        known.sections[section].keys[pair].othersSpending = .zero
        known.sections[section].keys[pair].spendingWeight = .zero
        known.sections[section].keys[pair].overdueIncome = []
      }
    }
    return known.forecast(
      remainder: MonthForecast.Remainder(
        p10: .zero, middle: .zero, p90: .zero, lowData: false, computedFor: today,
        daysLeft: today.days(to: through), windowDays: 0))
  }
}
