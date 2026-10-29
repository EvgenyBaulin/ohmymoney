import CoreAnalytics
import CoreKit
import Foundation

/// The five cards of a week: two minutes once a week.
public struct WeekCards: Hashable, Sendable {
  public struct Total: Hashable, Sendable {
    public var expenses: AmountE4
    public var income: AmountE4
    public var purchases: Int
  }

  public struct DearestDay: Hashable, Sendable {
    public var day: DateOnly
    public var amount: AmountE4
  }

  public struct TopCategory: Hashable, Sendable {
    public var categoryId: UUID
    public var amount: AmountE4
    public var shareBP: Int
  }

  public struct Comparison: Hashable, Sendable {
    public var expenses: AmountE4
    public var previousExpenses: AmountE4
    /// More or less than the week before, in basis points; `nil` when that week had none.
    public var changeBP: Int?
  }

  public var week: WeekKey
  public var hasData: Bool
  public var total: Total
  /// `nil` in a week with no spending.
  public var dearestDay: DearestDay?
  public var topCategory: TopCategory?
  public var comparison: Comparison
  /// «Знаешь ли ты»; `nil` while there is too little history or nothing noticeable.
  public var knowYou: KnowFact?
  /// The face the owner chose for the week, if he answered.
  public var mood: WeekMood?

  /// - Parameter moods: the answers given so far.
  public static func build(week: WeekKey, ledger: Ledger, moods: [WeekMood] = []) -> WeekCards {
    let range = week.range
    // The sums are the ledger's own, the ones the Reports window adds up.
    let expenses = ledger.expenses(in: range)
    let rows = ledger.rows(in: range)
    let income = AmountE4.sum(rows.lazy.filter { $0.kind == .income }.map(\.amountRubE4))
    let spending = rows.filter { !$0.contribution.isZero }
    let purchases = Set(spending.map(\.transactionId)).count

    var byDay: [DateOnly: AmountE4] = [:]
    var byCategory: [UUID: AmountE4] = [:]
    for row in spending {
      byDay[row.day, default: .zero] += row.contribution
      if row.link?.isBookkeeping != true, let root = row.rootCategoryId {
        byCategory[root, default: .zero] += row.contribution
      }
    }
    let dearest = byDay.filter { $0.value.raw > 0 }
      .max { ($0.value, $1.key) < ($1.value, $0.key) }
      .map { DearestDay(day: $0.key, amount: $0.value) }
    let positive = byCategory.filter { $0.value.raw > 0 }
    let positiveTotal = AmountE4.sum(positive.values)
    let top = positive.max { ($0.value, $1.key.uuidString) < ($1.value, $0.key.uuidString) }
      .map {
        TopCategory(
          categoryId: $0.key, amount: $0.value,
          shareBP: SummaryMath.shareBP($0.value.decimal, of: positiveTotal.decimal))
      }
    let before = ledger.expenses(in: week.previous.range)
    return WeekCards(
      week: week, hasData: !spending.isEmpty || !income.isZero,
      total: Total(expenses: expenses, income: income, purchases: purchases),
      dearestDay: dearest, topCategory: top,
      comparison: Comparison(
        expenses: expenses, previousExpenses: before,
        changeBP: SummaryMath.changeBP(expenses.decimal, base: before.decimal)),
      knowYou: KnowYouFacts.find(ledger: ledger, week: week),
      mood: moods.first { $0.week == week })
  }
}
