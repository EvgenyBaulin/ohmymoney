import Foundation
import Testing

@testable import CoreAnalytics
@testable import CoreKit

/// «Топ категорий» of Overview counts purchases, including those filed by hand under the
/// reconciliation category. Only operations linked to counts are balance adjustments.
@Suite("The top categories of Overview")
struct OverviewTopCategoriesTests {
  private let today = DateOnly(year: 2026, month: 9, day: 20)

  private func spent(
    _ whole: Int64, in category: CoreKit.Category, externalId: String? = nil
  ) throws -> TransactionEntry {
    var draft = TransactionDraft(
      occurredAt: CalendarContext.utc.startOfDay(DateOnly(year: 2026, month: 9, day: 10)),
      amount: AmountE4(whole: whole))
    draft.parts = [PartDraft(categoryId: category.id, amount: AmountE4(whole: whole))]
    var entry = try draft.materialize()
    entry.transaction.externalId = externalId
    return entry
  }

  @Test func onlyCountOperationsAreExcludedFromTheTop() throws {
    let food = CoreKit.Category(kind: .expense, name: "Food")
    let counts = CoreKit.Category(kind: .expense, name: "Сверка")
    let countsBelow = CoreKit.Category(parentId: counts.id, kind: .expense, name: "Cash")
    var book = PlanningBook()
    book.settings.reconcileExpenseCategoryId = counts.id
    let difference = "reconcile:\(UUID().uuidString.lowercased()):\(UUID().uuidString.lowercased())"
    let dataset = Dataset(
      entries: [
        try spent(1_000, in: food),
        try spent(50_000, in: counts, externalId: difference),
        try spent(700, in: countsBelow),
        try spent(300, in: counts),
      ],
      categories: [food, counts, countsBelow], planning: book)
    let summary = OverviewSummary(
      ledger: Ledger(dataset: dataset, calendar: .utc), today: today)

    #expect(Set(summary.topCategories.map(\.key)) == [.category(food.id), .category(counts.id)])
    #expect(summary.topCategories.allSatisfy { $0.amount == AmountE4(whole: 1_000) })
    #expect(summary.topCategories.allSatisfy { $0.share == 5_000 })
    #expect(summary.expenses.current == AmountE4(whole: 2_000))
  }

  /// A difference written before «Сверка» was remembered — in «Не помню» or any other category —
  /// is still a difference: its link says so.
  @Test func aDifferenceInAnotherCategoryIsLeftOutByItsLink() throws {
    let food = CoreKit.Category(kind: .expense, name: "Food")
    let unknown = CoreKit.Category(kind: .expense, name: "Unknown", systemRole: .unknown)
    let dataset = Dataset(
      entries: [
        try spent(1_000, in: food),
        try spent(9_000, in: unknown, externalId: "reconcile:\(UUID().uuidString.lowercased())"),
      ],
      categories: [food, unknown])
    let summary = OverviewSummary(
      ledger: Ledger(dataset: dataset, calendar: .utc), today: today)
    #expect(summary.topCategories.map(\.key) == [.category(food.id)])
  }
}
