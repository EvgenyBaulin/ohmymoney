import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation

/// What a suggested limit is counted from: a usual month, or a usual month less a tenth.
public enum LimitSuggestionBasis: String, CaseIterable, Hashable, Sendable {
  /// The median of the last full months.
  case usual
  /// That median less 10 %.
  case tenPercentLess
}

/// A limit «Предложить лимиты…» offers: a top-level expense category without a limit that was
/// spent on in the last full months, and what a month of it usually costs.
public struct LimitSuggestion: Hashable, Sendable, Identifiable {
  public var categoryId: UUID
  /// My spending under the category in each of the months looked at, oldest first; a month
  /// that gave more back than it spent is zero.
  public var months: [AmountE4]
  /// The median of `months`.
  public var median: AmountE4
  /// The median rounded up (`LimitSuggestions.roundedUp`).
  public var usual: AmountE4
  /// The median less 10 %, rounded up the same way.
  public var tenPercentLess: AmountE4

  public var id: UUID { categoryId }

  public init(
    categoryId: UUID, months: [AmountE4], median: AmountE4, usual: AmountE4,
    tenPercentLess: AmountE4
  ) {
    self.categoryId = categoryId
    self.months = months
    self.median = median
    self.usual = usual
    self.tenPercentLess = tenPercentLess
  }

  /// The amount the basis suggests.
  public func amount(_ basis: LimitSuggestionBasis) -> AmountE4 {
    switch basis {
    case .usual: usual
    case .tenPercentLess: tenPercentLess
    }
  }
}

/// The rules of suggested limits. Spending is my expenses as every limit counts them
/// (`LimitRules.counts`, from the `Ledger`), so a suggested limit starts where it will be
/// measured.
public enum LimitSuggestions {
  /// How many full months are looked at: the ones before the month of today.
  public static let monthCount = 3
  /// A category spent on in fewer of those months is no habit yet: one big purchase is not a
  /// month's spending.
  public static let minimumMonthsSpent = 2
  /// Under this a suggestion is rounded up to `smallStep`, from it up to `largeStep`.
  public static let largeFrom = AmountE4(whole: 10_000)
  public static let smallStep = AmountE4(whole: 500)
  public static let largeStep = AmountE4(whole: 1_000)

  /// The full months before the month of `today`, oldest first.
  public static func months(before today: DateOnly) -> [MonthKey] {
    var months: [MonthKey] = []
    var month = today.monthKey
    for _ in 0..<monthCount {
      month = month.previous
      months.insert(month, at: 0)
    }
    return months
  }

  /// The suggestions for the book as it is, the biggest first, then by name, then by id.
  ///
  /// Only top-level categories: a limit on each subcategory would make a long list, and the
  /// limit on a category covers its subcategories. A category is offered when a limit could be
  /// saved on it and is shown (`LimitRules.offersLimit`: an expense category, neither a system
  /// one, nor «Сверка», nor archived), has no limit of its own, and was spent on in at least
  /// `minimumMonthsSpent` of the months. A median that rounds to nothing offers nothing.
  public static func suggestions(
    ledger: Ledger, budgets: [Budget], today: DateOnly, limitless: Set<UUID> = []
  ) -> [LimitSuggestion] {
    let tree = ledger.tree
    let months = months(before: today)
    let candidates = ledger.dataset.categories.filter { category in
      category.parentId == nil
        && LimitRules.offersLimit(
          on: category.id, tree: tree, limitless: limitless,
          taxCategoryId: ledger.dataset.selfEmployment.taxCategoryId)
        && LimitRules.categoryLimit(of: category.id, in: budgets) == nil
    }
    let candidateIds = Set(candidates.map(\.id))
    guard !candidateIds.isEmpty, let first = months.first, let last = months.last else {
      return []
    }

    var spent: [UUID: [MonthKey: AmountE4]] = [:]
    let range = DayRange(first.firstDay, Period.month(last).range.end)
    for row in ledger.rows(in: range) {
      guard let root = row.rootCategoryId ?? row.categoryId, candidateIds.contains(root) else {
        continue
      }
      let probe = Budget(scope: .category, categoryId: root, amountE4: .zero)
      guard LimitRules.counts(row, for: probe) else { continue }
      spent[root, default: [:]][row.day.monthKey, default: .zero] += row.contribution
    }

    let suggestions = candidates.compactMap { category -> (LimitSuggestion, String)? in
      let byMonth = spent[category.id] ?? [:]
      let amounts = months.map { month in max(byMonth[month] ?? .zero, .zero) }
      guard amounts.filter({ $0.raw > 0 }).count >= minimumMonthsSpent else { return nil }
      let median = median(of: amounts)
      let usual = roundedUp(median)
      guard usual.raw > 0 else { return nil }
      let suggestion = LimitSuggestion(
        categoryId: category.id, months: amounts, median: median, usual: usual,
        tenPercentLess: roundedUp(lessATenth(median)))
      return (suggestion, fold(category.name))
    }
    return
      suggestions
      .sorted { left, right in
        if left.0.usual != right.0.usual { return left.0.usual > right.0.usual }
        if left.1 != right.1 { return left.1 < right.1 }
        return left.0.categoryId.uuidString < right.0.categoryId.uuidString
      }
      .map(\.0)
  }

