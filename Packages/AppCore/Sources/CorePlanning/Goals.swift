import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation

/// How realistic a goal is — the word the Goals card and the goal advice put next to it.
public enum GoalRealism: String, Hashable, Sendable, CaseIterable {
  /// Everything is saved.
  case reached
  /// At the pace below, the target date is met.
  case onTrack
  /// At the pace below, the target date is missed.
  case behindPlan
  /// The target date has passed and something is still missing.
  case overdue
  /// No target date: there is nothing to be late for.
  case noDate
  /// A date, but neither a monthly plan nor contributions of the last complete months to
  /// judge by.
  case notEnoughData
}

/// Where the monthly pace of a goal comes from.
public enum GoalPaceSource: String, Hashable, Sendable, CaseIterable {
  /// The monthly plan of the goal.
  case plan
  /// The average net contribution of the last complete months.
  case history
}

/// One goal with its progress and its outlook. Every amount is in the goal's currency
/// (`currency`): a ruble goal counts rubles, a dollar goal dollars — a contribution in another
/// currency counts at the rate of its own day (`GoalMath`).
public struct GoalStatus: Hashable, Sendable, Identifiable {
  public var goal: Goal
  /// Everything contributed, net of withdrawals, over the whole history.
  public var saved: AmountE4
  /// max(0, target − saved).
  public var remaining: AmountE4
  /// saved ÷ target in basis points, rounded down and kept within 0…10 000, so 100 % means
  /// the goal is really reached.
  public var progressBp: Int
  /// Net contributions dated in the current month.
  public var contributedThisMonth: AmountE4
  /// What has to go in every month from this one through the month of the target date;
  /// the whole remainder once the date has passed; `nil` without a date.
  public var neededMonthly: AmountE4?
  /// Months from this one through the month of the target date, both included; 0 once the
  /// date has passed; `nil` without a date.
  public var monthsLeft: Int?
  /// The monthly pace the outlook assumes: the plan, else the average net contribution of
  /// the last complete months (at most three); `nil` when there is no plan and the goal had
  /// no contribution or withdrawal in those months.
  public var pace: AmountE4?
  public var paceSource: GoalPaceSource?
  public var realism: GoalRealism
  /// The month the goal is reached in at `pace`; `nil` when it is reached already or the
  /// pace does not move it forward.
  public var projectedCompletion: MonthKey?
  /// What will be saved by the target date at `pace`; `nil` without a date, without a pace
  /// or once the date has passed.
  public var amountByTargetDate: AmountE4?
  /// Whether «can save this month» (P50) covers `neededMonthly` at today's rate; `nil` when
  /// either is unknown or the goal's currency has no rate today.
  public var coveredByCanSave: Bool?
  /// Rubles for one unit of the goal's currency today; 1 for a ruble goal, `nil` when no rate
  /// is known.
  public var rubPerUnit: Decimal?
  /// Contributions and withdrawals left out of the figures: in another currency, on a day no
  /// rate of the goal's currency is known for.
  public var withoutRate: Int

  public var id: UUID { goal.id }
  /// The currency every amount of the status is in.
  public var currency: CurrencyCode { goal.currency }
  /// What is saved, in rubles at today's rate; `nil` without a rate. The grey line of the free
  /// sum holds it back (`CashPlan.goalSavings`): the money is on the accounts, but not free.
  public var savedRubToday: AmountE4? { rubles(saved) }

  public init(
    goal: Goal, saved: AmountE4, remaining: AmountE4, progressBp: Int,
    contributedThisMonth: AmountE4, neededMonthly: AmountE4?, monthsLeft: Int?,
    pace: AmountE4?, paceSource: GoalPaceSource?, realism: GoalRealism,
    projectedCompletion: MonthKey?, amountByTargetDate: AmountE4?, coveredByCanSave: Bool?,
    rubPerUnit: Decimal? = nil, withoutRate: Int = 0
  ) {
    self.goal = goal
    self.saved = saved
    self.remaining = remaining
    self.progressBp = progressBp
    self.contributedThisMonth = contributedThisMonth
    self.neededMonthly = neededMonthly
    self.monthsLeft = monthsLeft
    self.pace = pace
    self.paceSource = paceSource
    self.realism = realism
    self.projectedCompletion = projectedCompletion
    self.amountByTargetDate = amountByTargetDate
    self.coveredByCanSave = coveredByCanSave
    self.rubPerUnit = goal.currency == .rub ? 1 : rubPerUnit
    self.withoutRate = withoutRate
  }

