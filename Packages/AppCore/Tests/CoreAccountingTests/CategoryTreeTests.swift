import CoreKit
import Foundation
import Testing

@testable import CoreAccounting

@Suite("Reading the category list")
struct CategoryTreeTests {
  let categories = StartingCategories()

  @Test func systemCategoriesTakeNoLimit() {
    #expect(categories.tree.acceptsLimit(categories.goals) == false)
    #expect(categories.tree.acceptsLimit(categories.loans) == false)
    #expect(categories.tree.acceptsLimit(categories.unknown) == false)
    #expect(categories.tree.acceptsLimit(categories.surcharges) == false)
    #expect(categories.tree[categories.goals]?.acceptsLimit == false)
  }

  @Test func theSubcategoriesOfASystemCategoryTakeNoLimitEither() {
    #expect(categories.tree.acceptsLimit(categories.goalsTrip) == false)
    #expect(categories.tree.acceptsLimit(categories.loansCar) == false)
  }

  @Test func ordinaryCategoriesTakeLimits() {
    #expect(categories.tree.acceptsLimit(categories.groceries))
    #expect(categories.tree.acceptsLimit(categories.fuel))
    #expect(categories.tree.acceptsLimit(nil) == false)
    #expect(categories.tree.acceptsLimit(id(999)) == false)
  }

  @Test func aSystemRoleReachesTheSubcategories() {
    #expect(categories.tree.systemRole(of: categories.goalsTrip) == .goals)
    #expect(categories.tree.systemRole(of: categories.loansCar) == .loans)
    #expect(categories.tree.systemRole(of: categories.fuel) == nil)
    #expect(categories.tree.isGoalCategory(categories.goalsTrip))
    #expect(categories.tree.isLoanCategory(categories.loansCar))
    #expect(categories.tree.isGoalCategory(categories.groceries) == false)
  }

  @Test func rootAndParentWalkOneLevelUp() {
    #expect(categories.tree.root(of: categories.fuel)?.id == categories.car)
    #expect(categories.tree.root(of: categories.car)?.id == categories.car)
    #expect(categories.tree.parent(of: categories.fuel)?.id == categories.car)
    #expect(categories.tree.parent(of: categories.car) == nil)
    #expect(categories.tree.children(of: categories.car).map(\.name) == ["Fines", "Fuel"])
  }

  @Test func qualityIsInheritedOnlyWhenTheSubcategoryHasNone() {
    #expect(categories.tree.effectiveQuality(of: categories.fuel) == .neutral)
    #expect(categories.tree.effectiveQuality(of: categories.fines) == .bad)
    #expect(categories.tree.inheritsQuality(categories.fuel))
    #expect(categories.tree.inheritsQuality(categories.fines) == false)
    #expect(categories.tree.inheritsQuality(categories.car) == false)
    #expect(categories.tree.effectiveQuality(of: id(999)) == nil)
  }

  @Test func theSystemCategoriesCanBeFoundByRole() {
    #expect(categories.tree.systemCategory(.goals)?.id == categories.goals)
    #expect(categories.tree.systemCategory(.surcharges)?.id == categories.surcharges)
    #expect(CategoryTree().systemCategory(.goals) == nil)
    #expect(CategoryTree().isEmpty)
    #expect(categories.tree.count == 17)
  }

  /// «Не помню» есть и у расходов, и у доходов: схема держит одну роль на вид, а не одну на
  /// всё. Корень ищется по роли и виду; без вида и на испорченных данных, где у двух корней
  /// одна роль, ответ всё равно один — он не зависит от того, как лёг словарь.
  @Test func aSystemRoleIsFoundByItsKindAndNeverByHashOrder() {
    let expenseUnknown = id(301)
    let incomeUnknown = id(302)
    let rows = [
      CoreKit.Category(
        id: expenseUnknown, kind: .expense, name: "Unknown", sort: 5, systemRole: .unknown),
      CoreKit.Category(
        id: incomeUnknown, kind: .income, name: "Unknown", sort: 1, systemRole: .unknown),
    ]
    // Other rows change the size of the index and with it the order a dictionary walks in.
    for count in 0..<50 {
      let tree = CategoryTree(rows.shuffled() + filler(count))
      #expect(tree.systemCategory(.unknown, kind: .income)?.id == incomeUnknown)
      #expect(tree.systemCategory(.unknown, kind: .expense)?.id == expenseUnknown)
      #expect(tree.systemCategory(.unknown)?.id == expenseUnknown)
      #expect(tree.systemCategory(.unknown, kind: .income)?.kind == .income)
    }

    let first = id(303)
    let second = id(304)
    let broken = [
      CoreKit.Category(id: second, kind: .expense, name: "Goals", systemRole: .goals),
      CoreKit.Category(id: first, kind: .expense, name: "Goals", systemRole: .goals),
    ]
    let answers = Set(
      (0..<50).map { CategoryTree(broken.shuffled() + filler($0)).systemCategory(.goals)?.id })
    #expect(answers == [first])
  }

  private func filler(_ count: Int) -> [CoreKit.Category] {
    (0..<count).map { CoreKit.Category(id: id(400 + $0), kind: .expense, name: "Filler \($0)") }
  }
}
