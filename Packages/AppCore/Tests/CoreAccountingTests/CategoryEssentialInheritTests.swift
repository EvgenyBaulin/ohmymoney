import CoreKit
import Foundation
import Testing

@testable import CoreAccounting

/// «Необходимая трата»: a category's own mark, else its parent's, else no; only an expense
/// category, never one that belongs to the app.
@Suite("Essential categories")
struct CategoryEssentialInheritTests {
  let food = CoreKit.Category(kind: .expense, name: "Продукты", essential: true)
  let cafe = CoreKit.Category(kind: .expense, name: "Кафе")
  let goals = CoreKit.Category(kind: .expense, name: "Цели", systemRole: .goals)
  let salary = CoreKit.Category(kind: .income, name: "Зарплата", essential: true)

  @Test func aSubcategoryFollowsItsParentUnlessItSaysOtherwise() {
    let market = CoreKit.Category(parentId: food.id, kind: .expense, name: "Рынок")
    let sweets = CoreKit.Category(
      parentId: food.id, kind: .expense, name: "Сладкое", essential: false)
    let lunch = CoreKit.Category(parentId: cafe.id, kind: .expense, name: "Обеды", essential: true)
    let tree = CategoryTree([food, cafe, market, sweets, lunch])
    #expect(tree.isEssential(food.id))
    #expect(tree.isEssential(market.id))
    #expect(!tree.isEssential(sweets.id))
    #expect(!tree.isEssential(cafe.id))
    #expect(tree.isEssential(lunch.id))
  }

  @Test func onlySpendingTheOwnerChoseIsEssential() {
    let trip = CoreKit.Category(parentId: goals.id, kind: .expense, name: "Отпуск", essential: true)
    var markedGoals = goals
    markedGoals.essential = true
    let tree = CategoryTree([markedGoals, trip, salary])
    #expect(!tree.isEssential(goals.id))
    #expect(!tree.isEssential(trip.id))
    #expect(!tree.isEssential(salary.id))
    #expect(!tree.isEssential(nil))
    #expect(!tree.isEssential(UUID()))
  }
}
