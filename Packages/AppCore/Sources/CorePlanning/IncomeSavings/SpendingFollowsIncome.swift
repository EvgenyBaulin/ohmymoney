import CoreAnalytics
import CoreKit
import Foundation

/// Whether spending grows faster than income: «за 3 месяца доход +20 %, траты +25 % к тем же
/// месяцам год назад».
///
/// The last three complete months are set against the same three months a year earlier, so the
/// season cancels out. With less than a year and three months of history the last six complete
/// months are set against the six before them (`comparison == .sixToSix`, marked as such: summer
/// meets winter there). Spending is my spending without goal contributions — money put aside
/// does not count as growth of spending.
public struct SpendingFollowsIncome: Hashable, Sendable {
  public enum Comparison: String, Hashable, Sendable {
    /// 3 months against the same 3 months a year ago.
    case yearOverYear
    /// 6 months against the 6 before them: fresher, but seasonal.
    case sixToSix
  }

  public enum State: Hashable, Sendable {
    case ready
    /// Not enough history for either comparison, or nothing to divide by.
    case notEnoughData
  }

  /// The spending grows this many basis points faster than the income before it is worth
  /// saying so.
  public static let gapBp = 500

  public var comparison: Comparison?
  public var recentMonths: [MonthKey]
  public var earlierMonths: [MonthKey]
  public var incomeRub: AmountE4
  public var earlierIncomeRub: AmountE4
  public var spendingRub: AmountE4
  public var earlierSpendingRub: AmountE4
  /// Change in basis points, rounded half away from zero; `nil` when the earlier figure is not
  /// above zero.
  public var incomeChangeBp: Int?
  public var spendingChangeBp: Int?
  /// Income went up, spending went up by at least `gapBp` more: worth a line.
  public var spendingOutpacesIncome: Bool
  public var state: State

  public init(
    comparison: Comparison?, recentMonths: [MonthKey], earlierMonths: [MonthKey],
    incomeRub: AmountE4, earlierIncomeRub: AmountE4, spendingRub: AmountE4,
    earlierSpendingRub: AmountE4, incomeChangeBp: Int?, spendingChangeBp: Int?,
    spendingOutpacesIncome: Bool, state: State
  ) {
    self.comparison = comparison
    self.recentMonths = recentMonths
    self.earlierMonths = earlierMonths
    self.incomeRub = incomeRub
    self.earlierIncomeRub = earlierIncomeRub
    self.spendingRub = spendingRub
    self.earlierSpendingRub = earlierSpendingRub
    self.incomeChangeBp = incomeChangeBp
    self.spendingChangeBp = spendingChangeBp
    self.spendingOutpacesIncome = spendingOutpacesIncome
    self.state = state
  }

  public static func build(ledger: Ledger, today: DateOnly) -> SpendingFollowsIncome {
    let current = today.monthKey
    let start = IncomeEstimate.historyStart(firstDay: ledger.firstDay)
    let recent3 = MonthKey.range(current.adding(months: -3), through: current.previous)
    let earlier3 = recent3.map { $0.adding(months: -12) }
    let recent6 = MonthKey.range(current.adding(months: -6), through: current.previous)
    let earlier6 = MonthKey.range(current.adding(months: -12), through: current.adding(months: -7))

    let comparison: Comparison
    let recent: [MonthKey]
    let earlier: [MonthKey]
    if let start, let first = earlier3.first, start <= first {
      (comparison, recent, earlier) = (.yearOverYear, recent3, earlier3)
    } else if let start, let first = earlier6.first, start <= first {
      (comparison, recent, earlier) = (.sixToSix, recent6, earlier6)
    } else {
      return SpendingFollowsIncome(
        comparison: nil, recentMonths: [], earlierMonths: [], incomeRub: .zero,
        earlierIncomeRub: .zero, spendingRub: .zero, earlierSpendingRub: .zero,
        incomeChangeBp: nil, spendingChangeBp: nil, spendingOutpacesIncome: false,
        state: .notEnoughData)
    }

    let income = AmountE4.sum(recent.map { ledger.income(attributedTo: [$0]) })
    let earlierIncome = AmountE4.sum(earlier.map { ledger.income(attributedTo: [$0]) })
    let spending = spent(ledger, recent)
    let earlierSpending = spent(ledger, earlier)
    let incomeChange = change(income, from: earlierIncome)
    let spendingChange = change(spending, from: earlierSpending)
    let outpaces: Bool
    if let incomeChange, let spendingChange {
      outpaces = incomeChange > 0 && spendingChange - incomeChange >= gapBp
    } else {
      outpaces = false
    }
    return SpendingFollowsIncome(
      comparison: comparison, recentMonths: recent, earlierMonths: earlier, incomeRub: income,
      earlierIncomeRub: earlierIncome, spendingRub: spending,
      earlierSpendingRub: earlierSpending, incomeChangeBp: incomeChange,
      spendingChangeBp: spendingChange, spendingOutpacesIncome: outpaces,
      state: incomeChange == nil || spendingChange == nil ? .notEnoughData : .ready)
  }

  /// My spending without goal contributions over whole months, by date.
  static func spent(_ ledger: Ledger, _ months: [MonthKey]) -> AmountE4 {
    var total = AmountE4.zero
    for month in months {
      for row in ledger.rows(in: DayRange(month.firstDay, month.lastDay))
      where !row.isGoalContribution {
        total += row.contribution
      }
    }
    return total
  }

  static func change(_ now: AmountE4, from before: AmountE4) -> Int? {
    guard before.raw > 0 else { return nil }
    return SavingsNorm.signedRatio(now - before, of: before)
  }
}

/// The line «spending follows income» in «Стоит посмотреть»: at most once a quarter, and never
/// again once the owner said «Больше не показывать».
public enum TrendNudge {
  /// `YYYY-Qn` of a day.
  public static func quarterKey(of day: DateOnly) -> String {
    "\(day.year)-Q\((day.month - 1) / 3 + 1)"
  }

  /// Whether to show the line now: switched on, spending really outpaces income, and not shown
  /// yet this quarter.
  public static func shouldShow(
    _ trend: SpendingFollowsIncome, settings: IncomeSavingsSettings, today: DateOnly
  ) -> Bool {
    guard settings.trendNudgeEnabled, trend.state == .ready, trend.spendingOutpacesIncome
    else { return false }
    return settings.trendNudgeShown != quarterKey(of: today)
  }

  /// The settings after the line was shown: the quarter is remembered.
  public static func markShown(
    _ settings: IncomeSavingsSettings, today: DateOnly
  ) -> IncomeSavingsSettings {
    var copy = settings
    copy.trendNudgeShown = quarterKey(of: today)
    return copy
  }

  /// The settings after «Больше не показывать».
  public static func turnedOff(_ settings: IncomeSavingsSettings) -> IncomeSavingsSettings {
    var copy = settings
    copy.trendNudgeEnabled = false
    return copy
  }
}
