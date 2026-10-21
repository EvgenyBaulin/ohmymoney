import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// A real database in memory for the tests of the cushion: the environment, the store that
/// keeps ⌘Z, and reads of what was written.
@MainActor
class CushionDatabaseTestCase: XCTestCase {
  var environment: AppEnvironment!
  var store: TransactionsStore!
  private var directory: URL!
  private var dataDirectoryBefore: String?

  override func setUp() async throws {
    dataDirectoryBefore = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-cushion-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    setenv("OHMYMONEY_DATA_DIR", directory.path, 1)
    environment = AppEnvironment()
    await environment.start(preparing: {
      try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    })
    store = TransactionsStore()
    store.attach(
      try XCTUnwrap(environment.transactions), references: environment.references,
      planning: environment.planning)
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

  @discardableResult
  func account(
    _ name: String, archived: Bool = false, cushion: Bool = false
  ) throws
    -> PaymentMethod
  {
    var account = PaymentMethod(name: name, kind: .card, currency: .rub)
    account.archived = archived
    account.cushion = cushion
    try XCTUnwrap(environment.references).save(account)
    return account
  }

  @discardableResult
  func category(
    _ name: String, parent: UUID? = nil, kind: CategoryKind = .expense, essential: Bool? = nil
  ) throws -> CoreKit.Category {
    let category = CoreKit.Category(
      parentId: parent, kind: kind, name: name, sort: 500, essential: essential)
    try XCTUnwrap(environment.references).save(category)
    return category
  }

  func accounts() throws -> [PaymentMethod] {
    try XCTUnwrap(environment.accounts).accounts(includeArchived: true)
  }

  func categories() throws -> [CoreKit.Category] {
    try XCTUnwrap(environment.references).categories(includeArchived: true)
  }

  func stored(_ id: UUID) throws -> CoreKit.Category? {
    try categories().first { $0.id == id }
  }

  func setup() throws -> CushionSetup {
    CushionSetup(accounts: try accounts(), categories: try categories())
  }
}

/// «Счета и категории подушки»: the accounts ticked are the cushion, the categories ticked are
/// essential spending; a first setup ticks the usual essential categories by name in either
/// language and writes nothing until saved; the save is one step of ⌘Z.
@MainActor
final class CushionSetupSheetTests: CushionDatabaseTestCase {
  /// Nothing marked yet: the categories named like the usual essential ones — in Russian or in
  /// English, the case and «ё» aside — are ticked with their subcategories, and nothing else;
  /// nothing is in the database until the owner saves.
  func testAFirstSetupTicksTheUsualEssentialCategoriesByName() throws {
    let groceries = try category(" продукты ")
    let rent = try category("Rent")
    let flat = try category("Квартира", parent: rent.id)
    let fun = try category("Развлечения")
    let setup = try setup()
    XCTAssertTrue(setup.suggested)
    XCTAssertTrue(setup.essential.isSuperset(of: [groceries.id, rent.id, flat.id]))
    XCTAssertFalse(setup.essential.contains(fun.id))
    XCTAssertTrue(
      try categories().allSatisfy { $0.essential == nil }, "nothing written before «Сохранить»")
  }

  /// Once anything is marked the sheet shows what is stored — a subcategory as its parent says
  /// when it says nothing — and suggests nothing.
  func testAfterwardsTheSheetShowsWhatIsStored() throws {
    let groceries = try category("Продукты", essential: false)
    let home = try category("Дом", essential: true)
    let repairs = try category("Ремонт", parent: home.id)
    let setup = try setup()
    XCTAssertFalse(setup.suggested)
    XCTAssertEqual(
      setup.essential.intersection([groceries.id, home.id, repairs.id]),
      [
        home.id, repairs.id,
      ])
  }

