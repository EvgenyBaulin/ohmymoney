import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation

/// The income category the savings rate counts when it is set to «only earnings».
public enum EarningsCategory {
  /// The names of the top-level income category the app starts with, folded.
  static let names = ["заработок", "earnings"]

  /// The chosen category when it is a live income category, else the top-level income category
  /// called «Заработок» / «Earnings»; `nil` when there is neither.
  public static func resolve(chosen: UUID?, in categories: [CoreKit.Category]) -> UUID? {
    if let chosen,
      categories.contains(where: { $0.id == chosen && $0.kind == .income && !$0.archived })
    {
      return chosen
    }
    return categories.first {
      $0.parentId == nil && $0.kind == .income && !$0.archived
        && names.contains(NameKey.fold($0.name))
    }?.id
  }
}

/// The savings rate of one month, with everything it is made of.
///
/// «Kept» is the income less what I spent **without** the contributions to goals: a goal
/// contribution is money put aside, not spent. The spending shown elsewhere (`spendingRub`)
/// still counts it, so a screen that shows both says why they differ.
public struct SavingsNormMonth: Hashable, Sendable {
  public enum State: Hashable, Sendable {
    case ready
    /// No positive income in the month: no rate, whatever was spent.
    case noIncome
  }

  public var month: MonthKey
  /// The income the rate is measured against: all income of the month, or only the earnings
  /// category when asked.
  public var incomeRub: AmountE4
  /// My expenses of the month by date, goal contributions included — the figure of the other
  /// screens.
  public var spendingRub: AmountE4
  /// My expenses without the goal contributions.
  public var spendingWithoutGoalsRub: AmountE4
  /// Contributions to goals less what was taken back, by date.
  public var goalsNetRub: AmountE4
  /// Money moved to the cushion accounts in the month; informational: a transfer is not
  /// spending, so it is already in «kept».
  public var cushionDepositsRub: AmountE4
  /// `incomeRub` − `spendingWithoutGoalsRub`; negative when more was spent than came.
  public var keptRub: AmountE4
  /// `keptRub` ÷ `incomeRub` in basis points, rounded half away from zero; negative for a month
  /// in the red; `nil` without positive income.
  public var rateBp: Int?
  /// The same rate with goal contributions counted as spending: (income − spending) ÷ income.
  public var rateWithGoalsAsSpendingBp: Int?
  /// The month is not over: the spending is still to come, the rate looks better than it
  /// will be.
  public var isPartial: Bool
  /// «Only earnings» was asked for but no earnings category exists: all income was taken.
  public var earningsFallback: Bool
  public var state: State

  public init(
    month: MonthKey, incomeRub: AmountE4, spendingRub: AmountE4,
    spendingWithoutGoalsRub: AmountE4, goalsNetRub: AmountE4, cushionDepositsRub: AmountE4,
    keptRub: AmountE4, rateBp: Int?, rateWithGoalsAsSpendingBp: Int?, isPartial: Bool,
    earningsFallback: Bool, state: State
  ) {
    self.month = month
    self.incomeRub = incomeRub
    self.spendingRub = spendingRub
    self.spendingWithoutGoalsRub = spendingWithoutGoalsRub
    self.goalsNetRub = goalsNetRub
    self.cushionDepositsRub = cushionDepositsRub
    self.keptRub = keptRub
    self.rateBp = rateBp
    self.rateWithGoalsAsSpendingBp = rateWithGoalsAsSpendingBp
    self.isPartial = isPartial
    self.earningsFallback = earningsFallback
    self.state = state
  }
}

/// The savings rate by month.
public enum SavingsNorm {
  /// One month. `cushionDeposits` is what moved to the cushion accounts in it, as the caller
  /// knows from the transfers.
  public static func month(
    _ month: MonthKey, ledger: Ledger, today: DateOnly, earningsOnly: Bool = false,
    earningsCategoryId: UUID? = nil, cushionDeposits: AmountE4 = .zero
  ) -> SavingsNormMonth {
    let span = DayRange(month.firstDay, month.lastDay)
    var spending = AmountE4.zero
    var withoutGoals = AmountE4.zero
    for row in ledger.rows(in: span) {
      spending += row.contribution
      if !row.isGoalContribution { withoutGoals += row.contribution }
    }
    let goalsNet = GoalRules.netContributions(ledger: ledger, in: span)

    var fallback = false
    let income: AmountE4
    if earningsOnly {
      if let root = EarningsCategory.resolve(
        chosen: earningsCategoryId, in: ledger.dataset.categories)
      {
        income = AmountE4.sum(
          ledger.rows(attributedTo: [month]).lazy
            .filter { $0.kind == .income && $0.rootCategoryId == root }
            .map(\.amountRubE4))
      } else {
        fallback = true
        income = ledger.income(attributedTo: [month])
      }
    } else {
      income = ledger.income(attributedTo: [month])
    }

    let kept = income - withoutGoals
    let positive = income.raw > 0
    return SavingsNormMonth(
      month: month, incomeRub: income, spendingRub: spending,
      spendingWithoutGoalsRub: withoutGoals, goalsNetRub: goalsNet,
      cushionDepositsRub: cushionDeposits, keptRub: kept,
      rateBp: positive ? signedRatio(kept, of: income) : nil,
      rateWithGoalsAsSpendingBp: positive ? signedRatio(income - spending, of: income) : nil,
      isPartial: month >= today.monthKey, earningsFallback: fallback,
      state: positive ? .ready : .noIncome)
  }

  /// The last `count` months ending with the month of `today` (which is partial), oldest first,
  /// none before the month of the first operation.
  public static func series(
    count: Int, ledger: Ledger, today: DateOnly, earningsOnly: Bool = false,
    earningsCategoryId: UUID? = nil, cushionDeposits: [MonthKey: AmountE4] = [:]
  ) -> [SavingsNormMonth] {
    guard count > 0, let first = ledger.firstDay?.monthKey else { return [] }
    let last = today.monthKey
    let from = max(first, last.adding(months: -(count - 1)))
    guard from <= last else { return [] }
    return MonthKey.range(from, through: last).map {
      month(
        $0, ledger: ledger, today: today, earningsOnly: earningsOnly,
        earningsCategoryId: earningsCategoryId, cushionDeposits: cushionDeposits[$0] ?? .zero)
    }
  }

  /// The rate over several complete months together: Σ kept ÷ Σ income, so a big month weighs
  /// more than a small one; months without positive income are left out. `nil` when none is
  /// left.
  public static func combinedRateBp(_ months: [SavingsNormMonth]) -> Int? {
    let usable = months.filter { $0.state == .ready && !$0.isPartial }
    guard !usable.isEmpty else { return nil }
    return signedRatio(
      AmountE4.sum(usable.map(\.keptRub)), of: AmountE4.sum(usable.map(\.incomeRub)))
  }

  /// `part` ÷ `base` in basis points, rounded half away from zero, either sign; `base` is
  /// above zero.
  static func signedRatio(_ part: AmountE4, of base: AmountE4) -> Int? {
    guard base.raw > 0 else { return nil }
    let value = Decimal(part.raw) * 10_000 / Decimal(base.raw)
    guard let rounded = try? DecimalMath.int64(rounding: value) else { return nil }
    return Int(clamping: rounded)
  }
}