  /// An amount of the goal's currency in rubles at today's rate; `nil` without a rate.
  public func rubles(_ amount: AmountE4) -> AmountE4? {
    guard currency != .rub else { return amount }
    guard let rubPerUnit, rubPerUnit > 0 else { return nil }
    return SavingsMath.rounded(amount.decimal * rubPerUnit)
  }
}

/// Goals: progress, the contribution a goal needs, how realistic it is, and the operations
/// «Contribute» and «Withdraw» write.
///
/// A row belongs to a goal when it carries the goal's id, or when it carries no goal at all
/// and is filed under the goal's subcategory; a contribution is an `expense` and adds, a
/// withdrawal is a `refund` and takes off. The rule is `GoalMath`, which `PlannedPayments`
/// applies to the forecast too, so the goals of the planned month and of the forecast are one
/// figure. Everything is counted in the goal's currency: a contribution in another currency at
/// the rate of its own day (`rates`, rubles for one unit), and whatever is shown in rubles at
/// today's rate (`rubPerUnit`).
public enum GoalRules {
  /// Complete months the pace of a goal without a plan is averaged over.
  public static let historyMonths = 3

  // MARK: - Statuses

  /// The statuses of the goals that are not archived, in the order given.
  ///
  /// `canSaveP50` is «can save this month» (`CanSave.p50`) when the caller has it: every
  /// goal then says whether that covers its needed contribution. `rates` are the rates by day
  /// a contribution in another currency counts at; `rubPerUnit` today's rates, for what the
  /// status shows in rubles. A ruble goal needs neither.
  public static func statuses(
    goals: [Goal], ledger: Ledger, today: DateOnly, canSaveP50: AmountE4? = nil,
    rates: DayRates = .empty, rubPerUnit: [CurrencyCode: Decimal] = [:]
  ) -> [GoalStatus] {
    let live = goals.filter { !$0.archived }
    guard !live.isEmpty else { return [] }
    let month = today.monthKey
    let historyStart = ledger.firstDay?.monthKey
    let historyMonths = Set(
      SavingsMath.completeMonths(
        before: month, historyStart: historyStart, count: Self.historyMonths))

    // One pass over the ledger for every goal: the rows are many, the goals are few.
    var byId: [UUID: Int] = [:]
    var bySubcategory: [UUID: Int] = [:]
    for (index, goal) in live.enumerated() {
      if byId[goal.id] == nil { byId[goal.id] = index }
      if let subcategory = goal.subcategoryId, bySubcategory[subcategory] == nil {
        bySubcategory[subcategory] = index
      }
    }
    var sums = Array(repeating: Sums(), count: live.count)
    let firstOfMonth = month.firstDay
    for row in ledger.rows where row.kind == .expense || row.kind == .refund {
      let index: Int?
      if let goalId = row.goalId {
        index = byId[goalId]
      } else {
        index = row.categoryId.flatMap { bySubcategory[$0] }
      }
      guard let index else { continue }
      guard let amount = GoalMath.contribution(of: row, to: live[index], rates: rates) else {
        sums[index].withoutRate += 1
        continue
      }
      sums[index].saved += amount
      if row.day < firstOfMonth {
        sums[index].before += amount
      } else if row.day.monthKey == month {
        sums[index].thisMonth += amount
      }
      if historyMonths.contains(row.day.monthKey) {
        sums[index].history += amount
        sums[index].historyRows += 1
      }
    }

    return live.enumerated().map { index, goal in
      status(
        of: goal, sums: sums[index], today: today, historyMonthCount: historyMonths.count,
        canSaveP50: canSaveP50,
        rubPerUnit: goal.currency == .rub ? 1 : rubPerUnit[goal.currency])
    }
  }

