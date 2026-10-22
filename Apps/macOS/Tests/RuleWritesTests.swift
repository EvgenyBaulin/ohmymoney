import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// The writes the rules, tags and exchange screens make, against a real database: one step of
/// ⌘Z for each, and what the dictionary and the list look like after.
@MainActor
final class RuleWritesTests: XCTestCase {
  private var environment: AppEnvironment!
  private var store: TransactionsStore!
  private var directory: URL!
  private var dataDirectoryBefore: String?

  override func setUp() async throws {
    dataDirectoryBefore = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-rules-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    setenv("OHMYMONEY_DATA_DIR", directory.path, 1)
    environment = AppEnvironment()
    await environment.start(preparing: {
      try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    })
    store = TransactionsStore()
    store.attach(
      try XCTUnwrap(environment.transactions), references: environment.references,
      planning: environment.planning, spending: environment.spendingRules)
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

  // MARK: Helpers

  private func spending() throws -> SpendingRulesRepository {
    try XCTUnwrap(environment.spendingRules)
  }

  private func loaded() async throws -> Dataset {
    try await DatasetRepository(writer: try XCTUnwrap(environment.stack).writer).load(version: 1)
  }

  @discardableResult
  private func spend(
    _ note: String, _ whole: Int64 = 100, hoursAgo: Double = 2
  ) throws
    -> TransactionEntry
  {
    var draft = TransactionDraft(
      occurredAt: Date().addingTimeInterval(-hoursAgo * 3_600), amount: AmountE4(whole: whole),
      note: note)
    draft.normalizeSinglePart()
    let entry = try draft.materialize()
    XCTAssertTrue(store.save(entry))
    return entry
  }

  private func category(_ name: String, kind: CategoryKind = .expense) throws -> CoreKit.Category {
    let category = CoreKit.Category(kind: kind, name: name)
    try XCTUnwrap(environment.references).save(category)
    return category
  }

  private func snapshot() async throws -> DataSnapshot {
    let dataset = try await loaded()
    let calendar = environment.calendar
    return DataSnapshot.build(
      dataset: dataset, calendar: calendar, today: calendar.day(of: Date()),
      context: SnapshotContext(), version: DataVersion(load: 1))
  }

  // MARK: Several rules at once

  func testRulesAddedTogetherAreOneStepOfUndo() async throws {
    let food = try category("Продукты")
    let rules = (0..<3).map { index in
      Rule(
        name: "r\(index)", position: index, conditions: [.textContains("w\(index)")],
        actions: [.setCategory(food.id)])
    }
    XCTAssertTrue(store.addRules(rules))
    var stored = try await loaded().rules
    XCTAssertEqual(stored.map(\.name), ["r0", "r1", "r2"])
    store.undo()
    stored = try await loaded().rules
    XCTAssertTrue(stored.isEmpty, "one ⌘Z took all three")
    XCTAssertTrue(store.addRules([]), "nothing to add is not a failure")
  }

  func testTagsAndRuleTagsOfASavedOperationAreOneStep() async throws {
    let entry = try spend("ужин")
    let part = try XCTUnwrap(entry.parts.first).id
    let book = try spending().tagBook()
    XCTAssertTrue(book.tags.isEmpty)
    let named = Tag(name: "работа")
    XCTAssertTrue(store.apply(TagEdit(before: book, after: TagBook(tags: [named]))))
    XCTAssertTrue(
      store.tag(parts: [part], names: ["Отпуск", "#отпуск"], ruleTagIds: [named.id, named.id]))
    let after = try await loaded().tagBook
    XCTAssertEqual(Set(after.tags.map(\.name)), ["работа", "Отпуск"])
    XCTAssertEqual(after.links.count, 2, "each tag once on the part")
    store.undo()
    let undone = try await loaded().tagBook
    XCTAssertEqual(undone.tags.map(\.name), ["работа"], "the tags typed went, the old one stayed")
    XCTAssertTrue(undone.links.isEmpty)
    // A tag a rule named that is gone is not put on anything.
    XCTAssertTrue(store.tag(parts: [part], names: [], ruleTagIds: [UUID()]))
    let still = try await loaded().tagBook
    XCTAssertTrue(still.links.isEmpty)
  }

  // MARK: The exchange file

  func testAFileOfRulesGoesFromOneDatabaseToTheNext() async throws {
    let food = try category("Продукты")
    let cafe = try category("Кафе")
    let tag = Tag(name: "еда")
    XCTAssertTrue(store.apply(TagEdit(before: TagBook(), after: TagBook(tags: [tag]))))
    let shared = Rule(
      name: "Пятёрочка", position: 0, conditions: [.textContains("пятёрочка")],
      actions: [.setCategory(food.id), .addTag(tag.id)])
    let withOwnCard = Rule(
      name: "С моей карты", position: 1, conditions: [.card(UUID())],
      actions: [.setCategory(cafe.id)])
    XCTAssertTrue(store.addRules([shared, withOwnCard]))

    let dataset = try await loaded()
    let selection = RuleExportSelection(rules: dataset.rules)
    XCTAssertEqual(selection.chosen.map(\.name), ["Пятёрочка"], "personal rules start unticked")
    let bundle = RuleExchange.export(
      rules: selection.chosen, directory: ExchangeDirectory(dataset: dataset), title: "Еда")
    let file = try bundle.encoded()
    let read = try RuleBundle.decoded(from: file)
    XCTAssertEqual(read.title, "Еда")

    // The other database: empty but for one category of the same name.
    let other = try await emptyReceiver(with: ["Продукты"])
    let preview = RuleExchange.preview(
      read, into: ExchangeDirectory(dataset: other.dataset), existing: other.dataset.rules)
    XCTAssertEqual(preview.categoriesMatched, ["Продукты"])
    XCTAssertEqual(preview.tagsToAdd.map(\.name), ["еда"])
    XCTAssertEqual(preview.rulesToAdd.count, 1)
    XCTAssertEqual(preview.rulesToAdd.first?.origin, .exchange)

    let outcome = RuleExchangeWriter.write(
      preview, environment: other.environment, store: other.store)
    XCTAssertEqual(outcome, RuleExchangeWriter.Outcome(categories: 0, tags: 1, rules: 1))
    let received = try await DatasetRepository(
      writer: try XCTUnwrap(other.environment.stack).writer
    ).load(version: 1)
    XCTAssertEqual(received.rules.map(\.name), ["Пятёрочка"])
    XCTAssertEqual(received.tagBook.tags.map(\.name), ["еда"])
    let local = try XCTUnwrap(received.categories.first { $0.name == "Продукты" })
    XCTAssertEqual(received.rules.first?.actions.first, .setCategory(local.id), "points at yours")

    // Opening the same file again adds nothing.
    let again = RuleExchange.preview(
      read, into: ExchangeDirectory(dataset: received), existing: received.rules)
    XCTAssertTrue(again.rulesToAdd.isEmpty)
    XCTAssertEqual(again.rulesAlreadyThere, ["Пятёрочка"])

    // ⌘Z: the rules first, then the tags; nothing of the receiver's own was removed.
    other.store.undo()
    var after = try await DatasetRepository(
      writer: try XCTUnwrap(other.environment.stack).writer
    ).load(version: 1)
    XCTAssertTrue(after.rules.isEmpty)
    XCTAssertEqual(after.tagBook.tags.count, 1)
    other.store.undo()
    after = try await DatasetRepository(writer: try XCTUnwrap(other.environment.stack).writer)
      .load(version: 1)
    XCTAssertTrue(after.tagBook.tags.isEmpty)
    XCTAssertTrue(after.categories.contains { $0.name == "Продукты" })
    await other.environment.close()
  }

  func testCategoriesFromAFileAreWrittenAndNothingIsRenamed() async throws {
    let sender = try category("Подарки")
    let bundle = RuleExchange.export(
      rules: [
        Rule(
          name: "Цветы", conditions: [.textContains("цветы")], actions: [.setCategory(sender.id)])
      ], directory: ExchangeDirectory(dataset: try await loaded()))
    let other = try await emptyReceiver(with: ["Продукты"])
    let preview = RuleExchange.preview(
      bundle, into: ExchangeDirectory(dataset: other.dataset), existing: [])
    XCTAssertEqual(preview.categoriesToAdd.map(\.name), ["Подарки"])
    let outcome = RuleExchangeWriter.write(
      preview, environment: other.environment, store: other.store)
    XCTAssertEqual(outcome.categories, 1)
    XCTAssertEqual(outcome.rules, 1)
    XCTAssertFalse(outcome.failed)
    let names = try XCTUnwrap(other.environment.references).categories().map(\.name)
    XCTAssertTrue(names.contains("Подарки"))
    XCTAssertTrue(names.contains("Продукты"))
    await other.environment.close()
  }

  // MARK: Applying to the past

  func testThePreviewIsWhatIsWrittenAndOneUndoBringsItBack() async throws {
    let food = try category("Продукты")
    let old = try spend("пятёрочка", 300, hoursAgo: 72)
    let rule = Rule(
      name: "Пятёрочка", conditions: [.textContains("пятёрочка")],
      actions: [.setCategory(food.id)])
    XCTAssertTrue(store.addRule(rule))
    let shot = try await snapshot()
    let plan = try await AnalysisFacade().rules.backfillPlan(shot)
    XCTAssertEqual(plan.items.map(\.id), [old.id])
    let wording = RuleWording(environment: environment, names: RuleNames(dataset: shot.dataset))
    let lines = BackfillRowText.lines(
      try XCTUnwrap(plan.items.first), names: RuleNames(dataset: shot.dataset), wording: wording)
    XCTAssertEqual(lines.count, 1)
    XCTAssertTrue(lines[0].contains("Продукты"), lines[0])

    XCTAssertTrue(store.applyBackfill(plan.commit(selection: plan.defaultSelection)))
    let written = try XCTUnwrap(
      try XCTUnwrap(environment.transactions).entries(ids: [old.id]).first)
    XCTAssertEqual(written.parts.first?.categoryId, food.id)
    XCTAssertEqual(store.lastBackfill?.written, 1)
    let result = BackfillResult(
      written: 1, links: 0, stale: 0, landed: true)
    XCTAssertEqual(result.symbol, "checkmark.circle")

    store.undo()
    let back = try XCTUnwrap(try XCTUnwrap(environment.transactions).entries(ids: [old.id]).first)
    XCTAssertEqual(back.parts.first?.categoryId, old.parts.first?.categoryId)
    XCTAssertEqual(
      back.transaction.updatedAt.timeIntervalSince1970,
      old.transaction.updatedAt.timeIntervalSince1970, accuracy: 0.01, "the old date of edit")
  }

  func testWhatTheOwnerEditedByHandStartsUnticked() async throws {
    let food = try category("Продукты")
    var draft = TransactionDraft(
      occurredAt: Date().addingTimeInterval(-86_400), amount: AmountE4(whole: 100),
      note: "пятёрочка")
    draft.normalizeSinglePart()
    var entry = try draft.materialize()
    // Written long ago, edited today: the edit is the owner's.
    entry.transaction.createdAt = Date().addingTimeInterval(-10 * 86_400)
    entry.transaction.updatedAt = Date().addingTimeInterval(-3_600)
    XCTAssertTrue(store.save(entry))
    XCTAssertTrue(
      store.addRule(
        Rule(conditions: [.textContains("пятёрочка")], actions: [.setCategory(food.id)])))
    let plan = try await AnalysisFacade().rules.backfillPlan(try await snapshot())
    let item = try XCTUnwrap(plan.items.first)
    XCTAssertTrue(item.editedByHand)
    XCTAssertFalse(item.selectedByDefault)
    XCTAssertTrue(plan.defaultSelection.isEmpty)
  }

  // MARK: Tags

  func testTheRowsOfTheDictionaryAreSortedAndArchivedOnesWaitForTheSwitch() {
    let a = Tag(name: "яблоко")
    let b = Tag(name: "Ананас")
    let c = Tag(name: "прошлое", archived: true)
    let book = TagBook(tags: [a, b, c], links: [PartTag(partId: UUID(), tagId: a.id)])
    let rows = TagRow.rows(book: book, report: nil, showsArchive: false)
    XCTAssertEqual(rows.map(\.tag.name), ["Ананас", "яблоко"])
    XCTAssertEqual(rows.last?.parts, 1)
    let all = TagRow.rows(book: book, report: nil, showsArchive: true)
    XCTAssertEqual(all.map(\.tag.name), ["Ананас", "яблоко", "прошлое"], "archive last")
  }

  func testDeletingATagTellsWhatItDoesToTheRules() {
    let tag = Tag(name: "еда")
    let other = Tag(name: "кафе")
    let book = TagBook(tags: [tag, other])
    let lonely = Rule(conditions: [.textContains("a")], actions: [.addTag(tag.id)])
    let shared = Rule(
      conditions: [.textContains("b")], actions: [.addTag(tag.id), .addTag(other.id)])
    let unrelated = Rule(conditions: [.textContains("c")], actions: [.addTag(other.id)])
    XCTAssertEqual(
      TagChange.deletion(of: tag.id, book: book, rules: [lonely, shared, unrelated]),
      TagChange.Deletion(rulesChanged: 1, rulesRemoved: 1))
  }

  func testTheTagReportSaysWhenTheRowsOverlap() async throws {
    let entry = try spend("ужин", 3_500)
    let part = try XCTUnwrap(entry.parts.first).id
    XCTAssertTrue(store.tag(parts: [part], names: ["отпуск", "турция"]))
    let shot = try await snapshot()
    let report = try await AnalysisFacade().tags.report(shot)
    XCTAssertEqual(report.rows.count, 2)
    XCTAssertTrue(report.rowsOverlap)
    let ru = AppEnvironment()
    ru.language.choice = .russian
    let caption = try XCTUnwrap(TagReportText.overlapCaption(report, ru))
    XCTAssertTrue(caption.contains("в каждый из них"), caption)
    ru.language.choice = .system
    // One tag on a part: the rows add up and nothing is said.
    let single = TagReport.compute(
      entries: [entry], links: [PartTag(partId: part, tagId: report.rows[0].tagId)])
    XCTAssertNil(TagReportText.overlapCaption(single, ru))
  }

  func testThePeriodsOfTheReportEndToday() {
    let today = DateOnly(year: 2026, month: 10, day: 22)
    XCTAssertEqual(
      TagReportPeriod.month.range(today: today)?.start, DateOnly(year: 2026, month: 10, day: 1))
    XCTAssertEqual(
      TagReportPeriod.year.range(today: today)?.start, DateOnly(year: 2026, month: 1, day: 1))
    XCTAssertNil(TagReportPeriod.all.range(today: today))
    XCTAssertEqual(TagReportPeriod.month.range(today: today)?.end, today)
  }

  // MARK: The settings

  func testTheSettingsSearchFindsTheRulesAndTheTagsInBothLanguages() {
    let words = SettingsSearch.catalogWords()
    for (query, expected) in [
      ("правил", true), ("теги", true), ("rules", true), ("tag", true), ("файл", true),
    ] {
      let found = SettingsSearch.find(query, words: words).map(\.section)
      XCTAssertEqual(found.contains(.rules), expected, query)
    }
    let tags = SettingsSearch.find("объединить", words: words)
    XCTAssertEqual(tags.first { $0.section == .rules }?.captions, [.rules("tags.merge")])
  }

  // MARK: Helpers for a second database

  private struct Receiver {
    var environment: AppEnvironment
    var store: TransactionsStore
    var dataset: Dataset
  }

  /// A second, empty database with the categories named.
  private func emptyReceiver(with categories: [String]) async throws -> Receiver {
    let other = AppEnvironment()
    await other.start(preparing: {
      try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    })
    let store = TransactionsStore()
    store.attach(
      try XCTUnwrap(other.transactions), references: other.references,
      planning: other.planning, spending: other.spendingRules)
    for name in categories {
      try XCTUnwrap(other.references).save(CoreKit.Category(kind: .expense, name: name))
    }
    let dataset = try await DatasetRepository(writer: try XCTUnwrap(other.stack).writer)
      .load(version: 1)
    return Receiver(environment: other, store: store, dataset: dataset)
  }
}
