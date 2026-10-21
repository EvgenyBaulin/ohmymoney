import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// «Необходимая трата» in the menu of a category: «Как у категории» only for a subcategory,
/// nothing at the top read as «нет», no choice at all on a system category or on income; a
/// choice is one step of ⌘Z.
@MainActor
final class CategoryEssentialMenuTests: CushionDatabaseTestCase {
  func testTheChoicesAndWhatTheyStore() {
    let top = CoreKit.Category(kind: .expense, name: "Дом")
    let child = CoreKit.Category(parentId: top.id, kind: .expense, name: "Ремонт")
    XCTAssertEqual(CategoriesSettingsView.essentialChoices(for: top), [.yes, .no])
    XCTAssertEqual(CategoriesSettingsView.essentialChoices(for: child), [.inherit, .yes, .no])
    XCTAssertEqual(EssentialChoice(nil, isTop: true), .no)
    XCTAssertEqual(EssentialChoice(nil), .inherit)
    XCTAssertEqual(EssentialChoice(true), .yes)
    XCTAssertEqual(EssentialChoice(false, isTop: true), .no)
    XCTAssertNil(EssentialChoice.inherit.value)
    XCTAssertEqual(EssentialChoice.yes.value, true)
    XCTAssertEqual(EssentialChoice.no.value, false)
  }

  /// A system category, everything under it and an income category cannot be essential: the
  /// menu is disabled and no change is made for them.
  func testSystemCategoriesAndIncomeAreFixed() {
    let goals = CoreKit.Category(kind: .expense, name: "Цели", systemRole: .goals)
    let goal = CoreKit.Category(parentId: goals.id, kind: .expense, name: "Отпуск")
    let salary = CoreKit.Category(kind: .income, name: "Зарплата")
    let food = CoreKit.Category(kind: .expense, name: "Еда")
    let tree = CategoryTree([goals, goal, salary, food])
    XCTAssertTrue(CategoriesSettingsView.essentialIsFixed(goals, in: tree))
    XCTAssertTrue(CategoriesSettingsView.essentialIsFixed(goal, in: tree))
    XCTAssertTrue(CategoriesSettingsView.essentialIsFixed(salary, in: tree))
    XCTAssertFalse(CategoriesSettingsView.essentialIsFixed(food, in: tree))
    XCTAssertNil(
      CategoriesSettingsView.essentialChange(goal, to: .yes, tree: tree, at: Date()))
    XCTAssertNil(
      CategoriesSettingsView.essentialChange(food, to: .inherit, tree: tree, at: Date()),
      "what is stored already: nothing to write")
  }

  /// «Да» on a category, «Нет» on its subcategory: written, the subcategory counts as not
  /// essential, a sibling follows its parent; each choice is undone by its own ⌘Z.
  func testAChoiceIsOneStepOfUndo() throws {
    let home = try category("Дом")
    let repairs = try category("Ремонт", parent: home.id)
    let rent = try category("Аренда", parent: home.id)
    var tree = CategoryTree(try categories())
    let yes = try XCTUnwrap(
      CategoriesSettingsView.essentialChange(home, to: .yes, tree: tree, at: Date()))
    XCTAssertTrue(store.apply(yes))
    tree = CategoryTree(try categories())
    let no = try XCTUnwrap(
      CategoriesSettingsView.essentialChange(
        try XCTUnwrap(try stored(repairs.id)), to: .no, tree: tree, at: Date()))
    XCTAssertTrue(store.apply(no))

    tree = CategoryTree(try categories())
    XCTAssertTrue(tree.isEssential(home.id))
    XCTAssertTrue(tree.isEssential(rent.id), "follows its parent")
    XCTAssertFalse(tree.isEssential(repairs.id))

    store.undo()
    XCTAssertNil(try stored(repairs.id)?.essential)
    XCTAssertEqual(try stored(home.id)?.essential, true)
    store.undo()
    XCTAssertNil(try stored(home.id)?.essential)
  }

  /// The words of the menu, in both languages.
  func testTheWords() {
    environment.language.choice = .russian
    XCTAssertEqual(
      environment.language("categories.essential", table: "Settings"), "Необходимая трата")
    XCTAssertEqual(
      environment.language("categories.essential.inherit", table: "Settings"), "Как у категории")
    environment.language.choice = .english
    XCTAssertEqual(
      environment.language("categories.essential", table: "Settings"), "Essential spending")
  }
}