  /// What a row adds to a goal, in the goal's currency (`GoalMath.contribution`): plus for a
  /// contribution, minus for a withdrawal, zero for a row of another goal and for anything
  /// else; `nil` when the row is in another currency and no rate of the goal's is known.
  public static func contribution(
    of row: LedgerRow, to goal: Goal, rates: DayRates
  ) -> AmountE4? {
    GoalMath.contribution(of: row, to: goal, rates: rates)
  }

  /// What the monthly plan of each live goal still asks this month, by goal: max(0, plan −
  /// net contributions this month), never more than the plan itself and capped by what the
  /// goal still needs, max(0, target − saved). A reached goal asks nothing, and one 3 000
  /// short asks 3 000 even with a plan of 10 000: a plan payment the goal no longer needs is
  /// not an unmade contribution. Money taken back out of this month's contributions unmakes
  /// them, but a withdrawal of earlier months' savings is not this month's plan: with a plan
  /// of 3 000 and 5 000 withdrawn the goal asks 3 000, not 8 000. Goals
  /// without a plan, or with nothing left to ask, are not in the map.
  ///
  /// Each amount is in its goal's currency (`GoalMath.planLeft`): the planned month turns it
  /// into rubles at today's rate (`PlannedMonth.goals`), and so do the goal reserve of the
  /// planning snapshot and `PlannedPayments.goals` of the forecast, which applies the same
  /// rule — the figures stay one. The free sum asks the rest of this month's plan the same
  /// way and adds the plans of the later months up to its day (`CashPlan`).
  public static func planStillDue(
    goals: [Goal], ledger: Ledger, today: DateOnly, rates: DayRates = .empty
  ) -> [UUID: AmountE4] {
    GoalMath.planLeft(goals: goals, rows: ledger.rows, month: today.monthKey, rates: rates)
  }

  /// Net contributions to all goals — to any goal, or filed anywhere under the system Goals
  /// category — over the days of the span, by date: what «already saved» and the savings
  /// rate count.
  public static func netContributions(ledger: Ledger, in range: DayRange) -> AmountE4 {
    var total = AmountE4.zero
    for row in ledger.rows(in: range) where row.isGoalContribution {
      switch row.kind {
      case .expense: total += row.amountRubE4
      case .refund: total += -row.amountRubE4
      case .income, .reimbursement: continue
      }
    }
    return total
  }

  private struct Sums {
    var saved = AmountE4.zero
    /// Rows dated before the 1st of this month.
    var before = AmountE4.zero
    var thisMonth = AmountE4.zero
    /// Rows of the complete months the pace is averaged over.
    var history = AmountE4.zero
    var historyRows = 0
    /// Rows left out for want of a rate.
    var withoutRate = 0
  }

