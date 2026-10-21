import CoreAnalytics
import CoreKit
import Foundation

// MARK: - Limits: a limit to suggest, a category growing faster than usual

extension AdviceRules {
  /// Complete months the category figures look back over at most.
  static let categoryMonths = 6
  /// Months the medians need at least.
  static let minimumMonths = 3
  /// Categories a suggestion names at most.
  static let categoriesShown = 3
  /// «Growing»: the last complete month is at least 130 % of the usual…
  static let growthFactorBp = 13_000
  /// …and at least 1 000 ₽ above it.
  static let growthMinimum = AmountE4(whole: 1_000)

  /// A limit for the top-level categories that have none («предложение лимита для
  /// категорий без него — по медиане 3–6 месяцев»).
  ///
  /// Over the last complete months, at most six, a category's spending of each month is what
  /// a limit on it would count (`LimitRules.counts`), by date. It is suggested when it has no
  /// limit of its own, takes a limit (not a system category, not an income one, not
  /// archived, not a reconciliation one) and had spending in at least three of those months; the suggestion is the
  /// median of all of them, empty months included, rounded up to 100 ₽. The three largest
  /// medians are named. Fewer than three complete months: «not enough data».
  static func limitSuggestions(_ context: AdviceContext, budgets: [Budget]) -> [Advice] {
    let months = context.completeMonths(categoryMonths)
    guard months.count >= minimumMonths else {
      return [.notEnoughData(.limitSuggestion, reason: Reason.fewerThanThreeMonths)]
    }
    let tree = context.ledger.tree
    let limited = Set(budgets.filter { $0.scope == .category }.compactMap(\.categoryId))
    let limitless = context.ledger.dataset.planning.settings.limitlessCategoryIds
    let table = spendingByCategory(context.ledger, months: months)
    let candidates =
      table.compactMap { root, byMonth -> (root: UUID, values: [AmountE4], median: AmountE4)? in
        guard !limited.contains(root), let category = tree.category(root),
          category.kind == .expense, !category.archived, tree.acceptsLimit(root),
          !LimitRules.isLimitless(root, tree: tree, limitless: limitless)
        else { return nil }
        let values = months.map { byMonth[$0] ?? .zero }
        guard values.filter({ $0.raw > 0 }).count >= minimumMonths,
          let median = IncomeEstimate.median(values), median.raw > 0
        else { return nil }
        return (root, values, median)
      }
      .sorted { left, right in
        left.median != right.median
          ? left.median > right.median : left.root.uuidString < right.root.uuidString
      }
    return candidates.prefix(categoriesShown).map { candidate in
      let values = candidate.values
      return Advice(
        id: AdviceBook.id(.limitSuggestion, candidate.root),
        kind: .limitSuggestion, subject: .category(candidate.root),
        terms: [
          AdviceTerm(key: Key.monthsCounted, value: .count(months.count)),
          AdviceTerm(
            key: Key.monthsWithSpending, value: .count(values.filter { $0.raw > 0 }.count)),
          AdviceTerm(
            key: Key.monthlyRange,
            value: .range(values.min() ?? .zero, values.max() ?? .zero)),
          AdviceTerm(key: Key.monthlyMedian, value: .money(candidate.median)),
        ],
        result: AdviceTerm(
          key: Key.suggestedLimit, op: .equals,
          value: .money(AdviceMath.roundedUpToHundred(candidate.median))))
    }
  }

  /// Categories growing faster than usual («предупреждение о категориях, которые растут
  /// быстрее обычного»): the last complete month is at least 1.3 × the median of the three to
  /// six complete months before it and at least 1 000 ₽ above it. A category with no usual
  /// spending (a median of zero) has nothing to grow from: a one-off purchase in a new
  /// category is not a trend. The three largest rises are named. Fewer than four complete
  /// months: «not enough data».
  static func growingCategories(_ context: AdviceContext) -> [Advice] {
    let window = context.completeMonths(categoryMonths + 1)
    guard window.count >= minimumMonths + 1, let last = window.last else {
      return [.notEnoughData(.growingCategory, reason: Reason.fewerThanFourMonths)]
    }
    let before = Array(window.dropLast())
    let tree = context.ledger.tree
    let table = spendingByCategory(context.ledger, months: window)
    let growing =
      table.compactMap { root, byMonth -> (root: UUID, last: AmountE4, median: AmountE4)? in
        guard let category = tree.category(root), category.kind == .expense,
          !category.archived
        else { return nil }
        let spent = byMonth[last] ?? .zero
        guard let median = IncomeEstimate.median(before.map { byMonth[$0] ?? .zero }),
          median.raw > 0,
          Decimal(spent.raw) * Decimal(Shares.whole)
            >= Decimal(median.raw) * Decimal(growthFactorBp),
          spent - median >= growthMinimum
        else { return nil }
        return (root, spent, median)
      }
      .sorted { left, right in
        let leftRise = left.last - left.median
        let rightRise = right.last - right.median
        return leftRise != rightRise
          ? leftRise > rightRise : left.root.uuidString < right.root.uuidString
      }
    return growing.prefix(categoriesShown).map { item in
      let rise = item.last - item.median
      var notes = [AdviceTerm(key: Key.lastCompleteMonth, value: .month(last))]
      if let growth = Shares.ratio(rise, of: item.median) {
        notes.append(AdviceTerm(key: Key.growth, value: .basisPoints(growth)))
      }
      notes.append(AdviceTerm(key: Key.monthsCounted, value: .count(before.count)))
      return Advice(
        id: AdviceBook.id(.growingCategory, item.root), kind: .growingCategory,
        subject: .category(item.root),
        terms: [
          AdviceTerm(key: Key.lastMonthSpent, op: .plus, value: .money(item.last)),
          AdviceTerm(key: Key.usualMedian, op: .minus, value: .money(item.median)),
        ],
        result: AdviceTerm(key: Key.aboveUsual, op: .equals, value: .money(rise)), notes: notes)
    }
  }

  /// My spending of each month under each top-level category — what a limit on that
  /// category counts (`LimitRules.counts`): my spending, refunds taken off, goal
  /// contributions and system categories left out — by date.
  static func spendingByCategory(
    _ ledger: Ledger, months: [MonthKey]
  ) -> [UUID: [MonthKey: AmountE4]] {
    guard let first = months.first, let last = months.last else { return [:] }
    let wanted = Set(months)
    var probes: [UUID: Budget] = [:]
    var table: [UUID: [MonthKey: AmountE4]] = [:]
    for row in ledger.rows(in: DayRange(first.firstDay, last.lastDay))
    where !row.contribution.isZero {
      guard let root = row.rootCategoryId, wanted.contains(row.day.monthKey) else { continue }
      let probe =
        probes[root]
        ?? Budget(id: root, scope: .category, categoryId: root, amountE4: .zero)
      probes[root] = probe
      guard LimitRules.counts(row, for: probe) else { continue }
      table[root, default: [:]][row.day.monthKey, default: .zero] += row.contribution
    }
    return table
  }
}
