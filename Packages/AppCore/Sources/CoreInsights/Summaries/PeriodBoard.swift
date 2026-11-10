import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation

/// «По периодам» of Reports: the numbers of one week, month or year as the colourful board draws
/// them — the period in numbers, where the money went, the spending of the last six weeks or
/// months against the same ones a year before, good, usual and poor spending, the main
/// categories. Built from the same ledger and by the same rules as the Reports tables and the
/// summary cards: the spending is `Ledger.expenses(in:)`, the categories are
/// `CategoryBreakdown`'s, a month and a year take their totals from `SummaryBuilder`.
public struct PeriodBoard: Hashable, Sendable {
  /// The third figure of the card: the dearest day of a week or a month, the best month of a
  /// year (the dearest day when the year has fewer than two months to compare).
  public enum Highlight: Hashable, Sendable {
    case dearestDay(DateOnly)
    case bestMonth(MonthKey)
  }

  /// A part of the ring: a category, or `nil` for everything past the first four.
  public struct Slice: Hashable, Sendable {
    public var categoryId: UUID?
    public var amount: AmountE4
    /// Basis points of the positive spending; the slices add up to exactly 10,000.
    public var shareBP: Int
  }

  /// A column of «Расходы по неделям / по месяцам»: the spending of a week or a month and of the
  /// same span a year before.
  public struct Column: Hashable, Sendable {
    public var range: DayRange
    /// The month of the column; `nil` for a week.
    public var month: MonthKey?
    public var spent: AmountE4
    public var previous: AmountE4
  }

  /// Good, usual or poor spending of the period.
  public struct Grade: Hashable, Sendable {
    public var quality: Quality
    public var amount: AmountE4
    /// Basis points of the rated spending; `nil` when nothing was rated.
    public var shareBP: Int?
  }

  /// How many columns the chart holds, as every frame draws it.
  public static let columnCount = 6
  /// How many categories the ring names before «Другое», and the list of main categories.
  public static let namedCategories = 4

  public var id: SummaryID
  public var range: DayRange
  public var hasData: Bool
  public var spent: AmountE4
  public var income: AmountE4
  /// What was kept of the income; `nil` with no income.
  public var savedBP: Int?
  public var previousSpent: AmountE4
  /// The spending against the period before; `nil` when nothing was spent then.
  public var changeBP: Int?
  public var highlight: Highlight?
  public var slices: [Slice]
  public var columns: [Column]
  public var grades: [Grade]
  /// The first four categories by money, with their share of the spending.
  public var topCategories: [SummaryCategory]

  public var saved: AmountE4 { income - spent }

  /// How far the bar of the card is filled: the share of the income kept, never below nothing
  /// or past the whole.
  public var keptFillBP: Int { min(max(savedBP ?? 0, 0), Shares.whole) }

  /// The change in whole per cent, as the card writes it; `0` reads «как на прошлой неделе».
  public var changePercent: Int? { changeBP.map(SummaryMath.percent) }

  /// - Returns: `nil` for an id that names no period.
  public static func build(_ id: SummaryID, ledger: Ledger, today: DateOnly) -> PeriodBoard? {
    guard let range = id.range else { return nil }
    let spent: AmountE4
    let income: AmountE4
    let previousSpent: AmountE4
    var best: MonthKey?
    switch id.kind {
    case .week:
      guard let week = id.weekKey else { return nil }
      spent = ledger.expenses(in: range)
      income = AmountE4.sum(
        ledger.rows(in: range).lazy.filter { $0.kind == .income }.map(\.amountRubE4))
      previousSpent = ledger.expenses(in: week.previous.range)
    case .month, .year:
      guard let summary = SummaryBuilder.summary(id: id, ledger: ledger, today: today) else {
        return nil
      }
      spent = summary.expenses
      income = summary.income
      previousSpent = summary.previousExpenses
      best = summary.bestMonth?.month
    }
    let spending = ledger.rows(in: range).filter { !$0.contribution.isZero }
    let categories = categories(ledger: ledger, range: range)
    return PeriodBoard(
      id: id, range: range, hasData: !spending.isEmpty || !income.isZero, spent: spent,
      income: income,
      savedBP: income.raw > 0 ? SummaryBuilder.basisPoints(income - spent, of: income) : nil,
      previousSpent: previousSpent,
      changeBP: SummaryMath.changeBP(spent.decimal, base: previousSpent.decimal),
      highlight: best.map(Highlight.bestMonth) ?? dearestDay(spending).map(Highlight.dearestDay),
      slices: slices(categories), columns: columns(id, ledger: ledger, today: today),
      grades: grades(spending), topCategories: Array(categories.prefix(namedCategories)))
  }

