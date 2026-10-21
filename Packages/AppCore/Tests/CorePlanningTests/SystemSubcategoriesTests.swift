import CoreAccounting
import CoreKit
import Foundation
import Testing

@testable import CorePlanning

@Suite("System subcategories of goals and debts")
struct SystemSubcategoriesTests: SavingsFixtures {
  var goalsRoot: UUID { uid(1) }
  var loansRoot: UUID { uid(3) }

  /// Goals has a live «Car» (sort 0) and an archived «Old» (sort 5); Loans has «Bank loan»
  /// (sort 2).
  var categories: [CoreKit.Category] {
    [
      CoreKit.Category(
        id: goalsRoot, kind: .expense, name: "Goals", quality: .good, systemRole: .goals),
      CoreKit.Category(id: uid(2), parentId: goalsRoot, kind: .expense, name: "Car", sort: 0),
      CoreKit.Category(
        id: uid(4), parentId: goalsRoot, kind: .expense, name: "Old", sort: 5, archived: true),
      CoreKit.Category(
        id: loansRoot, kind: .expense, name: "Loans", quality: .neutral, systemRole: .loans),
      CoreKit.Category(
        id: uid(6), parentId: loansRoot, kind: .expense, name: "Bank loan", sort: 2),
      CoreKit.Category(id: uid(10), kind: .expense, name: "Groceries"),
    ]
  }

  var tree: CategoryTree { CategoryTree(categories) }

  func goal(_ number: Int, subcategory: UUID? = nil, archived: Bool = false) -> Goal {
    Goal(
      id: uid(number), name: "Goal \(number)", targetE4: rub("1000"), subcategoryId: subcategory,
      archived: archived)
  }

  func debt(
    _ number: Int, direction: DebtDirection = .iOwe, paymentsAreExpenses: Bool = true,
    closed: Bool = false, subcategory: UUID? = nil
  ) -> Debt {
    Debt(
      id: uid(number), direction: direction, type: .loan, name: "Debt \(number)",
      paymentsAreExpenses: paymentsAreExpenses, closed: closed, loansSubcategoryId: subcategory)
  }

  /// A goal without a subcategory gets one under Goals, after the children already there
  /// (the archived one included): sort 6. No quality and no role of its own — both come
  /// from Goals.
  @Test func aGoalWithoutASubcategoryGetsOneUnderGoals() throws {
    let created = try #require(
      SystemSubcategories.goalSubcategory(for: goal(500), tree: tree, id: uid(900)))
    #expect(created.id == uid(900))
    #expect(created.parentId == goalsRoot)
    #expect(created.kind == .expense)
    #expect(created.name == "Goal 500")
    #expect(created.sort == 6)
    #expect(created.quality == nil)
    #expect(created.systemRole == nil)
    #expect(!created.archived)
    let grown = CategoryTree(categories + [created])
    #expect(grown.isGoalCategory(created.id))
    #expect(grown.effectiveQuality(of: created.id) == .good)
  }

  @Test func aGoalWithALiveSubcategoryNeedsNone() {
    #expect(
      SystemSubcategories.goalSubcategory(for: goal(500, subcategory: uid(2)), tree: tree) == nil)
  }

  /// A subcategory gone from the list or archived is not live: a new one is made.
  @Test func aMissingOrArchivedSubcategoryIsReplaced() {
    #expect(
      SystemSubcategories.goalSubcategory(for: goal(500, subcategory: uid(99)), tree: tree) != nil)
    #expect(
      SystemSubcategories.goalSubcategory(for: goal(500, subcategory: uid(4)), tree: tree) != nil)
  }

  @Test func archivedGoalsAndBooksWithoutGoalsGetNothing() {
    #expect(SystemSubcategories.goalSubcategory(for: goal(500, archived: true), tree: tree) == nil)
    let withoutGoals = CategoryTree(categories.filter { $0.id != goalsRoot })
    #expect(SystemSubcategories.goalSubcategory(for: goal(500), tree: withoutGoals) == nil)
  }

  /// Only a debt I owe whose payments are expenses gets a subcategory under Loans — after
  /// «Bank loan» (sort 2), so sort 3; its quality follows Loans (`neutral`).
  @Test func onlyADebtWhosePaymentsAreExpensesGetsALoanSubcategory() throws {
    let created = try #require(
      SystemSubcategories.loanSubcategory(for: debt(600), tree: tree, id: uid(901)))
    #expect(created.id == uid(901))
    #expect(created.parentId == loansRoot)
    #expect(created.name == "Debt 600")
    #expect(created.sort == 3)
    #expect(created.kind == .expense)
    let grown = CategoryTree(categories + [created])
    #expect(grown.isLoanCategory(created.id))
    #expect(grown.effectiveQuality(of: created.id) == .neutral)

    // Bought here on credit: the payments are not expenses.
    #expect(
      SystemSubcategories.loanSubcategory(for: debt(601, paymentsAreExpenses: false), tree: tree)
        == nil)
    // Owed to me: a payment is money coming back, never an expense.
    #expect(
      SystemSubcategories.loanSubcategory(for: debt(602, direction: .owedToMe), tree: tree) == nil)
    #expect(SystemSubcategories.loanSubcategory(for: debt(603, closed: true), tree: tree) == nil)
    #expect(
      SystemSubcategories.loanSubcategory(for: debt(604, subcategory: uid(6)), tree: tree) == nil)
    #expect(
      SystemSubcategories.loanSubcategory(for: debt(605, subcategory: uid(98)), tree: tree) != nil)
  }

  /// Everything at once: goals first, then debts, in the order given; two new children of
  /// Goals take 6 and 7. An id is drawn only for what is really made.
  @Test func missingListsEverythingWithConsecutiveSorts() {
    var next = 900
    let made = SystemSubcategories.missing(
      goals: [goal(500), goal(501, subcategory: uid(2)), goal(502, subcategory: uid(99))],
      debts: [debt(600), debt(601, paymentsAreExpenses: false)], tree: tree,
      makeId: {
        next += 1
        return uid(next)
      })
    #expect(made.map(\.id) == [uid(901), uid(902), uid(903)])
    #expect(made.map(\.name) == ["Goal 500", "Goal 502", "Debt 600"])
    #expect(made.map(\.parentId) == [goalsRoot, goalsRoot, loansRoot])
    #expect(made.map(\.sort) == [6, 7, 3])
  }
}