  /// System categories, income and the archive are not offered; archived accounts neither.
  func testOnlyTheOwnersLiveExpenseCategoriesAndLiveAccountsAreOffered() throws {
    let live = try account("Сбер")
    let old = try account("Старый", archived: true)
    let salary = try category("Зарплата", kind: .income)
    let food = try category("Еда")
    var gone = try category("Прошлое")
    gone.archived = true
    try XCTUnwrap(environment.references).save(gone)
    let setup = try setup()
    let offered = Set(setup.categories.map(\.id))
    XCTAssertTrue(offered.contains(food.id))
    XCTAssertFalse(offered.contains(salary.id))
    XCTAssertFalse(offered.contains(gone.id))
    let tree = CategoryTree(try categories())
    XCTAssertTrue(setup.categories.allSatisfy { tree.systemRole(of: $0.id) == nil })
    XCTAssertTrue(setup.accounts.contains { $0.id == live.id })
    XCTAssertFalse(setup.accounts.contains { $0.id == old.id })
  }

  /// A subcategory stores nothing where it follows its parent, and its own «нет» where it is
  /// unticked under a ticked parent; what already counts as wanted stays as it is.
  func testWhatIsStoredForEachCategory() {
    XCTAssertNil(CushionSetup.storedValue(stored: nil, desired: true, inherited: true))
    XCTAssertEqual(CushionSetup.storedValue(stored: nil, desired: false, inherited: true), false)
    XCTAssertEqual(CushionSetup.storedValue(stored: nil, desired: true, inherited: false), true)
    XCTAssertEqual(CushionSetup.storedValue(stored: false, desired: false, inherited: false), false)
    XCTAssertNil(CushionSetup.storedValue(stored: true, desired: false, inherited: false))
    XCTAssertNil(CushionSetup.storedValue(stored: false, desired: true, inherited: true))
  }

  /// Saving writes the accounts and the categories in one change; one ⌘Z takes all of it back.
  func testTheSaveIsOneStepOfUndo() throws {
    let savings = try account("Копилка")
    let card = try account("Карта", cushion: true)
    let groceries = try category("Продукты")
    let home = try category("Дом")
    let repairs = try category("Ремонт", parent: home.id)

    var setup = try setup()
    setup.set(account: savings.id, cushion: true)
    setup.set(account: card.id, cushion: false)
    setup.set(home.id, essential: true)
    setup.set(repairs.id, essential: false)
    XCTAssertTrue(setup.essential.contains(groceries.id), "suggested")
    XCTAssertTrue(CushionSetupSheet.save(setup, store: store, now: environment.now()))

    XCTAssertEqual(try accounts().first { $0.id == savings.id }?.cushion, true)
    XCTAssertEqual(try accounts().first { $0.id == card.id }?.cushion, false)
    XCTAssertEqual(try stored(groceries.id)?.essential, true)
    XCTAssertEqual(try stored(home.id)?.essential, true)
    XCTAssertEqual(try stored(repairs.id)?.essential, false, "unticked under a ticked parent")
    let tree = CategoryTree(try categories())
    XCTAssertTrue(tree.isEssential(home.id))
    XCTAssertFalse(tree.isEssential(repairs.id))

    store.undo()
    XCTAssertEqual(try accounts().first { $0.id == savings.id }?.cushion, false)
    XCTAssertEqual(try accounts().first { $0.id == card.id }?.cushion, true)
    XCTAssertTrue(try categories().allSatisfy { $0.essential == nil }, "one ⌘Z: all of it back")
  }

  /// Saving what is already there writes nothing and keeps no step of ⌘Z.
  func testNothingChangedIsNothingWritten() throws {
    try account("Карта", cushion: true)
    try category("Еда", essential: false)
    let setup = try setup()
    XCTAssertNil(setup.change(at: environment.now()))
    XCTAssertFalse(store.canUndo)
    XCTAssertTrue(CushionSetupSheet.save(setup, store: store, now: environment.now()))
    XCTAssertFalse(store.canUndo)
  }
}
