import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation

/// The goal of the cushion: N months of obligatory spending, and how to get there.
public struct CushionGoalStatus: Hashable, Sendable {
  public var targetMonths: Int
  /// N × the monthly obligatory spending.
  public var targetRub: AmountE4
  /// What is still missing; zero once reached.
  public var missingRub: AmountE4
  /// What to put aside per month to be done by the target month; `nil` without one.
  public var perMonthRub: AmountE4?
  /// What to put aside per month without a target month: a twelfth of what is missing.
  public var defaultPerMonthRub: AmountE4
  /// How the cushion grew per month lately; `nil` without enough month ends.
  public var pacePerMonthRub: AmountE4?
  /// The month the goal is reached at that pace; `nil` when it never is.
  public var reachedBy: MonthKey?
  public var reached: Bool

  public init(
    targetMonths: Int, targetRub: AmountE4, missingRub: AmountE4, perMonthRub: AmountE4?,
    defaultPerMonthRub: AmountE4, pacePerMonthRub: AmountE4?, reachedBy: MonthKey?,
    reached: Bool
  ) {
    self.targetMonths = targetMonths
    self.targetRub = targetRub
    self.missingRub = missingRub
    self.perMonthRub = perMonthRub
    self.defaultPerMonthRub = defaultPerMonthRub
    self.pacePerMonthRub = pacePerMonthRub
    self.reachedBy = reachedBy
    self.reached = reached
  }
}

/// The safety cushion: the money of the accounts marked as the cushion, and how many months
/// of obligatory spending it lasts.
public struct CushionStatus: Hashable, Sendable {
  public enum State: String, Hashable, Sendable {
    /// No account is marked as the cushion.
    case noAccounts
    /// The obligatory spending is not known yet (`ObligatorySpending.State.notEnoughData`).
    case notEnoughData
    case ready
  }

  /// The money of the cushion accounts now, in rubles.
  public var moneyRub: AmountE4
  /// The part of `moneyRub` on accounts in the summary: what the free sum leaves out when the
  /// setting says so.
  public var inSummaryRub: AmountE4
  /// The accounts marked as the cushion.
  public var accounts: [UUID]
  /// Their balances never counted.
  public var unanchored: [BalanceKey]
  public var obligatory: ObligatorySpending
  /// `moneyRub` ÷ the monthly obligatory spending, floored to a tenth; `nil` without it.
  public var months: Decimal?
  public var goal: CushionGoalStatus?
  public var state: State

  public init(
    moneyRub: AmountE4, inSummaryRub: AmountE4 = .zero, accounts: [UUID],
    unanchored: [BalanceKey], obligatory: ObligatorySpending, months: Decimal?,
    goal: CushionGoalStatus?, state: State
  ) {
    self.moneyRub = moneyRub
    self.inSummaryRub = inSummaryRub
    self.accounts = accounts
    self.unanchored = unanchored
    self.obligatory = obligatory
    self.months = months
    self.goal = goal
    self.state = state
  }

  public static let empty = CushionStatus(
    moneyRub: .zero, accounts: [], unanchored: [], obligatory: .empty, months: nil, goal: nil,
    state: .noAccounts)
}

/// Builds the status of the cushion.
///
/// * **Money** — the balances now of the live accounts marked as the cushion, at today's rate,
///   as the sidebar shows them; `inSummaryRub` is the part on accounts in the summary.
/// * **Months** — the money ÷ the monthly obligatory spending, floored to a tenth, never below
///   zero; none while that spending is not known or is nothing.
/// * **Goal** — N months of that spending, rounded up to 1,000 ₽; what is missing, and to put it
///   aside: by the target month — what is missing over the months left, at least one (saving at
///   the end of this month counts), rounded up to 100 ₽ —, or else a twelfth of it, rounded the
///   same. The pace is how the cushion grew per month over the last three month ends (fewer
///   when there are fewer, at least two), and the month it is reached at that pace; a pace that
///   is not above zero reaches nothing.
public enum CushionRules {
  /// The goal is rounded up to this many rubles.
  public static let goalStep = AmountE4(whole: 1_000)
  /// What to put aside per month is rounded up to this many rubles.
  public static let perMonthStep = AmountE4(whole: 100)
  /// The month ends the pace looks back over.
  public static let paceMonths = 3