  /// The middle of the amounts in order; of an even count, the mean of the two middle ones,
  /// rounded half away from zero.
  public static func median(of amounts: [AmountE4]) -> AmountE4 {
    let sorted = amounts.sorted()
    guard !sorted.isEmpty else { return .zero }
    let middle = sorted.count / 2
    if sorted.count % 2 == 1 { return sorted[middle] }
    return rounded((sorted[middle - 1].decimal + sorted[middle].decimal) / 2)
  }

  /// Up to the next 500 ₽ under 10,000 ₽ and the next 1,000 ₽ from it: a limit reads as a
  /// round number and never starts below what a usual month costs. A round amount stays;
  /// zero and less are zero.
  public static func roundedUp(_ amount: AmountE4) -> AmountE4 {
    guard amount.raw > 0 else { return .zero }
    let step = amount < largeFrom ? smallStep : largeStep
    // An amount near the top of the range keeps itself: padding it to the next step must not
    // trap, as the multiplication below does not.
    let (padded, tooBig) = amount.raw.addingReportingOverflow(step.raw - 1)
    guard !tooBig else { return amount }
    let steps = padded / step.raw
    let (value, overflow) = steps.multipliedReportingOverflow(by: step.raw)
    return overflow ? amount : AmountE4(raw: value)
  }

  /// 90 % of the amount, rounded half away from zero to stored units.
  public static func lessATenth(_ amount: AmountE4) -> AmountE4 {
    rounded(amount.decimal * Decimal(9) / Decimal(10))
  }

  /// The limits to write for the rows the owner kept: one new limit per category, starting
  /// this month, without rollover. A row whose limit could not be saved — a category that got
  /// a limit meanwhile, a system one, an amount of zero — is left out, as is a second row of
  /// the same category; the others are still written.
  public static func budgets(
    for chosen: [(categoryId: UUID, amount: AmountE4)], existing: [Budget], tree: CategoryTree,
    in month: MonthKey, limitless: Set<UUID> = []
  ) -> [Budget] {
    var written: [Budget] = []
    for row in chosen {
      let budget = Budget(scope: .category, categoryId: row.categoryId, amountE4: row.amount)
      guard
        LimitRules.validate(
          budget, tree: tree, existing: existing + written, limitless: limitless) == nil
      else { continue }
      written.append(LimitRules.saving(budget, over: nil, in: month))
    }
    return written
  }

  private static func rounded(_ value: Decimal) -> AmountE4 {
    (try? AmountE4(decimal: value)) ?? (value < 0 ? AmountE4(raw: .min) : AmountE4(raw: .max))
  }

  private static func fold(_ name: String) -> String {
    name.lowercased().replacingOccurrences(of: "ё", with: "е")
  }
}