  private static func status(
    of goal: Goal, sums: Sums, today: DateOnly, historyMonthCount: Int, canSaveP50: AmountE4?,
    rubPerUnit: Decimal?
  ) -> GoalStatus {
    let month = today.monthKey
    let target = goal.targetE4
    let saved = sums.saved
    let remaining = max(.zero, target - saved)
    let reached = remaining.isZero
    let thisMonth = sums.thisMonth
    // What this month already did towards its own share. A withdrawal this month is not a
    // share done: it raises what the months left have to bring.
    let doneThisMonth = max(.zero, thisMonth)

    let pace: AmountE4?
    let paceSource: GoalPaceSource?
    if let plan = goal.monthlyPlanE4, plan.raw > 0 {
      pace = plan
      paceSource = .plan
    } else if historyMonthCount > 0, sums.historyRows > 0 {
      // Without a single row in those months the goal may be new: nothing to judge by.
      pace = SavingsMath.divide(sums.history, by: historyMonthCount)
      paceSource = .history
    } else {
      pace = nil
      paceSource = nil
    }

    var neededMonthly: AmountE4?
    var monthsLeft: Int?
    var amountByTargetDate: AmountE4?
    let overdue = goal.targetDate.map { today > $0 } ?? false
    if let date = goal.targetDate {
      if overdue {
        monthsLeft = 0
        neededMonthly = remaining
      } else {
        // The target month itself is one of the months to save in.
        let months = max(1, month.months(to: date.monthKey) + 1)
        monthsLeft = months
        // Counted from what stood before this month, so the figure does not shrink while
        // this month's own contribution is being made.
        let baseline = sums.before + min(.zero, thisMonth)
        // Rounded up to whole units of the goal's currency, the figure the screen shows:
        // paying it every month must reach the target, so a plan typed from it reads
        // «on track».
        neededMonthly =
          reached
          ? .zero : SavingsMath.ceilingWhole(max(.zero, target - baseline), by: months)
        if let pace {
          // This month adds only what is left of its pace; every later month adds the pace.
          let thisMonthLeft = max(.zero, pace - doneThisMonth)
          amountByTargetDate = saved + thisMonthLeft + SavingsMath.times(pace, months - 1)
        }
      }
    }

    var projectedCompletion: MonthKey?
    if !reached, let pace, pace.raw > 0 {
      let thisMonthLeft = max(.zero, pace - doneThisMonth)
      if remaining <= thisMonthLeft {
        projectedCompletion = month
      } else {
        let months = SavingsMath.ceilingQuotient(remaining - thisMonthLeft, pace)
        projectedCompletion = month.adding(months: months)
      }
    }

    let realism: GoalRealism
    if reached {
      realism = .reached
    } else if goal.targetDate == nil {
      realism = .noDate
    } else if overdue {
      realism = .overdue
    } else if let amountByTargetDate {
      realism = amountByTargetDate >= target ? .onTrack : .behindPlan
    } else {
      realism = .notEnoughData
    }

    var result = GoalStatus(
      goal: goal, saved: saved, remaining: remaining,
      progressBp: progressBasisPoints(saved: saved, target: target),
      contributedThisMonth: thisMonth, neededMonthly: neededMonthly, monthsLeft: monthsLeft,
      pace: pace, paceSource: paceSource, realism: realism,
      projectedCompletion: projectedCompletion, amountByTargetDate: amountByTargetDate,
      coveredByCanSave: nil, rubPerUnit: rubPerUnit, withoutRate: sums.withoutRate)
    // «Can save» is in rubles: the goal's need is compared at today's rate.
    if let canSaveP50, let neededMonthly, let needed = result.rubles(neededMonthly) {
      result.coveredByCanSave = needed <= canSaveP50
    }
    return result
  }

  /// saved ÷ target in basis points, rounded down: 99.99 % must not read as 100 %.
  static func progressBasisPoints(saved: AmountE4, target: AmountE4) -> Int {
    guard target.raw > 0 else { return Shares.whole }
    guard saved.raw > 0 else { return 0 }
    guard saved < target else { return Shares.whole }
    let product = Int64(Shares.whole).multipliedFullWidth(by: saved.raw)
    let (quotient, _) = target.raw.dividingFullWidth(product)
    return Int(quotient)
  }

  // MARK: - The month a plan counts from

  /// The goal as it is saved, with the month its monthly plan counts from: the month of
  /// `today` when a plan appears — on a new goal, or on one that had none or a plan of zero —,
  /// none once the plan is taken away, and otherwise the month stored before (`previous`): a
  /// new amount, a new name or a new date moves nothing. Money put in before that month is
  /// not counted as paid ahead of the plan.
  public static func withPlanStart(_ goal: Goal, previous: Goal?, today: DateOnly) -> Goal {
    func planned(_ goal: Goal?) -> Bool {
      guard let plan = goal?.monthlyPlanE4 else { return false }
      return plan > .zero
    }
    var saved = goal
    if !planned(goal) {
      saved.planStartMonth = nil
    } else if !planned(previous) {
      saved.planStartMonth = today.monthKey
    } else {
      saved.planStartMonth = previous?.planStartMonth
    }
    return saved
  }

  // MARK: - Contribute and Withdraw

  /// «Contribute»: an expense of one part in the goal's subcategory, tied to the goal. The
  /// part is `good` with the source `system`, as `QualityResolver` fixes every goal
  /// contribution — the panel must not offer another rating. The category is the app's
  /// choice, so its source is `system` too. The amount is taken without its sign, in
  /// `currency` — rubles unless the form asks for another, such as the goal's own; the
  /// operation's rubles then come from the rate of its day, as for any operation.
  public static func contributionDraft(
    goal: Goal, subcategoryId: UUID?, amount: AmountE4, occurredAt: Date,
    paymentMethodId: UUID? = nil, note: String? = nil, currency: CurrencyCode = .rub
  ) -> TransactionDraft {
    draft(
      .expense, goal: goal, subcategoryId: subcategoryId, amount: amount,
      occurredAt: occurredAt, paymentMethodId: paymentMethodId, note: note, currency: currency)
  }