  public static func status(
    capital: CapitalSnapshot, obligatory: ObligatorySpending, accounts: AccountsSnapshot,
    settings: CapitalSettings, today: DateOnly
  ) -> CushionStatus {
    var money = AmountE4.zero
    var inSummary = AmountE4.zero
    var ids: [UUID] = []
    var unanchored: [BalanceKey] = []
    for section in accounts.sections {
      for line in section.accounts where line.account.cushion && !line.account.archived {
        ids.append(line.account.id)
        for key in line.keys {
          if let rub = key.rub {
            money += rub
            if section.inSummary { inSummary += rub }
          } else if key.balance == nil, key.isHeld {
            unanchored.append(key.key)
          }
        }
      }
    }
    guard !ids.isEmpty else {
      var empty = CushionStatus.empty
      empty.obligatory = obligatory
      return empty
    }
    guard let monthly = obligatory.monthlyRub else {
      return CushionStatus(
        moneyRub: money, inSummaryRub: inSummary, accounts: ids, unanchored: unanchored,
        obligatory: obligatory, months: nil, goal: nil, state: .notEnoughData)
    }
    let goal = settings.targetMonths.map {
      goalStatus(
        targetMonths: $0, targetMonth: settings.targetMonth, money: money, monthly: monthly,
        capital: capital, today: today)
    }
    return CushionStatus(
      moneyRub: money, inSummaryRub: inSummary, accounts: ids, unanchored: unanchored,
      obligatory: obligatory, months: months(money: money, monthly: monthly), goal: goal,
      state: .ready)
  }

  /// `money` ÷ `monthly`, floored to a tenth and never below zero; `nil` when `monthly` is not
  /// above zero.
  public static func months(money: AmountE4, monthly: AmountE4) -> Decimal? {
    guard monthly.raw > 0 else { return nil }
    guard money.raw > 0 else { return 0 }
    let tenths = money.raw.multipliedReportingOverflow(by: 10)
    let count =
      tenths.overflow
      ? (money.raw / monthly.raw) * 10 + (money.raw % monthly.raw) * 10 / monthly.raw
      : tenths.partialValue / monthly.raw
    return Decimal(count) / 10
  }

  static func goalStatus(
    targetMonths: Int, targetMonth: MonthKey?, money: AmountE4, monthly: AmountE4,
    capital: CapitalSnapshot, today: DateOnly
  ) -> CushionGoalStatus {
    let target = roundedUp(
      SubscriptionMath.rounded(monthly.decimal * Decimal(targetMonths)), to: goalStep)
    let missing = max(.zero, target - money)
    let reached = missing.isZero
    let perMonth = targetMonth.map { month in
      let left = max(1, today.monthKey.months(to: month))
      return share(of: missing, over: left, roundedUpTo: perMonthStep)
    }
    let defaultPerMonth = share(of: missing, over: 12, roundedUpTo: perMonthStep)
    let pace = self.pace(capital: capital)
    var reachedBy: MonthKey?
    if reached {
      reachedBy = today.monthKey
    } else if let pace, pace.raw > 0 {
      let needed = (missing.raw + pace.raw - 1) / pace.raw
      reachedBy = today.monthKey.adding(months: Int(clamping: needed) - 1)
    }
    return CushionGoalStatus(
      targetMonths: targetMonths, targetRub: target, missingRub: missing, perMonthRub: perMonth,
      defaultPerMonthRub: defaultPerMonth, pacePerMonthRub: pace, reachedBy: reachedBy,
      reached: reached)
  }

  /// How the cushion grew per month over the last `paceMonths` month ends: the change from the
  /// earliest of them to the latest over the months between; `nil` with fewer than two.
  public static func pace(capital: CapitalSnapshot) -> AmountE4? {
    let ends = capital.points.filter { !$0.isNow }.suffix(paceMonths + 1)
    guard let first = ends.first, let last = ends.last, ends.count >= 2 else { return nil }
    return SavingsMath.divide(last.cushionRub - first.cushionRub, by: ends.count - 1)
  }

  /// ⌈`amount` ÷ `count`⌉ in whole `step`s: `count` such shares are never less than the amount.
  static func share(of amount: AmountE4, over count: Int, roundedUpTo step: AmountE4) -> AmountE4 {
    guard amount.raw > 0 else { return .zero }
    let (portion, overflow) = step.raw.multipliedReportingOverflow(by: Int64(max(1, count)))
    guard !overflow else { return step }
    let steps = amount.raw / portion + (amount.raw % portion > 0 ? 1 : 0)
    return AmountE4(raw: steps * step.raw)
  }

  /// `amount` rounded up to a whole number of `step`; zero and less stay as they are.
  static func roundedUp(_ amount: AmountE4, to step: AmountE4) -> AmountE4 {
    guard amount.raw > 0, step.raw > 0 else { return amount }
    let steps = (amount.raw + step.raw - 1) / step.raw
    return AmountE4(raw: steps * step.raw)
  }
}
