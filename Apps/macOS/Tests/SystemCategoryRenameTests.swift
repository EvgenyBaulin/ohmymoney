import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// The categories the app keeps for itself — Goals, Loans, «Не помню», Surcharges — can be
/// renamed in Settings. They stay what they are: the app finds them by their role and their
/// place in the tree, never by name, so a new name changes nothing but the words on screen.
@MainActor
final class SystemCategoryRenameTests: XCTestCase {
  private var environment: AppEnvironment!
  private var directory: URL!
  private var dataDirectoryBefore: String?

  override func setUp() async throws {
    dataDirectoryBefore = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-rename-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    setenv("OHMYMONEY_DATA_DIR", directory.path, 1)
    environment = AppEnvironment()
    await environment.start(preparing: {
      try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    })
  }

  override func tearDown() async throws {
    if let environment { await environment.close() }
    if let dataDirectoryBefore {
      setenv("OHMYMONEY_DATA_DIR", dataDirectoryBefore, 1)
    } else {
      unsetenv("OHMYMONEY_DATA_DIR")
    }
    if let directory { try? FileManager.default.removeItem(at: directory) }
  }

  private var references: ReferenceRepository { environment.references! }

  func testARenamedSystemCategoryIsStillFoundByItsRole() throws {
    let system = try references.categories().filter(\.isSystem)
    XCTAssertFalse(system.isEmpty, "the starter categories carry no system category")

    for category in system {
      let renamed = try XCTUnwrap(
        CategoriesSettingsView.renamed(category, to: "Renamed \(category.name)"))
      XCTAssertEqual(renamed.systemRole, category.systemRole, "a rename dropped the role")
      try references.save(renamed)
    }

    let tree = CategoryTree(try references.categories())
    for category in system {
      let role = try XCTUnwrap(category.systemRole)
      let found = try XCTUnwrap(
        try references.category(systemRole: role, kind: category.kind), "\(role) was lost")
      XCTAssertEqual(found.id, category.id)
      XCTAssertEqual(found.name, "Renamed \(category.name)")
      XCTAssertEqual(tree.systemCategory(role, kind: category.kind)?.id, category.id)
      XCTAssertEqual(tree.systemRole(of: category.id), role)
    }
  }

  /// A goal still gets its subcategory under Goals renamed, and that subcategory is still the
  /// app's: a good contribution, no quality to choose.
  func testAGoalStillFilesItsSubcategoryUnderGoalsRenamed() throws {
    let goals = try XCTUnwrap(try references.category(systemRole: .goals, kind: .expense))
    try references.save(try XCTUnwrap(CategoriesSettingsView.renamed(goals, to: "Накопления")))

    let tree = CategoryTree(try references.categories())
    let goal = Goal(name: "A bicycle", targetE4: AmountE4(whole: 50_000))
    let subcategory = try XCTUnwrap(SystemSubcategories.goalSubcategory(for: goal, tree: tree))
    XCTAssertEqual(subcategory.parentId, goals.id)

    let grown = CategoryTree(try references.categories() + [subcategory])
    XCTAssertEqual(grown.systemRole(of: subcategory.id), .goals)
    XCTAssertTrue(CategoriesSettingsView.qualityIsFixed(subcategory, in: grown))
  }

  /// «Не помню» renamed «Продукты» made two categories of one name in every picker and in the
  /// entry line. A name another live category of the kind already has — under the same parent,
  /// or at the top — is refused, whatever its case; under another parent, of the other kind, or
  /// in the archive, it is not.
  func testARenameToANameAnotherCategoryHasIsRefused() throws {
    let all = try references.categories(includeArchived: true)
    let unknown = try XCTUnwrap(try references.category(systemRole: .unknown, kind: .expense))
    let root = try XCTUnwrap(
      all.first { $0.kind == .expense && $0.parentId == nil && !$0.isSystem },
      "the starter categories carry no expense category of the owner's")
    XCTAssertTrue(
      CategoriesSettingsView.nameIsTaken(root.name.uppercased(), by: unknown, among: all))
    XCTAssertFalse(
      CategoriesSettingsView.nameIsTaken("Something else entirely", by: unknown, among: all))

    let food = CoreKit.Category(kind: .expense, name: "Еда")
    let cafe = CoreKit.Category(kind: .expense, name: "Кафе")
    let coffee = CoreKit.Category(parentId: food.id, kind: .expense, name: "Кофе")
    let hedgehog = CoreKit.Category(parentId: food.id, kind: .expense, name: "Ёжик")
    let other = CoreKit.Category(parentId: food.id, kind: .expense, name: "Другое")
    let elsewhere = CoreKit.Category(parentId: cafe.id, kind: .expense, name: "Разное")
    let salary = CoreKit.Category(kind: .income, name: "Зарплата", archived: true)
    let book = [food, cafe, coffee, hedgehog, other, elsewhere, salary]
    func taken(_ name: String, by category: CoreKit.Category) -> Bool {
      CategoriesSettingsView.nameIsTaken(name, by: category, among: book)
    }

    XCTAssertTrue(taken("  кофе ", by: other), "a sibling's name")
    XCTAssertTrue(taken("ежик", by: other), "a sibling's name with «е» for «ё»")
    XCTAssertTrue(taken("КАФЕ", by: other), "a category's name for a subcategory")
    XCTAssertTrue(taken("Кофе", by: cafe), "a subcategory's name for a category")
    XCTAssertFalse(taken("Другое", by: elsewhere), "the same name under another parent")
    XCTAssertFalse(taken("зарплата", by: food), "the name of the other kind")
    XCTAssertFalse(taken("КОФЕ", by: coffee), "its own name in another case")
    XCTAssertFalse(
      CategoriesSettingsView.nameIsTaken(
        "Зарплата", by: CoreKit.Category(kind: .income, name: "Бонус"), among: book),
      "the name of an archived category, which no picker shows")
  }

  func testTheCaptionOfASystemCategoryIsSaidInBothLanguages() {
    for choice in [AppLanguage.Choice.english, .russian] {
      environment.language.choice = choice
      for key in ["categories.system", "categories.system.help", "categories.rename.taken"] {
        XCTAssertNotEqual(environment.language(key, table: "Settings"), key, "\(key), \(choice)")
      }
    }
    environment.language.choice = .russian
    XCTAssertEqual(environment.language("categories.system", table: "Settings"), "системная")
  }
}
