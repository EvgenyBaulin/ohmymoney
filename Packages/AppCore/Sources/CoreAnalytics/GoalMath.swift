import CoreAccounting
import CoreKit
import Foundation

/// The money of a goal, counted in the goal's own currency — the one rule the goals of
/// Planning (`GoalRules` in CorePlanning) and the planned payments of the forecast
/// (`PlannedPayments`) share, so the two can never disagree about a goal.
///
/// A row belongs to a goal when it carries the goal's id, or when it carries no goal at all
/// and is filed under the goal's subcategory. A contribution is an `expense` and adds; a
/// withdrawal is a `refund` and takes off; nothing else touches a goal.
///
/// A row in the goal's currency counts with its own amount. A ruble goal counts rubles, as it
/// always did. Any other row counts its rubles at the rate of its own day
/// (`DayRates` — rubles for one unit, the nominal applied: 100 tenge are quoted, one is kept),
/// so a contribution made months ago does not change value when the rate moves.
public enum GoalMath {
  /// Whether the row is money put into the goal or taken out of it.
  public static func belongs(_ row: LedgerRow, to goal: Goal) -> Bool {
    row.goalId == goal.id
      || (row.goalId == nil && row.categoryId != nil && row.categoryId == goal.subcategoryId)
  }

  /// What a row adds to a goal, in the goal's currency: plus for a contribution, minus for a
  /// withdrawal, zero for a row of another goal or of another kind. `nil` when the row counts
  /// but no rate of the goal's currency is known at all: the caller skips it and says so,
  /// rather than guessing.
  public static func contribution(
    of row: LedgerRow, to goal: Goal, rates: DayRates
  ) -> AmountE4? {
    guard belongs(row, to: goal) else { return .zero }
    return amount(of: row, in: goal.currency, rates: rates)
  }

  /// The row's signed amount in `currency`, the goal's belonging aside.
  private static func amount(
    of row: LedgerRow, in currency: CurrencyCode, rates: DayRates
  ) -> AmountE4? {
    let sign: Int64
    switch row.kind {
    case .expense: sign = 1
    case .refund: sign = -1
    case .income, .reimbursement: return .zero
    }
    let value: AmountE4
    if currency == .rub {
      value = row.amountRubE4
    } else if row.currency == currency {
      value = row.amountE4
    } else {
      guard let perUnit = rates.perUnit(currency, on: row.day), perUnit > 0 else { return nil }
      value = AmountE4.rounded(row.amountRubE4.decimal / perUnit)
    }
    return sign < 0 ? -value : value
  }

  /// An amount of `currency` in rubles at the rate the caller has for today (`rubPerUnit`,
  /// rubles for one unit); `nil` without one. Rubles stay as they are.
  public static func rubles(
    _ amount: AmountE4, in currency: CurrencyCode, rubPerUnit: [CurrencyCode: Decimal]
  ) -> AmountE4? {
    if currency == .rub { return amount }
    guard let rate = rubPerUnit[currency], rate > 0 else { return nil }
    return AmountE4.rounded(amount.decimal * rate)
  }

  /// What the monthly plan of each live goal still asks in `month`, in the goal's currency:
  /// `GoalPlanState.restThisMonth` — what is left of this month's plan once what went in above
  /// the plans of the months before is counted towards it, never more than the plan itself and
  /// never more than the goal still needs, max(0, target − saved). A reached goal asks nothing,
  /// and a withdrawal of earlier months' savings is no plan of this month. Goals without a
  /// plan, or with nothing left to ask, are not in the map. A row without a rate adds nothing.
  public static func planLeft(
    goals: [Goal], rows: [LedgerRow], month: MonthKey, rates: DayRates
  ) -> [UUID: AmountE4] {
    planStates(goals: goals, rows: rows, month: month, rates: rates).compactMapValues { state in
      state.restThisMonth.raw > 0 ? state.restThisMonth : nil
    }
  }

  /// Where the monthly plan of a goal stands in `month` (`GoalPlanState`); `nil` for an
  /// archived goal and for one without a plan above zero.
  public static func planState(
    goal: Goal, rows: [LedgerRow], month: MonthKey, rates: DayRates
  ) -> GoalPlanState? {
    planStates(goals: [goal], rows: rows, month: month, rates: rates)[goal.id]
  }

