import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

@MainActor
final class StarterCategoryAppearanceUndoTests: XCTestCase {
  func testPickingMarksIsOneUndoStepAndOneRedoStep() throws {
    let stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    let references = ReferenceRepository(writer: stack.writer)
    let transactions = TransactionRepository(writer: stack.writer)
    let store = TransactionsStore(repository: transactions, references: references)
    store.attach(
      transactions, references: references, planning: PlanningRepository(writer: stack.writer))
    let home = CoreKit.Category(kind: .expense, name: "Home")
    let work = CoreKit.Category(kind: .income, name: "Заработок")
    let own = CoreKit.Category(
      kind: .expense, name: "Groceries",
      appearance: CategoryAppearance(icon: "star", color: "tone3"))
    for category in [home, work, own] { try references.save(category) }
    let before = try references.categories(includeArchived: true)
    let change = try XCTUnwrap(CategoriesSettingsView.starterAppearanceChange(in: before))
    XCTAssertTrue(store.apply(change))
    let marked = try references.categories(includeArchived: true)
    XCTAssertEqual(marked.first { $0.id == home.id }?.icon, "house")
    XCTAssertEqual(marked.first { $0.id == work.id }?.icon, "briefcase")
    XCTAssertEqual(marked.first { $0.id == own.id }, own)
    XCTAssertNil(CategoriesSettingsView.starterAppearanceChange(in: marked))

    store.undo()
    XCTAssertEqual(try references.categories(includeArchived: true), before)
    XCTAssertFalse(store.canUndo)
    XCTAssertTrue(store.canRedo)
    store.redo()
    XCTAssertEqual(try references.categories(includeArchived: true), marked)
    XCTAssertFalse(store.canRedo)
    store.undo()
    XCTAssertEqual(try references.categories(includeArchived: true), before)
  }
}
