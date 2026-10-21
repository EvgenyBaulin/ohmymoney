import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// A new quality of a category carried over to past operations: the question
/// counts over the pipeline's ledger, the answer is one write and one step of ⌘Z, and a
/// rating set by hand is never touched.
@MainActor
final class CategoryQualityTests: XCTestCase {
  private var repository: TransactionRepository!
  private var references: ReferenceRepository!
  private var store: TransactionsStore!
  private var written = 0
  private var groceries: UUID!

  private func makeStore() throws {
    let stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    repository = TransactionRepository(writer: stack.writer)
    references = ReferenceRepository(writer: stack.writer)
    try references.seedCategoriesIfEmpty(StarterCategories.tree(language: "en"))
    groceries = try XCTUnwrap(
      try references.categories().first { $0.name == "Groceries" && $0.parentId == nil }?.id)
    store = TransactionsStore(repository: repository, references: references)
    written = 0
    store.didWrite = { [weak self] _ in self?.written += 1 }
  }

  /// Operations in Groceries, rated the way the entry line rates them: by the category.
  private func saveGroceries(_ count: Int, source: QualitySource = .category) throws -> [UUID] {
    let start = CalendarContext.utc.startOfDay(DateOnly(year: 2026, month: 9, day: 1))
    let entries = try (0..<count).map { index in
      var draft = TransactionDraft(
        occurredAt: start.addingTimeInterval(TimeInterval(index) * 60),
        amount: AmountE4(whole: 100), note: "groceries \(index)")
      draft.normalizeSinglePart()
      draft.parts[0].categoryId = groceries
      draft.parts[0].quality = source == .manual ? .good : .neutral
      draft.parts[0].qualitySource = source
      return try draft.materialize()
    }
    try repository.insert(entries)
    return entries.map(\.id)
  }

  /// What the pipeline hands the store after reading the database.
  private func ledger() throws -> Ledger {
    let dataset = Dataset(
      entries: try repository.entries(from: .distantPast, to: .distantFuture),
      categories: try references.categories(includeArchived: true))
    let ledger = Ledger(dataset: dataset, calendar: .utc)
    store.show(ledger)
    return ledger
  }

  /// Settings saves the new quality, then counts what the past would change.
  private func rerate(_ quality: Quality) throws -> (CategoryQualityChange, [UUID]) {
    var category = try XCTUnwrap(try references.categories().first { $0.id == groceries })
    category.quality = quality
    try references.save(category)
    let change = CategoryQualityChange(categoryId: groceries)
    let ids = change.affected(try ledger().entries, tree: CategoryTree(store.categories()))
    return (change, ids)
  }

  private func qualities(_ ids: [UUID]) throws -> [Quality?] {
    let byId = Dictionary(
      uniqueKeysWithValues: try repository.entries(ids: ids).map { ($0.id, $0) })
    return ids.map { byId[$0]?.parts.first?.quality }
  }

  func testApplyingIsOneWriteAndOneUndoAndLeavesMyRatingsAlone() throws {
    try makeStore()
    let rated = try saveGroceries(3)
    let mine = try saveGroceries(1, source: .manual)

    let (change, ids) = try rerate(.bad)
    XCTAssertEqual(Set(ids), Set(rated), "the question counts only what would change")

    XCTAssertTrue(store.apply(change, to: ids))
    XCTAssertEqual(try qualities(rated), [.bad, .bad, .bad])
    XCTAssertEqual(try qualities(mine), [.good])
    XCTAssertEqual(written, 1)
    XCTAssertTrue(store.canUndo)

    store.undo()
    XCTAssertEqual(try qualities(rated), [.neutral, .neutral, .neutral])
    XCTAssertEqual(
      try repository.entries(ids: rated).map { $0.parts[0].qualitySource },
      [
        .category, .category, .category,
      ])
    XCTAssertEqual(written, 2, "the undo is reported too: a backup follows it")
    XCTAssertFalse(store.canUndo, "the whole change was one step")
    // The category's own quality is a setting, not a step of ⌘Z: it stays the new one.
    XCTAssertEqual(try references.categories().first { $0.id == groceries }?.quality, .bad)
  }

