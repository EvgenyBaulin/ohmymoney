import CoreKit
import Foundation
import Testing

@testable import CoreAccounting

@Suite("A new quality of a category, applied to past operations")
struct CategoryQualityChangeTests {
  let categories = StartingCategories()

  /// The starting categories with one quality changed, the way Settings saves it before
  /// the question is asked.
  private func rerated(_ categoryId: UUID, _ quality: Quality?) -> CategoryTree {
    let all = (100...120).compactMap { categories.tree[id($0)] }.map { category in
      var category = category
      if category.id == categoryId { category.quality = quality }
      return category
    }
    return CategoryTree(all)
  }

  private func rated(
    _ partId: UUID, _ category: UUID, _ quality: Quality?, _ source: QualitySource?,
    goal: UUID? = nil
  ) -> TransactionPart {
    part(
      partId, amount: money(100), category: category, goal: goal, quality: quality,
      qualitySource: source)
  }

  /// Only the parts rated by the category follow; my own rating, my history and a goal
  /// contribution in the same operation stay — and the operation keeps everything else.
  @Test func onlyThePartsRatedByTheCategoryFollowIt() throws {
    let tree = rerated(categories.groceries, .bad)
    var receipt = entry(
      id(1),
      parts: [
        rated(id(11), categories.groceries, .neutral, .category),
        rated(id(12), categories.groceries, .good, .manual),
        rated(id(13), categories.groceries, .neutral, .history),
        rated(id(14), categories.goalsTrip, .good, .system, goal: id(70)),
        rated(id(15), categories.groceries, nil, nil),
      ])
    receipt.transaction.externalId = "bank:7"
    let change = CategoryQualityChange(categoryId: categories.groceries)

    let changed = try #require(change.applied(to: receipt, tree: tree))

    #expect(changed.parts.map(\.quality) == [.bad, .good, .neutral, .good, .bad])
    #expect(
      changed.parts.map(\.qualitySource) == [.category, .manual, .history, .system, .category])
    #expect(changed.transaction == receipt.transaction)
    #expect(changed.parts.map(\.amountE4) == receipt.parts.map(\.amountE4))
    #expect(changed.parts.map(\.categoryId) == receipt.parts.map(\.categoryId))
  }

  /// The question counts operations, not parts, and leaves out what would not change:
  /// another category, the quality already there, a deleted operation, income and money
  /// given back, an operation whose only part I rated myself.
  @Test func theQuestionCountsOnlyOperationsThatWouldChange() {
    let tree = rerated(categories.groceries, .bad)
    let entries = [
      entry(
        id(1),
        parts: [
          rated(id(11), categories.groceries, .neutral, .category),
          rated(id(12), categories.groceries, .neutral, .category),
        ]),
      entry(id(2), parts: [rated(id(21), categories.education, .good, .category)]),
      entry(id(3), parts: [rated(id(31), categories.groceries, .bad, .category)]),
      entry(
        id(4), deleted: true, parts: [rated(id(41), categories.groceries, .neutral, .category)]),
      entry(id(5), kind: .refund, parts: [rated(id(51), categories.groceries, .neutral, nil)]),
      entry(
        id(6), kind: .reimbursement,
        parts: [rated(id(61), categories.groceries, .neutral, .category)]),
      entry(id(7), parts: [rated(id(71), categories.groceries, .neutral, .manual)]),
    ]

    let affected = CategoryQualityChange(categoryId: categories.groceries)
      .affected(entries, tree: tree)

    #expect(affected == [id(1), id(5)])
  }

  /// A parent's new quality reaches its subcategories that have none of their own, and
  /// only them.
  @Test func aParentCarriesTheSubcategoriesThatInheritFromIt() {
    let tree = rerated(categories.car, .bad)
    let entries = [
      entry(id(1), parts: [rated(id(11), categories.fuel, .neutral, .category)]),
      entry(id(2), parts: [rated(id(21), categories.fines, .bad, .category)]),
      entry(id(3), parts: [rated(id(31), categories.car, .neutral, .category)]),
    ]
    let change = CategoryQualityChange(categoryId: categories.car)

    #expect(change.affected(entries, tree: tree) == [id(1), id(3)])
    #expect(change.applied(to: entries[0], tree: tree)?.parts.first?.quality == .bad)
  }

  /// «—» is a choice too: a subcategory without a quality follows its parent again, a
  /// category without one rates its parts neutral — as a new operation would be rated.
  @Test func takingTheQualityAwayFallsBackToTheParentOrNeutral() {
    let fines = CategoryQualityChange(categoryId: categories.fines)
    let finesCleared = rerated(categories.fines, nil)
    #expect(fines.quality(in: finesCleared) == .neutral)
    let ticket = entry(id(1), parts: [rated(id(11), categories.fines, .bad, .category)])
    #expect(fines.applied(to: ticket, tree: finesCleared)?.parts.first?.quality == .neutral)

    let pharmacy = CategoryQualityChange(categoryId: categories.pharmacy)
    #expect(pharmacy.quality(in: categories.tree) == .good)

    let education = CategoryQualityChange(categoryId: categories.education)
    #expect(education.quality(in: rerated(categories.education, nil)) == .neutral)
  }
}
