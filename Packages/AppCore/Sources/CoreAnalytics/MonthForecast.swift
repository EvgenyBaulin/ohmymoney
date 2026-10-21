import CoreAccounting
import CoreKit
import Foundation

/// Payments already known for the rest of the month: debts whose payments are
/// expenses and goals that are behind their monthly plan. Scheduled payments are not here:
/// they live in `CorePlanning`, which this module cannot see, and `PlannedMonth` there adds
/// them to the same debts and goals — a forecast takes one of the two, never both.
///
/// The app takes `PlannedMonth`; this is the forecast's rule for debts and goals, as the
/// golden fixture of this module pins it. Its debts and goals are the planned month's, rule
/// for rule, and `PlannedTests.theForecastsPlannedPaymentsAgreeWithThePlannedMonth` keeps
/// them one figure.
public struct PlannedPayments: Hashable, Sendable {
  public var debts: AmountE4
  /// In rubles at today's rate, whatever the currency of each goal.
  public var goals: AmountE4
  /// Debts in a currency without a known rate: left out rather than guessed.
  public var debtsWithoutRate: [UUID]
  /// Goals in a currency without today's rate: left out rather than guessed.
  public var goalsWithoutRate: [UUID] = []

  public var total: AmountE4 { debts + goals }

  /// * a debt counts when it is not closed, its payments are expenses, it has a monthly
  ///   payment and a payment day, and this month's due falls after today and is still unpaid —
  ///   each payment closes the earliest due still unpaid, counted from the start of the debt
  ///   (`DebtDues`, the rule every planning screen shares), so a payment made last month «for
  ///   this month» pays it, a payment day before the debt began owes nothing, and a debt with
  ///   nothing left on it owes no due; the payment day is the day it falls due, clipped to the
  ///   length of the month — a debt paid «on the 31st» is due on 30 September, not after it;
  ///   a debt in another currency is converted at the last rate the caller knows
  ///   (`rubPerUnit`);
  /// * a goal counts with what is left of its monthly plan: max(0, plan − contributions
  ///   this month), never more than the plan, never more than it still needs, max(0,
  ///   target − saved) — `GoalMath.planLeft`, the rule `GoalRules.planStillDue` in
  ///   `CorePlanning` gives too. It is worked out in the goal's currency, contributions in
  ///   another currency at the rate of their day (`dayRates`), and converted at today's rate
  ///   (`rubPerUnit`).
  public init(
    ledger: Ledger, today: DateOnly, rubPerUnit: [CurrencyCode: Decimal] = [:],
    dayRates: DayRates = .empty
  ) {
    let month = today.monthKey
    let journal = ledger.dataset.planning.debtEntries
    let planned = ledger.dataset.debts.filter { debt in
      guard !debt.closed, DebtRules.paymentIsExpense(on: debt), debt.hasDues else { return false }
      return true
    }
    let states = DebtDues.states(debts: planned, ledger: ledger, journal: journal, today: today)
    var debts = AmountE4.zero
    var missing: [UUID] = []
    for debt in planned {
      guard let day = debt.paymentDay, let state = states[debt.id]?.knowing(debt) else { continue }
      let due = DebtDueState.payday(day, in: month)
      guard due > today, state.isUnpaid(due) else { continue }
      // What is left of the due when part of it was paid.
      let owed = state.owed(due)
      if debt.currency == .rub {
        debts += owed
      } else if let rate = rubPerUnit[debt.currency] {
        debts += AmountE4.rounded(owed.decimal * rate)
      } else {
        missing.append(debt.id)
      }
    }
    var goals = AmountE4.zero
    var goalsMissing: [UUID] = []
    let stillDue = GoalMath.planLeft(
      goals: ledger.dataset.goals, rows: ledger.rows, month: month, rates: dayRates)
    for goal in ledger.dataset.goals where !goal.archived {
      guard let left = stillDue[goal.id] else { continue }
      if let rubles = GoalMath.rubles(left, in: goal.currency, rubPerUnit: rubPerUnit) {
        goals += rubles
      } else {
        goalsMissing.append(goal.id)
      }
    }
    self.debts = debts
    self.goals = goals
    self.debtsWithoutRate = missing.sorted { $0.uuidString < $1.uuidString }
    self.goalsWithoutRate = goalsMissing.sorted { $0.uuidString < $1.uuidString }
  }
}