  /// «Only for new operations»: the new quality is saved and counted, and nothing is written
  /// — the operations keep the quality they took from the category, and there is no step to
  /// undo.
  func testDecliningLeavesTheOperationsAsTheyAreAndOnlyTheCategoryChanges() throws {
    try makeStore()
    let rated = try saveGroceries(3)

    let (_, ids) = try rerate(.bad)
    XCTAssertEqual(Set(ids), Set(rated), "the question was asked about them")

    XCTAssertEqual(try qualities(rated), [.neutral, .neutral, .neutral])
    XCTAssertEqual(
      try repository.entries(ids: rated).map { $0.parts[0].qualitySource },
      [.category, .category, .category])
    XCTAssertEqual(written, 0, "declining writes nothing")
    XCTAssertFalse(store.canUndo, "and leaves nothing to undo")
    XCTAssertEqual(try references.categories().first { $0.id == groceries }?.quality, .bad)
  }

  /// A part rated by hand after the question was asked keeps its rating: the write judges
  /// the rows as they are in the database, not the ones counted.
  func testARatingSetByHandAfterTheQuestionIsKept() throws {
    try makeStore()
    let ids = try saveGroceries(2)
    let (change, counted) = try rerate(.bad)
    XCTAssertTrue(store.apply(.quality(.good), to: [ids[0]]))

    XCTAssertTrue(store.apply(change, to: counted))
    XCTAssertEqual(try qualities(ids), [.good, .bad])
  }

  /// Beyond a thousand operations the write leaves the main thread, still one step.
  func testMoreThanAThousandLandInTheBackgroundAsOneStep() async throws {
    try makeStore()
    let rated = try saveGroceries(TransactionsStore.backgroundThreshold + 1)
    let (change, ids) = try rerate(.bad)
    XCTAssertEqual(ids.count, rated.count)

    XCTAssertTrue(store.apply(change, to: ids))
    XCTAssertTrue(store.isWritingInBackground)
    let write = try XCTUnwrap(store.backgroundWrite)
    let landed = await write.value
    XCTAssertTrue(landed)
    XCTAssertTrue(try qualities(rated).allSatisfy { $0 == .bad })

    store.undo()
    let undo = try XCTUnwrap(
      store.backgroundWrite, "a step that large is undone off the main thread")
    let undone = await undo.value
    XCTAssertTrue(undone)
    XCTAssertTrue(try qualities(rated).allSatisfy { $0 == .neutral })
    XCTAssertFalse(store.canUndo)
  }

  /// The starter list and `QualityResolver.Defaults` give every expense category the same
  /// quality: a subcategory without a default of its own is created empty and follows its
  /// parent — Pharmacy under Health is good.
  func testTheStarterCategoriesCarryTheDefaultsOfTheCore() {
    let tree = StarterCategories.tree(language: "en")
    let byId = Dictionary(uniqueKeysWithValues: tree.map { ($0.id, $0) })
    for category in tree where category.kind == .expense {
      let parent = category.parentId.flatMap { byId[$0] }
      XCTAssertEqual(
        category.quality,
        QualityResolver.Defaults.quality(named: category.name, parentNamed: parent?.name),
        category.name)
    }
  }

  func testTheQuestionIsTranslatedWithItsPluralForms() {
    let environment = AppEnvironment()
    for choice in [AppLanguage.Choice.english, .russian] {
      environment.language.choice = choice
      let words = [
        CategoryQualityText.title(environment.language),
        CategoryQualityText.message(3, environment.language),
        CategoryQualityText.apply(environment.language),
        CategoryQualityText.keep(environment.language),
      ]
      XCTAssertFalse(words.contains { $0.hasPrefix("categories.") }, "\(words)")
    }
    environment.language.choice = .russian
    XCTAssertTrue(
      CategoryQualityText.message(1, environment.language).hasPrefix(
        "Оценка изменится у 1 операции."))
    XCTAssertTrue(
      CategoryQualityText.message(3, environment.language).hasPrefix(
        "Оценка изменится у 3 операций."))
    XCTAssertTrue(
      CategoryQualityText.message(21, environment.language).hasPrefix(
        "Оценка изменится у 21 операции."))
    environment.language.choice = .english
    XCTAssertTrue(
      CategoryQualityText.message(1, environment.language).hasPrefix(
        "1 operation will be rated anew."))
  }
}