  /// «Withdraw»: a refund with the same part. It takes the money off the goal's progress and
  /// off my expenses, exactly as the contribution added it.
  public static func withdrawalDraft(
    goal: Goal, subcategoryId: UUID?, amount: AmountE4, occurredAt: Date,
    paymentMethodId: UUID? = nil, note: String? = nil, currency: CurrencyCode = .rub
  ) -> TransactionDraft {
    draft(
      .refund, goal: goal, subcategoryId: subcategoryId, amount: amount,
      occurredAt: occurredAt, paymentMethodId: paymentMethodId, note: note, currency: currency)
  }

  private static func draft(
    _ kind: TransactionKind, goal: Goal, subcategoryId: UUID?, amount: AmountE4,
    occurredAt: Date, paymentMethodId: UUID?, note: String?, currency: CurrencyCode
  ) -> TransactionDraft {
    let categoryId = subcategoryId ?? goal.subcategoryId
    let decision = QualityResolver.resolve(goalId: goal.id, categoryId: categoryId)
    let amount = amount.magnitude
    let part = PartDraft(
      categoryId: categoryId, categorySource: .system, quality: decision.quality,
      qualitySource: decision.source, amount: amount, forWhom: .me, goalId: goal.id)
    return TransactionDraft(
      kind: kind, occurredAt: occurredAt, currency: currency, amount: amount,
      note: note, paymentMethodId: paymentMethodId, parts: [part])
  }
}

/// The few operations on rubles the savings figures need, each rounding half away from zero.
/// Kept apart from the planning types of the other files so no helper of theirs
/// is shadowed.
enum SavingsMath {
  static func rounded(_ value: Decimal) -> AmountE4 {
    (try? AmountE4(decimal: value)) ?? (value < 0 ? AmountE4(raw: .min) : AmountE4(raw: .max))
  }

  /// amount ÷ count, rounded; `count` below 1 counts as 1.
  static func divide(_ amount: AmountE4, by count: Int) -> AmountE4 {
    rounded(amount.decimal / Decimal(max(1, count)))
  }

  static func times(_ amount: AmountE4, _ count: Int) -> AmountE4 {
    rounded(amount.decimal * Decimal(count))
  }

  /// The last `count` complete months before `month`, oldest first, none of them before the
  /// month the history starts in. Like the average of the Reports, the first
  /// month counts even when the history starts inside it.
  static func completeMonths(
    before month: MonthKey, historyStart: MonthKey?, count: Int
  )
    -> [MonthKey]
  {
    guard let historyStart, historyStart < month, count > 0 else { return [] }
    let first = max(historyStart, month.adding(months: -count))
    return MonthKey.range(first, through: month.previous)
  }

  /// amount ÷ count rounded up to whole units: count × the result is never below the
  /// amount. `count` below 1 counts as 1; an amount not above zero gives zero.
  static func ceilingWhole(_ amount: AmountE4, by count: Int) -> AmountE4 {
    guard amount.raw > 0 else { return .zero }
    let unit = AmountE4(whole: 1).raw
    let (step, overflow) = Int64(max(1, count)).multipliedReportingOverflow(by: unit)
    guard !overflow else { return AmountE4(raw: unit) }
    let (quotient, remainder) = amount.raw.quotientAndRemainder(dividingBy: step)
    let wholes = quotient + (remainder > 0 ? 1 : 0)
    let (raw, tooBig) = wholes.multipliedReportingOverflow(by: unit)
    return tooBig ? amount : AmountE4(raw: raw)
  }

  /// ⌈amount ÷ step⌉ for a positive step; 0 when the amount is not positive.
  static func ceilingQuotient(_ amount: AmountE4, _ step: AmountE4) -> Int {
    guard amount.raw > 0, step.raw > 0 else { return 0 }
    let (quotient, remainder) = amount.raw.quotientAndRemainder(dividingBy: step.raw)
    return Int(quotient) + (remainder > 0 ? 1 : 0)
  }
}
