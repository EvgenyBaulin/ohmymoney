import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CorePlanning

/// «Сверка» — the categories the differences of counts are written in — takes no limit, like
/// the system categories: whatever the owner renamed it to, it and everything under it. A limit
/// 1.1 stored on it keeps counting as before and can be deleted, but not changed.
@Suite("No limit on the reconciliation categories")
struct LimitReconciliationCategoryTests: SavingsFixtures {
  let today = DateOnly(year: 2026, month: 9, day: 19)
  var month: MonthKey { today.monthKey }

  var reconcile: UUID { uid(40) }
  var reconcileIncome: UUID { uid(41) }
  var reconcileChild: UUID { uid(42) }

  /// The advice book with «Сверка» (an expense category with a subcategory «Мелочи») and its
  /// income twin, remembered in the settings as the reconciliation writes them.
  func data() -> AdviceData {
    var data = AdviceData()
    data.categories += [
      CoreKit.Category(id: reconcile, kind: .expense, name: "Сверка", quality: .neutral),
      CoreKit.Category(id: reconcileChild, parentId: reconcile, kind: .expense, name: "Мелочи"),
      CoreKit.Category(id: reconcileIncome, kind: .income, name: "Сверка"),
    ]
    data.book.settings.reconcileExpenseCategoryId = reconcile
    data.book.settings.reconcileIncomeCategoryId = reconcileIncome
    return data
  }

  var limitless: Set<UUID> { [reconcile, reconcileIncome] }

  /// «+ Лимит» on «Сверка»: refused with its own reason; the same form on «Food» saves.
  @Test func aNewLimitOnTheReconciliationCategoryIsRefused() {
    let data = data()
    let tree = CategoryTree(data.categories)
    #expect(data.book.settings.limitlessCategoryIds == limitless)
    let onReconcile = Budget(scope: .category, categoryId: reconcile, amountE4: rub("5000"))
    #expect(
      LimitRules.validate(onReconcile, tree: tree, existing: [], limitless: limitless)
        == .reconciliationCategory)
    let onIncome = Budget(scope: .category, categoryId: reconcileIncome, amountE4: rub("5000"))
    #expect(
      LimitRules.validate(onIncome, tree: tree, existing: [], limitless: limitless)
        == .reconciliationCategory)
    let onFood = Budget(scope: .category, categoryId: data.food, amountE4: rub("5000"))
    #expect(LimitRules.validate(onFood, tree: tree, existing: [], limitless: limitless) == nil)
    // Without the remembered ids nothing is special about the category, as in 1.1.
    #expect(LimitRules.validate(onReconcile, tree: tree, existing: []) == nil)
    #expect(
      LimitRules.settingCategoryLimit(
        reconcile, to: rub("5000"), budgets: [], tree: tree, in: month, limitless: limitless)
        == .refused(.reconciliationCategory))
  }

  /// A subcategory of «Сверка», and one under it moved deeper, take no limit either.
  @Test func aLimitOnASubcategoryOfItIsRefused() {
    var data = data()
    let deeper = uid(43)
    data.categories.append(
      CoreKit.Category(id: deeper, parentId: reconcileChild, kind: .expense, name: "Совсем"))
    let tree = CategoryTree(data.categories)
    for category in [reconcileChild, deeper] {
      let budget = Budget(scope: .category, categoryId: category, amountE4: rub("100"))
      #expect(
        LimitRules.validate(budget, tree: tree, existing: [], limitless: limitless)
          == .reconciliationCategory)
      #expect(LimitRules.isLimitless(category, tree: tree, limitless: limitless))
    }
    #expect(!LimitRules.isLimitless(data.cafe, tree: tree, limitless: limitless))
  }

  /// Settings → Категории shows no limit field on «Сверка» nor under it; «Food» keeps one.
  @Test func itOffersNoLimitField() {
    let data = data()
    let tree = CategoryTree(data.categories)
    #expect(!LimitRules.offersLimit(on: reconcile, tree: tree, limitless: limitless))
    #expect(!LimitRules.offersLimit(on: reconcileChild, tree: tree, limitless: limitless))
    #expect(LimitRules.offersLimit(on: data.food, tree: tree, limitless: limitless))
    #expect(LimitRules.offersLimit(on: reconcile, tree: tree))
  }

  /// A limit of 5 000 stored on «Сверка» by 1.1: a 300 purchase the owner filed there counts,
  /// the 8 000 difference a count wrote there does not — 300 of 5 000, as before.
  @Test func aStoredLimitCountsAsBefore() throws {
    var data = data()
    let stored = Budget(
      id: uid(800), scope: .category, categoryId: reconcile, amountE4: rub("5000"),
      startMonth: MonthKey(year: 2026, month: 1))
    data.book.budgets = [stored]
    data.spend("2026-09-05", "300", reconcile)
    data.add(
      .expense, "2026-09-10", [AdvicePart(amount: "8000", category: reconcile)],
      externalId: OperationLink.reconciliation(uid(990)).externalId)
    let ledger = data.ledger
    let line = try #require(
      LimitRules.lines(book: ledger.dataset.planning, ledger: ledger, today: today).first)
    #expect(line.spent == rub("300"))
    #expect(line.amount == rub("5000"))
    #expect(line.status == .ok)
  }

  /// The stored limit: emptying its field deletes it; a new amount is refused with the same
  /// words, from the field and from the list alike.
  @Test func aStoredLimitCanBeDeletedNotChanged() {
    let data = data()
    let tree = CategoryTree(data.categories)
    let stored = Budget(
      id: uid(800), scope: .category, categoryId: reconcile, amountE4: rub("5000"))
    #expect(
      LimitRules.settingCategoryLimit(
        reconcile, to: nil, budgets: [stored], tree: tree, in: month, limitless: limitless)
        == .delete(stored))
    #expect(
      LimitRules.settingCategoryLimit(
        reconcile, to: rub("6000"), budgets: [stored], tree: tree, in: month,
        limitless: limitless) == .refused(.reconciliationCategory))
    #expect(
      LimitRules.changingAmount(
        of: stored.id, to: rub("6000"), budgets: [stored], tree: tree, in: month,
        limitless: limitless) == .refused(.reconciliationCategory))
    #expect(
      LimitRules.changingAmount(
        of: stored.id, to: rub("5000"), budgets: [stored], tree: tree, in: month,
        limitless: limitless) == .unchanged)
  }

  /// Six months of spending filed under «Сверка»: the suggestions of a limit never name it,
  /// while the same spending on «Food» is named.
  @Test func noSuggestionNamesIt() {
    var data = data()
    for month in ["2026-03", "2026-04", "2026-05", "2026-06", "2026-07", "2026-08"] {
      data.spend("\(month)-10", "9000", reconcile)
      data.spend("\(month)-11", "4000", data.food)
    }
    let items = AdviceRules.limitSuggestions(data.context(today), budgets: [])
    #expect(items.map(\.subject) == [.category(data.food)])

    var unremembered = data
    unremembered.book.settings.reconcileExpenseCategoryId = nil
    let before = AdviceRules.limitSuggestions(unremembered.context(today), budgets: [])
    #expect(before.map(\.subject) == [.category(reconcile), .category(data.food)])
  }
}
