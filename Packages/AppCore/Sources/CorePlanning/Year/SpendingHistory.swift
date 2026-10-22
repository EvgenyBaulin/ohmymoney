import CoreAnalytics
import CoreKit
import Foundation

/// My spending by month, kept per category: the one input every seasonal figure of the year
/// plan is made of (seasonality, the year forecast, the «expensive month», the seasonal
/// limit). The ledger is read once; every question after that is arithmetic on a small table.
///
/// A row counts when it is my spending in the sense the limits use: it contributes to my
/// expenses, is not a goal contribution, a debt payment or a system category, and is not a
/// record the app wrote to square the books. Scheduled payments count — their charges are
/// part of what a category costs in a month.
public struct SpendingHistory: Hashable, Sendable {
  /// Rubles per month of the category itself (a subcategory has its own series).
  public private(set) var byCategory: [UUID: [MonthKey: AmountE4]]
  /// Rubles per month of a top-level category with everything under it.
  public private(set) var byRoot: [UUID: [MonthKey: AmountE4]]
  /// Rubles per month of all of it.
  public private(set) var total: [MonthKey: AmountE4]
  /// The first month the history counts, `nil` for an empty history. A month begun after its
  /// 1st is only part of a month, so the history starts on the next one (the rule of
  /// `IncomeEstimate`).
  public let firstMonth: MonthKey?
  /// The last month that is over: the month before today's.
  public let lastCompleteMonth: MonthKey

  public init(
    byCategory: [UUID: [MonthKey: AmountE4]], byRoot: [UUID: [MonthKey: AmountE4]] = [:],
    total: [MonthKey: AmountE4]? = nil, firstMonth: MonthKey?, lastCompleteMonth: MonthKey
  ) {
    self.byCategory = byCategory
    self.byRoot = byRoot
    if let total {
      self.total = total
    } else {
      var sums: [MonthKey: AmountE4] = [:]
      for series in byCategory.values {
        for (month, amount) in series { sums[month, default: .zero] += amount }
      }
      self.total = sums
    }
    self.firstMonth = firstMonth
    self.lastCompleteMonth = lastCompleteMonth
  }

  /// Reads the ledger. `today` fixes which months are over.
  public init(ledger: Ledger, today: DateOnly) {
    var byCategory: [UUID: [MonthKey: AmountE4]] = [:]
    var byRoot: [UUID: [MonthKey: AmountE4]] = [:]
    var total: [MonthKey: AmountE4] = [:]
    let current = today.monthKey
    for row in ledger.rows where row.month < current && Self.counts(row) {
      total[row.month, default: .zero] += row.contribution
      guard let categoryId = row.categoryId else { continue }
      byCategory[categoryId, default: [:]][row.month, default: .zero] += row.contribution
      byRoot[row.rootCategoryId ?? categoryId, default: [:]][row.month, default: .zero] +=
        row.contribution
    }
    self.init(
      byCategory: byCategory, byRoot: byRoot, total: total,
      firstMonth: IncomeEstimate.historyStart(firstDay: ledger.firstDay),
      lastCompleteMonth: current.previous)
  }

  /// The rule above, one row at a time.
  static func counts(_ row: LedgerRow) -> Bool {
    guard !row.contribution.isZero, !row.isGoalContribution, row.debtId == nil,
      row.systemRole == nil
    else { return false }
    return row.link?.isBookkeeping != true
  }

  /// The series of a category: a top-level one with its subcategories, a subcategory alone.
  public func series(of categoryId: UUID) -> [MonthKey: AmountE4] {
    byRoot[categoryId] ?? byCategory[categoryId] ?? [:]
  }

  /// The categories a year forecast has a row for: the top-level ones when the history knows
  /// them, else the categories themselves, in a stable order.
  public var forecastCategoryIds: [UUID] {
    (byRoot.isEmpty ? Array(byCategory.keys) : Array(byRoot.keys))
      .sorted { $0.uuidString < $1.uuidString }
  }

  /// The complete months the history can speak for, oldest first, at most `limit` of them:
  /// from `firstMonth` through `lastCompleteMonth`. Months without spending are real zeros.
  public func completeMonths(limit: Int = 24) -> [MonthKey] {
    guard let firstMonth, firstMonth <= lastCompleteMonth, limit > 0 else { return [] }
    let first = max(firstMonth, lastCompleteMonth.adding(months: -(limit - 1)))
    return MonthKey.range(first, through: lastCompleteMonth)
  }
}