  // MARK: - Pieces

  /// Every category with positive spending, the most first; the shares are the breakdown's.
  static func categories(ledger: Ledger, range: DayRange) -> [SummaryCategory] {
    CategoryBreakdown(ledger: ledger, period: .days(range), kind: .expense).nodes
      .compactMap { node -> SummaryCategory? in
        guard case .category(let categoryId) = node.key, node.amount.raw > 0 else { return nil }
        return SummaryCategory(
          categoryId: categoryId, amount: node.amount, shareBP: node.share ?? 0)
      }
      .sorted { ($0.amount, $1.categoryId.uuidString) > ($1.amount, $0.categoryId.uuidString) }
  }

  /// The first four categories and «Другое» for the rest, shared out so they make exactly
  /// 10,000 basis points.
  static func slices(_ categories: [SummaryCategory]) -> [Slice] {
    let named = Array(categories.prefix(namedCategories))
    let rest = AmountE4.sum(categories.dropFirst(namedCategories).map(\.amount))
    var parts: [(UUID?, AmountE4)] = named.map { ($0.categoryId, $0.amount) }
    if rest.raw > 0 { parts.append((nil, rest)) }
    let shares = Shares.basisPoints(parts.map(\.1))
    return parts.indices.map { index in
      Slice(categoryId: parts[index].0, amount: parts[index].1, shareBP: shares[index] ?? 0)
    }
  }

  /// The day the most was spent; the earlier of two equal ones.
  static func dearestDay(_ spending: [LedgerRow]) -> DateOnly? {
    var byDay: [DateOnly: AmountE4] = [:]
    for row in spending { byDay[row.day, default: .zero] += row.contribution }
    return byDay.filter { $0.value.raw > 0 }
      .max { ($0.value, $1.key) < ($1.value, $0.key) }?.key
  }

  /// Good, usual and poor spending, in that order; a part without a rating is usual, as in the
  /// ledger.
  static func grades(_ spending: [LedgerRow]) -> [Grade] {
    var sums: [Quality: AmountE4] = [:]
    for row in spending {
      guard let quality = row.quality else { continue }
      sums[quality, default: .zero] += row.contribution
    }
    let amounts = Quality.allCases.map { sums[$0] ?? .zero }
    let shares = Shares.basisPoints(amounts)
    return Quality.allCases.indices.map { index in
      Grade(quality: Quality.allCases[index], amount: amounts[index], shareBP: shares[index])
    }
  }

  /// Six weeks to the week of a weekly summary; six months to the month of a monthly one; the
  /// last six months of a year, to the month of today in the current one. Each against the same
  /// span a year before: the week 52 weeks earlier, the month twelve months earlier.
  static func columns(_ id: SummaryID, ledger: Ledger, today: DateOnly) -> [Column] {
    func monthColumns(endingWith last: MonthKey) -> [Column] {
      (0..<columnCount).reversed().map { back in
        let month = last.adding(months: -back)
        let range = DayRange(month.firstDay, month.lastDay)
        let before = month.adding(months: -12)
        return Column(
          range: range, month: month, spent: ledger.expenses(in: range),
          previous: ledger.expenses(in: DayRange(before.firstDay, before.lastDay)))
      }
    }
    switch id.kind {
    case .week:
      guard let week = id.weekKey else { return [] }
      return (0..<columnCount).reversed().map { back in
        let start = week.start.adding(days: -7 * back)
        let range = DayRange(start, start.adding(days: 6))
        let before = DayRange(start.adding(days: -364), start.adding(days: -358))
        return Column(
          range: range, month: nil, spent: ledger.expenses(in: range),
          previous: ledger.expenses(in: before))
      }
    case .month:
      return id.monthKey.map(monthColumns(endingWith:)) ?? []
    case .year:
      guard let year = id.yearNumber else { return [] }
      let last = year == today.year ? today.monthKey : MonthKey(year: year, month: 12)
      return monthColumns(endingWith: last)
    }
  }
}
