import CoreAnalytics
import CoreKit
import Foundation

/// The lines of «can save» read like the lines of «free to spend».
public typealias CanSaveLine = FreeToSpendLine

/// What «can save this month» is made of, in rubles.
public struct CanSaveInputs: Hashable, Sendable {
  public var income: MonthIncomeEstimate
  /// My expenses of this month to date, goal contributions left out — they are the saving
  /// itself, not spending that stands in its way.
  public var spentWithoutGoals: AmountE4
  /// My share of the scheduled payments and the payments on debts whose payments are
  /// expenses still due this month.
  public var plannedStillDue: AmountE4
  /// What variable spending adds over the rest of the month (`MonthForecast.remainder`).
  public var remainder: MonthForecast.Remainder
  /// Net goal contributions of this month.
  public var alreadySaved: AmountE4

  public init(
    income: MonthIncomeEstimate, spentWithoutGoals: AmountE4, plannedStillDue: AmountE4,
    remainder: MonthForecast.Remainder, alreadySaved: AmountE4
  ) {
    self.income = income
    self.spentWithoutGoals = spentWithoutGoals
    self.plannedStillDue = plannedStillDue
    self.remainder = remainder
    self.alreadySaved = alreadySaved
  }

  /// The inputs with the two ledger figures taken from the ledger: my expenses without goal
  /// contributions from the 1st through today, by date, and the net goal contributions of
  /// the same days.
  public init(
    ledger: Ledger, today: DateOnly, income: MonthIncomeEstimate, plannedStillDue: AmountE4,
    remainder: MonthForecast.Remainder
  ) {
    let span = DayRange(today.monthKey.firstDay, today)
    let spent = AmountE4.sum(
      ledger.rows(in: span).lazy.filter { !$0.isGoalContribution }.map(\.contribution))
    self.init(
      income: income, spentWithoutGoals: spent, plannedStillDue: plannedStillDue,
      remainder: remainder, alreadySaved: GoalRules.netContributions(ledger: ledger, in: span))
  }
}

/// «Can save this month»: expected income − planned payments − expected
/// variable spending (P50), with a range and what is saved already.
///
///     P50  = income − spent without goals − planned still due − remainder (middle)
///     low  = income − spent without goals − planned still due − remainder (P90)
///     high = income − spent without goals − planned still due − remainder (P10)
///
/// The variable spending of the month is what was spent so far plus what the rest of the
/// month is expected to add; the planned payments already made are among what was spent.
/// Goal contributions are neither: they are what is being saved, so «can save more» is
/// max(0, P50 − already saved). P50 may be negative — the month is spending more than it
/// brings. Without an income estimate there is no advice, only «not enough data»; a thin
/// history on either side keeps the numbers and raises `lowData`.
public struct CanSave: Hashable, Sendable {
  public enum Status: Hashable, Sendable {
    case ready
    case notEnoughData(reasonKey: String)
  }

  /// The keys of the lines and of the reason; the app supplies the words.
  public enum Key {
    public static let income = "advice.canSave.income"
    public static let spent = "advice.canSave.spent"
    public static let planned = "advice.canSave.planned"
    public static let variable = "advice.canSave.variable"
    public static let noIncome = "advice.reason.noIncome"
  }

  public var status: Status
  public var lines: [CanSaveLine]
  public var p50: AmountE4?
  /// With the remainder at its P90: the lower end of the range.
  public var low: AmountE4?
  /// With the remainder at its P10: the upper end of the range.
  public var high: AmountE4?
  public var alreadySaved: AmountE4
  public var canSaveMore: AmountE4?
  /// The income estimate or the forecast of the rest of the month is thin.
  public var lowData: Bool

  public init(_ inputs: CanSaveInputs) {
    alreadySaved = inputs.alreadySaved
    lowData = inputs.income.lowData || inputs.remainder.lowData
    guard let income = inputs.income.value else {
      status = .notEnoughData(reasonKey: Key.noIncome)
      lines = []
      p50 = nil
      low = nil
      high = nil
      canSaveMore = nil
      return
    }
    let remainder = inputs.remainder
    lines = [
      CanSaveLine(key: Key.income, sign: .plus, amount: income),
      CanSaveLine(key: Key.spent, sign: .minus, amount: inputs.spentWithoutGoals),
      CanSaveLine(key: Key.planned, sign: .minus, amount: inputs.plannedStillDue),
      CanSaveLine(key: Key.variable, sign: .minus, amount: remainder.middle),
    ]
    let known = income - inputs.spentWithoutGoals - inputs.plannedStillDue
    let middle = known - remainder.middle
    status = .ready
    p50 = middle
    // The quantiles of a skewed history need not sit on either side of the mean; the range
    // is kept around P50 the way the forecast keeps its own.
    low = min(known - remainder.p90, middle)
    high = max(known - remainder.p10, middle)
    canSaveMore = max(.zero, middle - inputs.alreadySaved)
  }
}

/// The savings rate of a month: net goal contributions ÷ income of the month, against the
/// target share of the settings.
///
/// Both sides take the month whole, as the tables of the Reports do: the
/// contributions dated in it and the income that belongs to it. Without positive income
/// there is no rate.
public struct SavingsRate: Hashable, Sendable {
  public enum Status: String, Hashable, Sendable, CaseIterable {
    case notEnoughData
    case belowTarget
    case onTarget
  }

  public var month: MonthKey
  /// Basis points, rounded half away from zero; `nil` without positive income.
  public var rateBp: Int?
  public var goalsNet: AmountE4
  public var income: AmountE4
  public var targetBp: Int
  public var status: Status

  public init(
    month: MonthKey, rateBp: Int?, goalsNet: AmountE4, income: AmountE4, targetBp: Int,
    status: Status
  ) {
    self.month = month
    self.rateBp = rateBp
    self.goalsNet = goalsNet
    self.income = income
    self.targetBp = targetBp
    self.status = status
  }

  public static func month(ledger: Ledger, month: MonthKey, targetBp: Int) -> SavingsRate {
    let goalsNet = GoalRules.netContributions(ledger: ledger, in: Period.month(month).range)
    let income = ledger.income(attributedTo: [month])
    let rate = Shares.ratio(goalsNet, of: income)
    let status: Status
    if let rate {
      status = rate >= targetBp ? .onTarget : .belowTarget
    } else {
      status = .notEnoughData
    }
    return SavingsRate(
      month: month, rateBp: rate, goalsNet: goalsNet, income: income, targetBp: targetBp,
      status: status)
  }
}
