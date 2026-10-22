import CoreKit
import Foundation

/// A limit that holds for one month only (the stored form of a future table
/// `budget_month_exceptions`: `id`, `budget_id`, `month` as `YYYY-MM`, `amount_e4`): the limit
/// «Gifts» is 5 000 ₽ and December's is 20 000 ₽, and January is back to 5 000 on its own.
public struct LimitMonthException: Identifiable, Hashable, Sendable, Codable {
  public var id: UUID
  public var budgetId: UUID
  public var month: MonthKey
  public var amountE4: AmountE4

  public init(id: UUID = UUID(), budgetId: UUID, month: MonthKey, amountE4: AmountE4) {
    self.id = id
    self.budgetId = budgetId
    self.month = month
    self.amountE4 = amountE4
  }

  enum CodingKeys: String, CodingKey {
    case id
    case budgetId = "budget_id"
    case month
    case amountE4 = "amount_e4"
  }
}

public enum LimitSchedule {
  /// The limit of `budget` in `month`: the exception of that month when there is one (the
  /// latest of two), else the limit itself.
  public static func amount(
    of budget: Budget, in month: MonthKey, exceptions: [LimitMonthException]
  ) -> AmountE4 {
    exceptions.last { $0.budgetId == budget.id && $0.month == month }?.amountE4 ?? budget.amountE4
  }

  /// The budget as the month sees it: its amount replaced by the exception of that month.
  public static func budget(
    _ budget: Budget, in month: MonthKey, exceptions: [LimitMonthException]
  ) -> Budget {
    var result = budget
    result.amountE4 = amount(of: budget, in: month, exceptions: exceptions)
    return result
  }

  /// Adds the exception of a month for a budget, replacing the one it had: one exception per
  /// budget and month.
  public static func setting(
    _ amount: AmountE4, for budget: UUID, in month: MonthKey,
    exceptions: [LimitMonthException]
  ) -> [LimitMonthException] {
    var result = exceptions.filter { !($0.budgetId == budget && $0.month == month) }
    result.append(LimitMonthException(budgetId: budget, month: month, amountE4: amount))
    return result
  }
}

/// «В декабре подарки обычно ≈ 20 000 ₽ — поднять лимит на декабрь?»
public struct LimitSeasonSuggestion: Hashable, Sendable, Identifiable {
  public var budgetId: UUID
  public var categoryId: UUID
  /// The month the limit is raised for: the month after today's.
  public var month: MonthKey
  public var currentLimit: AmountE4
  /// What this month usually costs in this category, rounded up to a hundred rubles.
  public var suggested: AmountE4
  /// What the month usually costs, before rounding.
  public var typical: AmountE4
  public var basis: SeasonBasis

  public var id: String { "limitSeason:\(budgetId.uuidString):\(month.iso)" }
}

/// A month before an expensive one, the limits it will break are offered an exception.
public enum LimitSeasonAdvisor {
  /// The typical spend has to be at least 10 % over the limit before the limit is called short.
  public static let marginBp = 1_000
  /// The rounding of a suggested limit: a hundred rubles, upwards.
  public static let step = AmountE4(whole: 100)

  /// The suggestions for the month after today.
  ///
  /// * Only limits on a category, and only with a whole year of history (`Seasonality`).
  /// * The category's next month has to be an expensive one for it — a limit that is short in
  ///   every month is another story (`LimitSuggestions`), and an exception for one month would
  ///   hide it.
  /// * The typical spend is the average of that calendar month over the years the history has,
  ///   and it has to exceed the limit of that month by `marginBp`.
  /// * A month that already has an exception for the limit is left alone; so is a dismissed
  ///   suggestion (`dismissed` holds `LimitSeasonSuggestion.id`).
  public static func suggestions(
    budgets: [Budget], history: SpendingHistory, exceptions: [LimitMonthException],
    today: DateOnly, dismissed: Set<String> = []
  ) -> [LimitSeasonSuggestion] {
    let month = today.monthKey.next
    var result: [LimitSeasonSuggestion] = []
    for budget in budgets where budget.scope == .category {
      guard let categoryId = budget.categoryId,
        let seasonality = Seasonality.of(category: categoryId, history: history).seasonality,
        let season = seasonality.month(month.month), season.isExpensive,
        !exceptions.contains(where: { $0.budgetId == budget.id && $0.month == month })
      else { continue }
      let limit = LimitSchedule.amount(of: budget, in: month, exceptions: exceptions)
      let typical = season.average
      let needed = Decimal(Seasonality.whole + marginBp) * limit.decimal
      guard typical.decimal * Decimal(Seasonality.whole) > needed else { continue }
      let suggestion = LimitSeasonSuggestion(
        budgetId: budget.id, categoryId: categoryId, month: month, currentLimit: limit,
        suggested: SavingsMath.ceilingWhole(typical, by: 1).roundedUp(toMultipleOf: step),
        typical: typical, basis: seasonality.basis)
      guard !dismissed.contains(suggestion.id) else { continue }
      result.append(suggestion)
    }
    return result.sorted {
      ($0.typical - $0.currentLimit, $0.budgetId.uuidString)
        > ($1.typical - $1.currentLimit, $1.budgetId.uuidString)
    }
  }
}

extension AmountE4 {
  /// Rounded up to a whole multiple of `step`; an amount not above zero stays as it is.
  func roundedUp(toMultipleOf step: AmountE4) -> AmountE4 {
    guard raw > 0, step.raw > 0 else { return self }
    let (quotient, remainder) = raw.quotientAndRemainder(dividingBy: step.raw)
    let (value, overflow) = (quotient + (remainder > 0 ? 1 : 0)).multipliedReportingOverflow(
      by: step.raw)
    return overflow ? self : AmountE4(raw: value)
  }
}
