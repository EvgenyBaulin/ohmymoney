import CoreKit
import Foundation
import Testing

@testable import CoreAccounting

/// Editing the rules: «Запомнить», the sheet's save by key, what a rule may name, «Как в
/// прошлом месяце».
@Suite("Editing cashback rules")
struct CashbackRulesTests {
  let fixture = CashbackFixture()

  func rule(
    _ number: Int, card: UUID? = nil, category: UUID?, month: MonthKey? = nil, _ e4: Int64
  ) -> CashbackRule {
    CashbackRule(
      id: id(number), accountId: fixture.tBank, cardId: card ?? fixture.black,
      categoryId: category, month: month, percent: CashbackPercent(e4: e4)!)
  }

  @Test func rememberReusesTheIdOfTheSameKey() {
    let kept = rule(1, category: fixture.pharmacy, month: fixture.september, 50_000)
    let typed = rule(2, category: fixture.pharmacy, month: fixture.september, 70_000)
    let written = CashbackRules.upserting(typed, into: [kept])
    #expect(written.id == id(1) && written.percent.e4 == 70_000)
    let other = rule(3, category: fixture.pharmacy, 70_000)
    #expect(CashbackRules.upserting(other, into: [kept]).id == id(3))
  }

  /// Two rows swap their categories: every key is there before and after, so every row keeps
  /// its id and nothing is written at all; the unique index never sees two rows of one key.
  @Test func aSwapOfTwoRowsSaves() {
    let old = [rule(1, category: fixture.cafes, 50_000), rule(2, category: fixture.home, 30_000)]
    let swapped = [
      rule(1, category: fixture.home, 30_000), rule(2, category: fixture.cafes, 50_000),
    ]
    let diff = CashbackRules.diff(old: old, new: swapped)
    #expect(diff.upserts.isEmpty && diff.deletions.isEmpty)
    // With the percents changed too, each key keeps its own row.
    let changed = [
      rule(1, category: fixture.home, 40_000), rule(2, category: fixture.cafes, 60_000),
    ]
    let second = CashbackRules.diff(old: old, new: changed)
    #expect(second.deletions.isEmpty)
    #expect(
      Set(second.upserts.map { "\($0.id) \($0.categoryId!) \($0.percent.e4)" }) == [
        "\(id(1)) \(fixture.cafes) 60000", "\(id(2)) \(fixture.home) 40000",
      ])
  }

  /// «Кафе 5 %» removed and «Кафе 7 %» added again: the old row takes 7 %.
  @Test func removingAndReaddingAKeyReusesItsId() {
    let old = [rule(1, category: fixture.cafes, 50_000)]
    let diff = CashbackRules.diff(old: old, new: [rule(9, category: fixture.cafes, 70_000)])
    #expect(diff.deletions.isEmpty)
    #expect(diff.upserts.map(\.id) == [id(1)] && diff.upserts[0].percent.e4 == 70_000)
  }

  /// The owner changes the category of a row: «Кафе 5 %» becomes «Дом 5 %». The row's old key
  /// is gone and its rule is deleted, so the new key needs a row of its own — never the id that
  /// is being deleted in the same save. In a chain (Кафе → Дом, Дом → Кино) «Дом» stays on its
  /// row and «Кино» gets a new one: two rules, not one.
  @Test func aRowMovedToANewCategoryGetsARowOfItsOwn() {
    let old = [rule(1, category: fixture.cafes, 50_000)]
    let moved = CashbackRules.diff(old: old, new: [rule(1, category: fixture.home, 50_000)])
    #expect(moved.deletions == [id(1)])
    #expect(moved.upserts.count == 1)
    #expect(moved.upserts.first?.categoryId == fixture.home)
    #expect(moved.upserts.first?.percent.e4 == 50_000)
    #expect(Set(moved.upserts.map(\.id)).isDisjoint(with: moved.deletions))

    let before = [
      rule(1, category: fixture.cafes, 50_000), rule(2, category: fixture.home, 30_000),
    ]
    let chain = CashbackRules.diff(
      old: before,
      new: [rule(1, category: fixture.home, 50_000), rule(2, category: fixture.cinema, 30_000)])
    #expect(chain.deletions == [id(1)])
    #expect(Set(chain.upserts.map(\.id)).count == chain.upserts.count)
    #expect(Set(chain.upserts.map(\.id)).isDisjoint(with: chain.deletions))
    #expect(chain.upserts.first { $0.categoryId == fixture.home }?.id == id(2))
    #expect(
      Set(chain.upserts.map { "\($0.categoryId!) \($0.percent.e4)" }) == [
        "\(fixture.home) 50000", "\(fixture.cinema) 30000",
      ])
  }

  @Test func aKeyGoneIsDeletedAndANewKeyIsAdded() {
    let old = [rule(1, category: fixture.cafes, 50_000), rule(2, category: fixture.home, 10_000)]
    let diff = CashbackRules.diff(
      old: old, new: [rule(1, category: fixture.cafes, 50_000), rule(3, category: nil, 10_000)])
    #expect(diff.deletions == [id(2)])
    #expect(diff.upserts.map(\.id) == [id(3)])
  }

  @Test func diffRefusesDuplicates() {
    let twice = [
      rule(1, category: fixture.cafes, 50_000), rule(2, category: fixture.cafes, 70_000),
    ]
    #expect(
      CashbackRules.issues(twice, tree: fixture.tree) == [
        .duplicate(twice[0].key)
      ])
  }

  @Test func diffRefusesIncomeAndGoalCategories() {
    let reconcile = id(250)
    let tree = CategoryTree(
      [CoreKit.Category(id: reconcile, kind: .expense, name: "Count")]
        + [fixture.salary, fixture.goalTrip, fixture.loans, fixture.goals].compactMap {
          fixture.tree.category($0)
        })
    let rules = [
      rule(1, category: fixture.salary, 10_000), rule(2, category: fixture.goalTrip, 10_000),
      rule(3, category: reconcile, 10_000), rule(4, category: fixture.loans, 0),
    ]
    #expect(
      CashbackRules.issues(rules, tree: tree, reconcileCategoryIds: [reconcile]) == [
        .categoryNotExpense(fixture.salary), .categoryIsGoal(fixture.goalTrip),
        .categoryIsReconciliation(reconcile), .categoryIsLoan(fixture.loans),
      ])
  }

  /// The rules belong to the account, whether it has cards or not: a rule of the account itself
  /// is fine on an account with live cards.
  @Test func anAccountRuleWithCardsIsFine() {
    let own = CashbackRule(
      accountId: fixture.tBank, categoryId: nil, percent: CashbackPercent(e4: 10_000)!)
    #expect(CashbackRules.issues([own], tree: fixture.tree).isEmpty)
    let cash = CashbackRule(accountId: fixture.cash, percent: CashbackPercent(e4: 10_000)!)
    #expect(CashbackRules.issues([cash], tree: fixture.tree).isEmpty)
  }

  /// A payment on a debt earns nothing, so no rule may name «Кредиты» or what is under it.
  @Test func aRuleOnLoansIsRefused() {
    let sub = id(260)
    let tree = CategoryTree(
      [CoreKit.Category(id: sub, parentId: fixture.loans, kind: .expense, name: "Mortgage")]
        + [fixture.loans].compactMap { fixture.tree.category($0) })
    let rules = [
      rule(1, category: fixture.loans, 0), rule(2, category: sub, 10_000),
    ]
    #expect(
      CashbackRules.issues(rules, tree: tree) == [
        .categoryIsLoan(fixture.loans), .categoryIsLoan(sub),
      ])
  }

  @Test func copyLastMonthSkipsExistingKeys() {
    let august = MonthKey(year: 2026, month: 8)
    let rules = [
      rule(1, category: fixture.cafes, month: august, 100_000),
      rule(2, category: fixture.home, month: august, 30_000),
      rule(3, category: fixture.home, month: fixture.september, 50_000),
      rule(4, card: fixture.virtual, category: fixture.cinema, month: august, 30_000),
    ]
    let copies = CashbackRules.copied(
      month: august, to: fixture.september, holder: .card(fixture.black), rules: rules)
    #expect(copies.count == 1)
    #expect(copies[0].categoryId == fixture.cafes && copies[0].month == fixture.september)
    #expect(copies[0].percent.e4 == 100_000 && copies[0].id != id(1))
  }

  @Test func theCategoriesARuleMayName() {
    let reconcile = id(250)
    let categories =
      [CoreKit.Category(id: reconcile, kind: .expense, name: "Count", sort: 9)]
      + [
        fixture.cafes, fixture.coffee, fixture.loans, fixture.goals, fixture.goalTrip,
        fixture.salary,
      ].compactMap { fixture.tree.category($0) }
    let tree = CategoryTree(categories)
    let choices = CashbackRules.categoryChoices(
      tree: tree, categories: categories, reconcileCategoryIds: [reconcile])
    #expect(choices.map(\.id) == [fixture.cafes, fixture.coffee])
  }
}
