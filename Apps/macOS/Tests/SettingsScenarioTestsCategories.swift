import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// The marks a category carries in «Настройки → Категории»: «Необходимая трата» and «Налог».
/// A subcategory without a mark of its own follows its parent, a mark of its own wins either
/// way, system categories and the other kind never carry one, and the marks survive the database.
final class SettingsScenarioCategoryMarksTests: XCTestCase {
  private let food = CoreKit.Category(kind: .expense, name: "Продукты", essential: true)
  private let fun = CoreKit.Category(kind: .expense, name: "Развлечения")
  private let work = CoreKit.Category(
    kind: .income, name: "Самозанятость", tax: IncomeTax(rate: 4, npd: true))
  private let goals = CoreKit.Category(
    kind: .expense, name: "Цели", systemRole: .goals, essential: true)

  private func child(
    of parent: CoreKit.Category, essential: Bool? = nil, tax: IncomeTax? = nil
  ) -> CoreKit.Category {
    CoreKit.Category(
      parentId: parent.id, kind: parent.kind, name: "child", essential: essential, tax: tax)
  }

  func testASubcategoryFollowsAnEssentialParent() {
    let bread = child(of: food)
    let tree = CategoryTree([food, bread])
    XCTAssertTrue(tree.isEssential(food.id))
    XCTAssertTrue(tree.isEssential(bread.id))
  }

  /// «Нет» on a subcategory wins over «Да» of its parent, and «Да» over a parent without a mark.
  func testAMarkOfItsOwnWinsEitherWay() {
    let sweets = child(of: food, essential: false)
    let doctor = child(of: fun, essential: true)
    let tree = CategoryTree([food, fun, sweets, doctor])
    XCTAssertFalse(tree.isEssential(sweets.id))
    XCTAssertTrue(tree.isEssential(doctor.id))
    XCTAssertFalse(tree.isEssential(fun.id))
  }

  /// A system category is never essential, whatever the database says.
  func testASystemCategoryIsNeverEssential() {
    let tree = CategoryTree([goals, child(of: goals, essential: true)])
    XCTAssertFalse(tree.isEssential(goals.id))
    XCTAssertFalse(tree.isEssential(tree.children(of: goals.id).first?.id))
  }

  func testAnIncomeOrNothingIsNeverEssential() {
    let marked = CoreKit.Category(kind: .income, name: "Зарплата", essential: true)
    let tree = CategoryTree([marked])
    XCTAssertFalse(tree.isEssential(marked.id))
    XCTAssertFalse(tree.isEssential(nil))
    XCTAssertFalse(tree.isEssential(UUID()))
  }

  func testASubcategoryOwesTheTaxOfItsParent() {
    let people = child(of: work)
    let tree = CategoryTree([work, people])
    XCTAssertEqual(tree.tax(of: people.id), IncomeTax(rate: 4, npd: true))
  }

  /// 6 % from organisations below 4 % from individuals: a rate of its own wins.
  func testATaxOfItsOwnWins() {
    let organisations = child(of: work, tax: IncomeTax(rate: 6, npd: true))
    let tree = CategoryTree([work, organisations])
    XCTAssertEqual(tree.tax(of: organisations.id)?.rate, 6)
  }

  /// A rate of zero or below is no tax — on the category and on what follows it.
  func testARateOfZeroIsNoTax() {
    let none = CoreKit.Category(kind: .income, name: "Подарки", tax: IncomeTax(rate: 0))
    let negative = CoreKit.Category(kind: .income, name: "Ошибка", tax: IncomeTax(rate: -1))
    let tree = CategoryTree([none, negative, child(of: none)])
    XCTAssertNil(tree.tax(of: none.id))
    XCTAssertNil(tree.tax(of: negative.id))
    XCTAssertNil(tree.tax(of: tree.children(of: none.id).first?.id))
  }

  /// A rate of zero on a subcategory stops the parent's tax for it.
  func testAZeroOnASubcategoryStopsTheParentsTax() {
    let refund = child(of: work, tax: IncomeTax(rate: 0))
    XCTAssertNil(CategoryTree([work, refund]).tax(of: refund.id))
  }

  func testAnExpenseOwesNoTax() {
    let odd = CoreKit.Category(kind: .expense, name: "Странная", tax: IncomeTax(rate: 13))
    XCTAssertNil(CategoryTree([odd]).tax(of: odd.id))
  }

  /// A rate with a fraction — USN 6 %, an odd 3.5 % — is kept exactly.
  func testAFractionalRateIsKeptExactly() {
    let usn = CoreKit.Category(
      kind: .income, name: "УСН", tax: IncomeTax(rate: Decimal(string: "3.5")!))
    XCTAssertEqual(CategoryTree([usn]).tax(of: usn.id)?.rate, Decimal(string: "3.5"))
    XCTAssertEqual(CategoryTree([usn]).tax(of: usn.id)?.npd, false)
  }

  /// The marks are written to the database and read back as they were.
  func testTheMarksSurviveTheDatabase() throws {
    let stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    let books = ReferenceRepository(writer: stack.writer)
    let organisations = child(of: work, tax: IncomeTax(rate: 6, npd: true))
    let sweets = child(of: food, essential: false)
    for category in [food, fun, work, organisations, sweets] { try books.save(category) }
    let read = Dictionary(uniqueKeysWithValues: try books.categories().map { ($0.id, $0) })
    XCTAssertEqual(read[food.id]?.essential, true)
    XCTAssertNil(read[fun.id]?.essential)
    XCTAssertEqual(read[sweets.id]?.essential, false)
    XCTAssertEqual(read[work.id]?.tax, IncomeTax(rate: 4, npd: true))
    XCTAssertEqual(read[organisations.id]?.tax, IncomeTax(rate: 6, npd: true))
  }

  /// The starter tree of a new base has its system categories in both languages, and none of
  /// them is essential or taxed.
  func testTheStarterTreeHasItsSystemCategoriesInBothLanguages() {
    for language in ["ru", "en"] {
      let starter = StarterCategories.tree(language: language)
      let roles = Set(starter.compactMap(\.systemRole))
      XCTAssertTrue(roles.isSuperset(of: [.goals, .loans, .unknown]), "\(language): \(roles)")
      let tree = CategoryTree(starter)
      for category in starter where category.isSystem {
        XCTAssertFalse(tree.isEssential(category.id), "\(language) \(category.name)")
        XCTAssertFalse(category.acceptsLimit, "\(language) \(category.name)")
      }
    }
  }

  /// Seeding a base that has categories adds none: the owner's tree stays as it is.
  func testSeedingABaseWithCategoriesAddsNone() throws {
    let stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    let books = ReferenceRepository(writer: stack.writer)
    try books.seedCategoriesIfEmpty(StarterCategories.tree(language: "ru"))
    let first = try books.categories().count
    try books.seedCategoriesIfEmpty(StarterCategories.tree(language: "en"))
    XCTAssertEqual(try books.categories().count, first)
  }
}
