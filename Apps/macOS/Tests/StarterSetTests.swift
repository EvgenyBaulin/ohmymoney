import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// The starter set on a database: a new one has «Зарплата» under «Заработок» and «Налоги и
/// сборы»; a set applied to a database of 1.3 removes nothing, ⌘Z takes all of it back in one
/// step, and applying it again doubles nothing.
@MainActor
final class StarterSetTests: XCTestCase {
  private var store: TransactionsStore!
  private var references: ReferenceRepository!
  private var planning: PlanningRepository!
  private var environment: AppEnvironment!

  override func setUp() async throws {
    let stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    references = ReferenceRepository(writer: stack.writer)
    planning = PlanningRepository(writer: stack.writer)
    store = TransactionsStore()
    store.attach(
      TransactionRepository(writer: stack.writer), references: references, planning: planning)
    environment = AppEnvironment()
  }

  func testANewDatabaseHasSalaryUnderWorkAndTaxesAndFees() throws {
    try references.seedCategoriesIfEmpty(StarterCategories.tree(language: "ru"))
    let categories = try references.categories(includeArchived: true)
    let work = try XCTUnwrap(categories.first { $0.name == "Заработок" && $0.parentId == nil })
    XCTAssertEqual(categories.first { $0.name == "Зарплата" }?.parentId, work.id)
    let taxes = try XCTUnwrap(categories.first { $0.name == "Налоги и сборы" })
    XCTAssertEqual(taxes.kind, .expense)
    XCTAssertEqual(
      Set(categories.filter { $0.parentId == taxes.id }.map(\.name)),
      ["Транспортный налог", "Имущественный налог", "НДФЛ"])
  }

  func testASetOnADatabaseOfOnePointThreeOnlyAddsAndUndoTakesItAllBack() throws {
    // A database of 1.3: the catalog without the categories of 1.4.
    try references.seedCategoriesIfEmpty(SampleCatalog.makeCategories(language: "ru"))
    let before = try references.categories(includeArchived: true)
    let budgetsBefore = try planning.book().budgets
    let dataset = Dataset(categories: before, planning: try planning.book())
    let plan = StarterSets.additions(
      for: StarterChoice(lifestyles: [.kids, .family]), language: "ru",
      existing: dataset.categories,
      budgets: dataset.planning.budgets, tiles: [], startMonth: MonthKey(year: 2026, month: 10))
    XCTAssertFalse(plan.categories.isEmpty)

    XCTAssertTrue(StarterSetActions.apply(plan, store: store, environment: environment))
    let after = try references.categories(includeArchived: true)
    XCTAssertTrue(Set(before.map(\.id)).isSubset(of: Set(after.map(\.id))), "nothing went")
    for old in before {
      XCTAssertEqual(after.first { $0.id == old.id }?.name, old.name, "nothing renamed")
    }
    XCTAssertEqual(after.count, before.count + plan.categories.count)
    XCTAssertEqual(try planning.book().budgets.count, budgetsBefore.count + plan.budgets.count)

    // Again: nothing is doubled.
    let again = StarterSets.additions(
      for: StarterChoice(lifestyles: [.kids, .family]), language: "ru", existing: after,
      budgets: try planning.book().budgets, tiles: [], startMonth: MonthKey(year: 2026, month: 10))
    XCTAssertTrue(again.categories.isEmpty && again.budgets.isEmpty)

    // One ⌘Z: every category and every limit of the set goes.
    store.undo()
    XCTAssertEqual(
      Set(try references.categories(includeArchived: true).map(\.id)), Set(before.map(\.id)))
    XCTAssertEqual(try planning.book().budgets.count, budgetsBefore.count)
  }
}