/// The forecast of spending to the end of the month: spent so far + the known planned
/// payments + a quantile estimate of the variable spending of the days left, by weekday.
///
/// The pipeline computes only the **remainder**: what variable spending will add over the
/// days after today. The card adds it to the spending and planned payments it has at hand,
/// so the known part of the figure is always fresh.
public struct MonthForecast: Hashable, Sendable {
  /// What the rest of the month is expected to add, never below zero.
  public struct Remainder: Hashable, Sendable {
    public var p10: AmountE4
    public var middle: AmountE4
    public var p90: AmountE4
    /// The history window is shorter than 28 days: a straight line with ±50 %.
    public var lowData: Bool
    /// The day the model was computed for; it is stale once the day changes.
    public var computedFor: DateOnly
    /// Days after today to the end of the month.
    public var daysLeft: Int
    /// Days of history the window covered.
    public var windowDays: Int

    public init(
      p10: AmountE4, middle: AmountE4, p90: AmountE4, lowData: Bool, computedFor: DateOnly,
      daysLeft: Int, windowDays: Int
    ) {
      self.p10 = p10
      self.middle = middle
      self.p90 = p90
      self.lowData = lowData
      self.computedFor = computedFor
      self.daysLeft = daysLeft
      self.windowDays = windowDays
    }
  }

  /// Spent + planned + remainder, with P10 ≤ P50 ≤ P90 and P10 never below what is spent.
  public var p10: AmountE4
  public var p50: AmountE4
  public var p90: AmountE4
  public var lowData: Bool

  public static let windowLength = 90
  public static let minimumWindow = 28
  /// From two full months of history the weekdays are told apart: eight samples of each is
  /// the least a median of a weekday is worth taking.
  public static let weekdayWindow = 56
  /// Runs starting on one weekday that an interval needs before it is taken from them alone.
  public static let minimumRuns = 4

  /// How the remainder is estimated. Which one is used follows from how much history there
  /// is; `ForecastBacktest` forces one to compare them.
  public enum Method: String, Hashable, Sendable, CaseIterable {
    /// Variable spending since the 1st ÷ days elapsed × days left, interval ±50 %. What a
    /// short history gets, and what the backtest measures the others against.
    case rate
    /// The window mean × days left, interval from the sums of every run of that length.
    case window
    /// P10 / P50 / P90 of the sums of the runs of that many days which begin on the same
    /// weekday as tomorrow.
    case weekday
  }

  public init(spent: AmountE4, planned: AmountE4, remainder: Remainder) {
    let known = spent + planned
    p50 = known + remainder.middle
    p10 = max(spent, min(known + remainder.p10, p50))
    p90 = max(known + remainder.p90, p50)
    lowData = remainder.lowData
  }

  /// Variable spending: my expenses without goal contributions, debt payments, parts paid
  /// for others and system categories — those are either planned or not mine. Nor the
  /// operations that paid scheduled payments: those «Mark as paid» wrote (`sched:` links) and
  /// the ordinary ones that match a due date (`scheduledOperations`, worked out by the
  /// planning, which this module cannot see). They are planned payments already, and left in
  /// the history they would be counted twice — once in the planned payments, once more in the
  /// daily average.
  static func isVariable(_ row: LedgerRow, scheduledOperations: Set<UUID> = []) -> Bool {
    if case .scheduled = row.link { return false }
    if scheduledOperations.contains(row.transactionId) { return false }
    // Nor anything the app wrote for its own books — the surplus and the shortfall of a
    // reimbursement, and the difference of a reconciliation. The last one used to be excluded
    // by its category, «Не помню»; it lives in «Сверка» now, which is an ordinary category,
    // and a forecast that took it for spending would grow by every ruble the books ever
    // failed to account for.
    if row.link?.isBookkeeping == true { return false }
    return !row.contribution.isZero && !row.isGoalContribution && row.debtId == nil
      && !row.reimbursable && row.systemRole == nil
  }

  /// The remainder for the days after `today`.
  ///
  /// Reading the whole ledger once and asking it many times is what the backtest needs, so
  /// the daily series is a value of its own: `VariableSpending`. `scheduledOperations` are the
  /// ordinary operations that pay a due date of a scheduled payment by matching it.
  public static func remainder(
    ledger: Ledger, today: DateOnly, method: Method? = nil,
    scheduledOperations: Set<UUID> = []
  )
    -> Remainder
  {
    VariableSpending(ledger: ledger, scheduledOperations: scheduledOperations)
      .remainder(today: today, method: method)
  }

  /// Sums of every run of `length` consecutive values; when the series is shorter than a
  /// run, the runs wrap around it, one starting at each value.
  static func rollingSums(_ series: [Decimal], length: Int) -> [Decimal] {
    guard !series.isEmpty, length > 0 else { return [] }
    if length <= series.count {
      var sum = series[0..<length].reduce(0, +)
      var sums = [sum]
      for index in length..<series.count {
        sum += series[index] - series[index - length]
        sums.append(sum)
      }
      return sums
    }
    return series.indices.map { start in
      (0..<length).reduce(Decimal(0)) { $0 + series[(start + $1) % series.count] }
    }
  }
}
