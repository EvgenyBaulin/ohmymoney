import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// «Зарплата» under «Заработок» and «Налоги и сборы» are for new databases only: a database that
/// already has its categories keeps its tree as it is when the app opens it.
@MainActor
final class StarterCategoriesOldDatabaseTests: XCTestCase {
  func testADatabaseWithCategoriesKeepsItsTree() throws {
    let stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    let references = ReferenceRepository(writer: stack.writer)
    // A database of 1.3: the catalog without the categories of new databases.
    try references.seedCategoriesIfEmpty(SampleCatalog.makeCategories(language: "ru"))
    let before = try references.categories(includeArchived: true)
    XCTAssertFalse(before.contains { $0.name == "Зарплата" || $0.name == "Налоги и сборы" })

    // What every launch does with the starter categories.
    try references.seedCategoriesIfEmpty(StarterCategories.tree(language: "ru"))
    let after = try references.categories(includeArchived: true)
    XCTAssertEqual(Set(after.map(\.id)), Set(before.map(\.id)), "nothing added, nothing gone")
  }
}
