import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation

/// How a month fits the owner's proportions.
public struct BudgetBasketLine: Hashable, Sendable {
  public enum Direction: Hashable, Sendable {
    /// Within a whole percent of the target.
    case onTarget
    /// More of the income than the target says.
    case above
    /// Less of the income than the target says.
    case below
  }

  public var basket: BudgetBasket
  public var amountRub: AmountE4
  /// Basis points of the income; `nil` without positive income.
  public var shareBp: Int?
  public var targetBp: Int
  /// `shareBp` − `targetBp`; `nil` without a share.
  public var differenceBp: Int?
  public var direction: Direction?

  public init(
    basket: BudgetBasket, amountRub: AmountE4, shareBp: Int?, targetBp: Int,
    differenceBp: Int?, direction: Direction?
  ) {
    self.basket = basket
    self.amountRub = amountRub
    self.shareBp = shareBp
    self.targetBp = targetBp
    self.differenceBp = differenceBp
    self.direction = direction
  }
}

public struct BudgetFit: Hashable, Sendable {
  public var month: MonthKey
  public var proportions: BudgetProportions
  /// The income the shares are measured against.
  public var incomeRub: AmountE4
  /// Needs, wants, savings in this order.
  public var lines: [BudgetBasketLine]
  public var isPartial: Bool

  public init(
    month: MonthKey, proportions: BudgetProportions, incomeRub: AmountE4,
    lines: [BudgetBasketLine], isPartial: Bool
  ) {
    self.month = month
    self.proportions = proportions
    self.incomeRub = incomeRub
    self.lines = lines
    self.isPartial = isPartial
  }

  public func line(_ basket: BudgetBasket) -> BudgetBasketLine? {
    lines.first { $0.basket == basket }
  }
}

/// The baskets of 50 / 30 / 20 (or the owner's own).
///
/// * **Needs** — spending in the categories marked as essential (`CategoryTree.isEssential`)
///   and payments on loans.
/// * **Wants** — the rest of my spending.
/// * **Savings** — contributions to goals (less what was taken back) and the money put on
///   the cushion accounts.
///
/// The owner can move any category to another basket (`overrides`, category → basket, the value
/// of the category's own column): a subcategory with no basket of its own follows its parent,
/// as the «necessary» mark does. A category moved to «savings» counts as put aside whatever
/// it is called.
public enum BudgetBaskets {
  /// The basket of a category by the rules above, without an override: essential or loans —
  /// needs, anything else — wants. Goal categories count as savings.
  public static func basket(
    of categoryId: UUID?, tree: CategoryTree, overrides: [UUID: BudgetBasket] = [:]
  ) -> BudgetBasket {
    if let categoryId {
      if let own = overrides[categoryId] { return own }
      if let parent = tree.parent(of: categoryId), let inherited = overrides[parent.id] {
        return inherited
      }
    }
    if tree.isGoalCategory(categoryId) { return .savings }
    if tree.isEssential(categoryId) || tree.isLoanCategory(categoryId) { return .needs }
    return .wants
  }

  /// How `month` lays out against the proportions. `income` is the income the shares are
  /// measured against (`SavingsNormMonth.incomeRub`, so the «only earnings» switch holds here
  /// too); `cushionDeposits` is the money moved to the cushion accounts in the month.
  public static func fit(
    month: MonthKey, ledger: Ledger, today: DateOnly, income: AmountE4,
    proportions: BudgetProportions, overrides: [UUID: BudgetBasket] = [:],
    cushionDeposits: AmountE4 = .zero
  ) -> BudgetFit {
    var sums: [BudgetBasket: AmountE4] = [:]
    var goalRows = AmountE4.zero
    for row in ledger.rows(in: DayRange(month.firstDay, month.lastDay)) {
      if row.isGoalContribution {
        // The money of goals: net of what was taken back, wherever the owner filed the row.
        switch row.kind {
        case .expense: goalRows += row.amountRubE4
        case .refund: goalRows += -row.amountRubE4
        case .income, .reimbursement: break
        }
        continue
      }
      guard !row.contribution.isZero else { continue }
      let basket = basket(of: row.categoryId, tree: ledger.tree, overrides: overrides)
      sums[basket, default: .zero] += row.contribution
    }
    sums[.savings, default: .zero] += goalRows + cushionDeposits

    let lines = BudgetBasket.allCases.map { basket -> BudgetBasketLine in
      let amount = sums[basket] ?? .zero
      let share = SavingsNorm.signedRatio(amount, of: income)
      let target = proportions.targetBp(of: basket)
      let difference = share.map { $0 - target }
      let direction: BudgetBasketLine.Direction? = difference.map {
        abs($0) < 100 ? .onTarget : ($0 > 0 ? .above : .below)
      }
      return BudgetBasketLine(
        basket: basket, amountRub: amount, shareBp: share, targetBp: target,
        differenceBp: difference, direction: direction)
    }
    return BudgetFit(
      month: month, proportions: proportions, incomeRub: income, lines: lines,
      isPartial: month >= today.monthKey)
  }
}
