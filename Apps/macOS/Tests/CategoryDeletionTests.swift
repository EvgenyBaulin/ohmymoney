import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// Deleting a category, and the archive being a place one can come back from.
///
/// The owner could not find the archive on 21.09 because there was nothing to find: the only
/// way out of a category was a small «В архив» button, and an archived category was never
/// listed again by anything in the app. He asked for deletion instead.
@MainActor
final class CategoryDeletionTests: XCTestCase {
  private var environment: AppEnvironment!
  private var store: TransactionsStore!
  private var directory: URL!
  private var dataDirectoryBefore: String?

  override func setUp() async throws {
    dataDirectoryBefore = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-categories-\(UUID().uuidString)", isDirectory: true)
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

  private var references: ReferenceRepository { environment.references! }

  @discardableResult
  private func makeCategory(_ name: String, parent: UUID? = nil) throws -> CoreKit.Category {
    let category = CoreKit.Category(
      parentId: parent, kind: .expense, name: name, sort: 100, quality: .neutral)
    try references.save(category)
    return category
  }

  private func delete(_ ids: [UUID]) -> Bool {
    var rows = PlanningRowIDs.empty
    rows.categories = ids
    return store.apply(PlanningChange(delete: rows))
  }

  private func spend(_ rubles: Int, in category: UUID) throws -> TransactionEntry {
    let when = Date()
    let id = UUID()
    let entry = TransactionEntry(
      transaction: Transaction(
        id: id, kind: .expense, occurredAt: when, amountE4: AmountE4(whole: Int64(rubles)),
        amountRubE4: AmountE4(whole: Int64(rubles)), createdAt: when, updatedAt: when),
      parts: [
        TransactionPart(
          transactionId: id, categoryId: category, quality: .neutral, qualitySource: .category,
          amountE4: AmountE4(whole: Int64(rubles)),
          amountRubE4: AmountE4(whole: Int64(rubles)))
      ])
    try XCTUnwrap(environment.transactions).save(entry)
    return entry
  }

  /// A split purchase, one part per `(rubles, category)`, each filed by `source`.
  private func spend(
    _ parts: [(rubles: Int, category: UUID)], source: CategorySource
  ) throws -> TransactionEntry {
    let when = Date()
    let id = UUID()
    let total = AmountE4(whole: Int64(parts.map(\.rubles).reduce(0, +)))
    let entry = TransactionEntry(
      transaction: Transaction(
        id: id, kind: .expense, occurredAt: when, amountE4: total, amountRubE4: total,
        createdAt: when, updatedAt: when),
      parts: parts.map {
        TransactionPart(
          transactionId: id, categoryId: $0.category, categorySource: source, quality: .neutral,
          qualitySource: .category, amountE4: AmountE4(whole: Int64($0.rubles)),
          amountRubE4: AmountE4(whole: Int64($0.rubles)))
      })
    try XCTUnwrap(environment.transactions).save(entry)
    return entry
  }

  func testACategoryNothingPointsAtIsDeletedAndOneUndoBringsItBack() throws {
    let category = try makeCategory("Kites")
    XCTAssertTrue(delete([category.id]))
    XCTAssertFalse(try references.categories().contains { $0.id == category.id })

    store.undo()
    let back = try references.categories().first { $0.id == category.id }
    XCTAssertEqual(back?.name, "Kites", "⌘Z did not bring the category back")
  }

  func testAParentGoesWithItsChildrenAndComesBackWithThem() throws {
    let parent = try makeCategory("Hobbies")
    let child = try makeCategory("Kites", parent: parent.id)

    // Children first: a parent still referenced by its own child cannot go.
    XCTAssertTrue(delete([child.id, parent.id]))
    let left = try references.categories().map(\.id)
    XCTAssertFalse(left.contains(parent.id))
    XCTAssertFalse(left.contains(child.id))

    store.undo()
    let back = try references.categories().map(\.id)
    XCTAssertTrue(back.contains(parent.id))
    XCTAssertTrue(back.contains(child.id))
  }

  /// The schema refuses it, and the app has to see the refusal rather than a row that simply
  /// does not move: this is why the question offers to move the operations first.
  func testACategoryWithOperationsIsNotDeleted() throws {
    let category = try makeCategory("Kites")
    _ = try spend(500, in: category.id)

    XCTAssertFalse(delete([category.id]), "a category with operations was deleted")
    XCTAssertTrue(try references.categories().contains { $0.id == category.id })
  }

  func testMovingTheOperationsFirstLetsTheCategoryGo() throws {
    let from = try makeCategory("Kites")
    let to = try makeCategory("Hobbies")
    let entry = try spend(500, in: from.id)
    store.show(
      Ledger(
        dataset: Dataset(entries: [entry], categories: try references.categories()),
        calendar: .system))

    XCTAssertTrue(store.apply(.category(to.id), to: [entry.id]))
    XCTAssertTrue(delete([from.id]))
    XCTAssertFalse(try references.categories().contains { $0.id == from.id })

    let moved = try XCTUnwrap(
      try XCTUnwrap(environment.transactions)
        .entries(from: .distantPast, to: .distantFuture).first)
    XCTAssertEqual(moved.parts.map(\.categoryId), [to.id])
  }

  /// An operation filed under the category after the question counted them is not among
  /// those that move, and the schema then refuses the deletion. The move has landed by then —
  /// a step of ⌘Z of its own — and the owner is told so, not only that the
  /// category stayed.
  func testADeletionRefusedAfterTheMoveSaysTheOperationsHaveMoved() throws {
    let from = try makeCategory("Kites")
    let to = try makeCategory("Hobbies")
    let counted = try spend(500, in: from.id)
    let filedSince = try spend(300, in: from.id)

    let outcome = CategoriesSettingsView.delete(
      [from.id], live: 1, moveTo: to.id, entries: [counted], store: store)

    XCTAssertTrue(outcome.moved)
    XCTAssertEqual(
      outcome.refusalKey, "categories.delete.failedAfterMove",
      "the refusal did not say the operations had already moved")
    XCTAssertTrue(try references.categories().contains { $0.id == from.id })
    let parts = try XCTUnwrap(environment.transactions)
      .entries(from: .distantPast, to: .distantFuture)
      .reduce(into: [UUID: UUID?]()) { $0[$1.id] = $1.parts.first?.categoryId }
    XCTAssertEqual(parts[counted.id], to.id)
    XCTAssertEqual(parts[filedSince.id], from.id)

    let language = AppLanguage()
    for choice in [AppLanguage.Choice.english, .russian] {
      language.choice = choice
      let key = "categories.delete.failedAfterMove"
      XCTAssertNotEqual(language(key, table: "Settings"), key, "\(choice)")
    }
  }

  /// Each part of a split has a category of its own, and the question promises
  /// to move the operations filed under the category going — so only their parts move. Until
  /// 24.09 the move was the list's bulk change, which reaches every part of a split: the
  /// groceries of a receipt ended up in «Hobbies» along with the kites.
  func testMovingTheOperationsOfACategoryLeavesTheOtherPartsOfASplitWhereTheyAre() throws {
    let from = try makeCategory("Kites")
    let to = try makeCategory("Hobbies")
    let groceries = try makeCategory("Groceries")
    let receipt = try spend([(300, from.id), (700, groceries.id)], source: .model)
    store.show(
      Ledger(
        dataset: Dataset(entries: [receipt], categories: try references.categories()),
        calendar: .system))

    XCTAssertTrue(
      CategoriesSettingsView.moveOperations(
        of: [from.id], to: to.id, entries: [receipt], store: store))

    let moved = try XCTUnwrap(
      try XCTUnwrap(environment.transactions).entries(ids: [receipt.id]).first)
    XCTAssertEqual(
      moved.parts.map(\.categoryId), [to.id, groceries.id],
      "a part in another category was moved with the one going")
    XCTAssertEqual(moved.parts.map(\.categorySource), [.manual, .model])
    XCTAssertEqual(moved.parts[1], receipt.parts[1], "the part left in place was rewritten")
    XCTAssertTrue(delete([from.id]), "the category still had something pointing at it")
  }

  /// The archive is a place: a category put there is still there to be found and brought back.
  func testAnArchivedCategoryIsListedWhenAskedForAndComesBack() throws {
    var category = try makeCategory("Kites")
    category.archived = true
    try references.save(category)

    XCTAssertFalse(
      try references.categories().contains { $0.id == category.id },
      "an archived category is listed by default")
    XCTAssertTrue(
      try references.categories(includeArchived: true).contains { $0.id == category.id },
      "an archived category could not be found at all")

    category.archived = false
    try references.save(category)
    XCTAssertTrue(try references.categories().contains { $0.id == category.id })
  }

  /// «Добавить» in Settings → Категории with the name of a category in the archive — «kites»
  /// for «Kites», beside the same parent — brings that category back rather than making a
  /// second one; a subcategory comes back under its own parent only.
  func testAddingTheNameOfAnArchivedCategoryBringsItBack() throws {
    var kites = try makeCategory("Kites")
    kites.archived = true
    try references.save(kites)
    let home = try makeCategory("Home")
    var rent = try makeCategory("Rent", parent: home.id)
    rent.archived = true
    try references.save(rent)

    XCTAssertEqual(
      CategoriesSettingsView.add(
        named: "kites", kind: .expense, parent: nil, references: references),
      .added(kites.id))
    XCTAssertEqual(
      CategoriesSettingsView.add(
        named: "rent", kind: .expense, parent: home.id, references: references),
      .added(rent.id))
    let all = try references.categories(includeArchived: true)
    XCTAssertEqual(
      all.filter { $0.name.lowercased() == "kites" }.map(\.id), [kites.id],
      "a second «Kites» was made")
    XCTAssertEqual(all.first { $0.id == kites.id }?.archived, false)
    XCTAssertEqual(all.first { $0.id == rent.id }?.archived, false)

    let income = CategoriesSettingsView.add(
      named: "Kites", kind: .income, parent: nil, references: references)
    XCTAssertNotEqual(income, .added(kites.id), "an expense came back for an income")
  }

  /// The bin is the case the app cannot get out of: a deleted operation keeps its parts, and
  /// nothing re-files the parts of an operation in the bin. The count has to come from the
  /// database — the pipeline's data is read with `deleted_at IS NULL` and never holds one.
  func testOperationsInTheBinAreCountedAndStillHoldTheCategory() throws {
    let category = try makeCategory("Kites")
    let entry = try spend(500, in: category.id)
    let transactions = try XCTUnwrap(environment.transactions)

    XCTAssertEqual(try transactions.binnedOperations(inCategories: [category.id]), 0)
    _ = try transactions.softDelete(id: entry.id)
    XCTAssertEqual(
      try transactions.binnedOperations(inCategories: [category.id]), 1,
      "an operation in the bin was not counted against its category")
    XCTAssertTrue(
      try transactions.entries(from: .distantPast, to: .distantFuture).isEmpty,
      "the live read still shows it, so counting from the pipeline would have worked")
    XCTAssertFalse(delete([category.id]), "a category the bin points at was deleted")
  }

  /// A goal's subcategory carries no role of its own and takes it from Goals through the
  /// tree. Judged by `isSystem` alone it looked like an ordinary category, and the owner
  /// could archive it — after which the next contribution quietly made a second one.
  func testASubcategoryOfASystemCategoryIsOwnedByTheApp() throws {
    let categories = try references.categories()
    let goals = try XCTUnwrap(categories.first { $0.systemRole == .goals })
    let subcategory = try makeCategory("A bicycle", parent: goals.id)

    let tree = CategoryTree(try references.categories())
    XCTAssertNil(subcategory.systemRole, "the subcategory carries a role of its own")
    XCTAssertEqual(tree.systemRole(of: subcategory.id), .goals, "the tree lost the role")
  }
}