  /// `planState` of every live goal with a plan, the rows read once.
  ///
  /// The plan counts from `goal.planStartMonth`, else from the month of the goal's first
  /// contribution, else from `month`. Every month from there to the one before `month` adds
  /// what went in above its plan to a credit and takes what fell short of it from the credit —
  /// never below zero: a month below plan is not held back later. This month's plan asks what
  /// the credit and this month's contributions do not cover; what they give beyond it is the
  /// credit for the months after this one.
  public static func planStates(
    goals: [Goal], rows: [LedgerRow], month: MonthKey, rates: DayRates
  ) -> [UUID: GoalPlanState] {
    let planned = goals.filter { goal in
      guard !goal.archived, let plan = goal.monthlyPlanE4 else { return false }
      return plan.raw > 0
    }
    guard !planned.isEmpty else { return [:] }
    var saved = Array(repeating: AmountE4.zero, count: planned.count)
    var byMonth = Array(repeating: [MonthKey: AmountE4](), count: planned.count)
    var firstMonth = [MonthKey?](repeating: nil, count: planned.count)
    for row in rows where row.kind == .expense || row.kind == .refund {
      for (index, goal) in planned.enumerated() {
        guard let amount = contribution(of: row, to: goal, rates: rates), !amount.isZero else {
          continue
        }
        saved[index] += amount
        byMonth[index][row.day.monthKey, default: .zero] += amount
        if firstMonth[index] == nil { firstMonth[index] = row.day.monthKey }
      }
    }
    var result: [UUID: GoalPlanState] = [:]
    for (index, goal) in planned.enumerated() {
      let plan = goal.monthlyPlanE4 ?? .zero
      let start = goal.planStartMonth ?? firstMonth[index] ?? month
      var credit = AmountE4.zero
      if start < month {
        for current in MonthKey.range(start, through: month.previous) {
          credit = max(.zero, credit + (byMonth[index][current] ?? .zero) - plan)
        }
      }
      let thisMonth = byMonth[index][month] ?? .zero
      let needed = max(.zero, goal.targetE4 - saved[index])
      let rest = min(plan, max(.zero, plan - credit - thisMonth), needed)
      result[goal.id] = GoalPlanState(
        creditIn: credit, thisMonth: thisMonth, restThisMonth: rest,
        creditOut: max(.zero, credit + thisMonth - plan))
    }
    return result
  }

  /// What is saved in each goal counted in the rubles its contributions cost, at the rate of
  /// their own day — «по курсу взносов», for the owner who keeps a foreign goal's money in
  /// rubles. A running average cost: a contribution adds its units and its rubles; a
  /// withdrawal takes rubles in proportion to the units it takes, so money in equals money out
  /// and nothing is ever left negative. A row without a rate for the goal's currency is left
  /// out, as it is of `saved`. A ruble goal is its rubles either way. Goals with nothing saved
  /// are not in the map.
  public static func savedRubAtContributions(
    goals: [Goal], rows: [LedgerRow], rates: DayRates
  ) -> [UUID: AmountE4] {
    let live = goals.filter { !$0.archived }
    guard !live.isEmpty else { return [:] }
    var units = Array(repeating: AmountE4.zero, count: live.count)
    var rubles = Array(repeating: AmountE4.zero, count: live.count)
    for row in rows where row.kind == .expense || row.kind == .refund {
      for (index, goal) in live.enumerated() {
        guard let amount = contribution(of: row, to: goal, rates: rates), !amount.isZero else {
          continue
        }
        if amount.raw > 0 {
          units[index] += amount
          rubles[index] += row.amountRubE4
        } else {
          if units[index].raw > 0 {
            let taken = min(amount.magnitude, units[index])
            rubles[index] =
              rubles[index]
              - AmountE4.rounded(rubles[index].decimal * taken.decimal / units[index].decimal)
          }
          units[index] += amount
          if units[index].raw <= 0 {
            units[index] = .zero
            rubles[index] = .zero
          }
        }
      }
    }
    var result: [UUID: AmountE4] = [:]
    for (index, goal) in live.enumerated() where units[index].raw > 0 {
      result[goal.id] = rubles[index]
    }
    return result
  }
}

/// Where the monthly plan of a goal stands in one month, in the goal's currency.
public struct GoalPlanState: Hashable, Sendable {
  /// Paid in above the plans of the months before this one, since the plan started.
  public var creditIn: AmountE4
  /// Net contributions of this month (a withdrawal makes it negative).
  public var thisMonth: AmountE4
  /// What this month's plan still asks: min(plan, max(0, plan − creditIn − thisMonth)), never
  /// more than the goal still needs.
  public var restThisMonth: AmountE4
  /// Credit left for the months after this one: max(0, creditIn + thisMonth − plan).
  public var creditOut: AmountE4

  public init(
    creditIn: AmountE4, thisMonth: AmountE4, restThisMonth: AmountE4, creditOut: AmountE4
  ) {
    self.creditIn = creditIn
    self.thisMonth = thisMonth
    self.restThisMonth = restThisMonth
    self.creditOut = creditOut
  }
}
