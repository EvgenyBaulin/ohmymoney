import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// The category model the pipeline trains, as the entry line and the editor use it
/// («1. история; 2. модель; 3. ручной выбор … уверенность не ниже порога →
/// категория подставляется; всегда показываются до трёх подсказок»).
@MainActor
final class CategoryModelInTheLineTests: XCTestCase {
  private var environment: AppEnvironment!
  private var directory: URL!
  private var dataDirectoryBefore: String?

  override func setUp() async throws {
    dataDirectoryBefore = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-model-line-\(UUID().uuidString)", isDirectory: true)
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
  /// What the model was last trained on, so a test can say what training again would give.
  private var trained: [CategoryExample] = []
  private var transactions: TransactionRepository { environment.transactions! }
  private var today: DateOnly { environment.today }

  /// Ten categories, each the one home of its own word, six times over: sixty examples and
  /// six a class — past the fifty and five the model needs before it says anything.
  private let words = [
    "coffee", "taxi", "bread", "cinema", "books", "pharmacy", "gym", "flowers", "phone", "shoes",
  ]

  @discardableResult
  private func trainTheModel() throws -> [String: CoreKit.Category] {
    var filed: [String: CoreKit.Category] = [:]
    var examples: [CategoryExample] = []
    for word in words {
      let category = CoreKit.Category(kind: .expense, name: "Model \(word)", quality: .neutral)
      try references.save(category)
      filed[word] = category
      for _ in 0..<6 {
        examples.append(
          CategoryExample(
            query: CategoryQuery(
              day: today, weekday: environment.calendar.weekdayIndex(today), kind: .expense,
              text: word, amountWhole: 250),
            partId: UUID(), categoryId: category.id))
      }
    }
    environment.categoryModel.hold(
      CategoryModel.train(on: examples, anchor: today), trainedOn: examples)
    trained = examples
    return filed
  }

  private func line(_ text: String) -> ParsedInput {
    InputLineParser(vocabulary: .empty, calendar: environment.calendar).parse(text, today: today)
  }

  // MARK: Asked at all

  /// The ↓ panel of the line, made the way the line makes it, asks the model the pipeline
  /// trained: words history has never seen but the model knows well are filed by the model
  /// and offered as its chip.
  func testTheLineAsksTheModelThePipelineTrained() throws {
    let filed = try trainTheModel()
    let model = EntryDraftModel(environment: environment)
    model.reload()

    model.apply(line("coffee 250"), amount: AmountE4(whole: 250), today: today)

    let coffee = try XCTUnwrap(filed["coffee"]?.id)
    XCTAssertEqual(model.categorySuggestions.first?.id, coffee)
    XCTAssertEqual(model.suggestionSources[coffee], .model)
    XCTAssertEqual(model.draft.parts[0].categoryId, coffee)
    XCTAssertEqual(model.draft.parts[0].categorySource, .model)
  }

  /// A category the model fills in brings its quality, as one chosen by hand or by history
  /// does: «Штрафы» is bad, so a fine the model files there is saved bad, and the day's streak
  /// without bad spending ends. The quality used to be worked out before the model had filed
  /// the part, so it was the quality of no category — ordinary.
  func testACategoryTheModelFillsBringsItsQuality() throws {
    let filed = try trainTheModel()
    var taxi = try XCTUnwrap(filed["taxi"])
    taxi.quality = .bad
    try references.save(taxi)
    let model = EntryDraftModel(environment: environment)
    model.reload()

    model.apply(line("taxi 250"), amount: AmountE4(whole: 250), today: today)

    let part = model.draft.parts[0]
    XCTAssertEqual(part.categoryId, taxi.id)
    XCTAssertEqual(part.categorySource, .model)
    XCTAssertEqual(part.quality, .bad)
    XCTAssertEqual(part.qualitySource, .category)
  }

  /// The editor of a saved operation asks the model the pipeline trained, like the ↓ panel of
  /// the line: a description the model knows well is filed by it, and offered as its chip.
  func testTheEditorAsksTheModelThePipelineTrained() throws {
    let filed = try trainTheModel()
    var draft = TransactionDraft(amount: AmountE4(whole: 250), note: "coffee")
    draft.normalizeSinglePart()
    let saved = try draft.materialize()
    try transactions.save(saved)

    let editor = TransactionEditorModel(entry: saved, environment: environment)
    editor.draft.applyDefaults(today: today)

    let coffee = try XCTUnwrap(filed["coffee"]?.id)
    XCTAssertEqual(editor.draft.categorySuggestions.first?.id, coffee)
    XCTAssertEqual(editor.draft.suggestionSources[coffee], .model)
    XCTAssertEqual(editor.draft.draft.parts[0].categoryId, coffee)
    XCTAssertEqual(editor.draft.draft.parts[0].categorySource, .model)
  }

  // MARK: The owner's choice

  /// The rows of `category_feedback`.
  private func feedbackRows() throws -> [CategoryFeedback] {
    try ModelRepository(writer: XCTUnwrap(environment.stack).writer).feedback()
  }

  /// What the pipeline would train on now, taken from the ledger the way step 4 takes it.
  private func examplesOfTheLedger() throws -> [CategoryExample] {
    let dataset = Dataset(
      entries: try transactions.recentEntries(limit: 1_000),
      categories: try references.categories(includeArchived: true))
    return LedgerTraining.examples(of: dataset, calendar: environment.calendar)
  }

  /// «Мой выбор пишется в `category_feedback`»: the model filed a saved «coffee» under
  /// Coffee, the owner filed it under Taxi in the editor and saved. The
  /// choice is written down — the words, what the model offered and how sure it was, what was
  /// chosen, the part — and the model knows it at once, exactly as training again would.
  func testACorrectionInTheEditorIsWrittenDownAndLearnedAtOnce() throws {
    let filed = try trainTheModel()
    let store = TransactionsStore()
    store.attach(
      transactions, references: environment.references, planning: environment.planning)
    var draft = TransactionDraft(amount: AmountE4(whole: 250), note: "coffee")
    draft.normalizeSinglePart()
    let saved = try draft.materialize()
    try transactions.save(saved)

    let editor = TransactionEditorModel(entry: saved, environment: environment)
    editor.draft.applyDefaults(today: today)
    let coffee = try XCTUnwrap(filed["coffee"]?.id)
    let taxi = try XCTUnwrap(filed["taxi"]?.id)
    let offered = try XCTUnwrap(editor.draft.lastPrediction?.suggestions.first)
    XCTAssertEqual(offered.categoryId, coffee)
    editor.draft.setCategory(taxi, forPartAt: 0)
    XCTAssertTrue(editor.save(store: store, environment: environment))

    let rows = try feedbackRows()
    XCTAssertEqual(rows.count, 1, "the owner's choice against the model was not written down")
    XCTAssertEqual(rows.first?.text, "coffee")
    XCTAssertEqual(rows.first?.predictedCategoryId, coffee)
    XCTAssertEqual(rows.first?.chosenCategoryId, taxi)
    XCTAssertEqual(rows.first?.partId, saved.parts[0].id)
    XCTAssertEqual(rows.first?.confidenceBp, offered.confidenceBp)

    let learned = try examplesOfTheLedger()
    XCTAssertEqual(learned.count, 1)
    XCTAssertEqual(
      environment.categoryModel.model,
      CategoryModel.train(on: trained + learned, anchor: today),
      "the correction reached the model only at the next run of the pipeline")
  }

  /// The line saves the way `EntryBar.commit` does: the operation, then what the model makes
  /// of it.
  private func saveFromTheLine(_ model: EntryDraftModel) throws -> TransactionEntry {
    let entry = try model.draft.materialize()
    try transactions.save(entry)
    CategoryLearning.saved(entry, choice: model.categoryChoice(), environment: environment)
    return entry
  }

  /// A new operation filed by hand against the model: written down, and learned at once —
  /// the next «coffee» already weighs it.
  func testAChoiceInTheLineIsWrittenDownAndLearnedAtOnce() throws {
    let filed = try trainTheModel()
    let model = EntryDraftModel(environment: environment)
    model.reload()
    model.apply(line("coffee 250"), amount: AmountE4(whole: 250), today: today)
    let taxi = try XCTUnwrap(filed["taxi"]?.id)
    model.setCategory(taxi, forPartAt: 0)

    let entry = try saveFromTheLine(model)

    let rows = try feedbackRows()
    XCTAssertEqual(rows.map(\.partId), [entry.parts[0].id])
    XCTAssertEqual(rows.first?.predictedCategoryId, filed["coffee"]?.id)
    XCTAssertEqual(rows.first?.chosenCategoryId, taxi)
    XCTAssertEqual(rows.first?.overrulesTheModel, true)
    XCTAssertEqual(
      environment.categoryModel.model,
      CategoryModel.train(on: trained + (try examplesOfTheLedger()), anchor: today))
  }

  /// A category the model filled in and the owner left alone is not the owner's choice, and
  /// not evidence either: nothing is written, nothing is learned.
  func testWhatTheModelFilledInAndWasLeftAloneIsNeitherWrittenNorLearned() throws {
    try trainTheModel()
    let model = EntryDraftModel(environment: environment)
    model.reload()
    model.apply(line("coffee 250"), amount: AmountE4(whole: 250), today: today)
    XCTAssertEqual(model.draft.parts[0].categorySource, .model)

    _ = try saveFromTheLine(model)

    XCTAssertEqual(try feedbackRows(), [])
    XCTAssertEqual(
      environment.categoryModel.model, CategoryModel.train(on: trained, anchor: today))
  }

  /// Opening a saved operation and changing only its amount chooses no category: nothing is
  /// written, and the model learns the new amount in place of the old one.
  func testAnEditThatLeavesTheCategoryWritesNoChoice() throws {
    let filed = try trainTheModel()
    let store = TransactionsStore()
    store.attach(
      transactions, references: environment.references, planning: environment.planning)
    var draft = TransactionDraft(amount: AmountE4(whole: 250), note: "coffee")
    draft.normalizeSinglePart()
    draft.parts[0].categoryId = filed["taxi"]?.id
    let saved = try draft.materialize()
    try transactions.save(saved)
    CategoryLearning.saved(saved, choice: nil, environment: environment)

    let editor = TransactionEditorModel(entry: saved, environment: environment)
    editor.draft.applyDefaults(today: today)
    editor.draft.setTotal(AmountE4(whole: 90_000))
    XCTAssertTrue(editor.save(store: store, environment: environment))

    XCTAssertEqual(try feedbackRows(), [])
    let learned = try examplesOfTheLedger()
    XCTAssertEqual(learned.map(\.query.amountWhole), [90_000])
    XCTAssertEqual(
      environment.categoryModel.model, CategoryModel.train(on: trained + learned, anchor: today))
  }

  // MARK: The question

  /// The panel asks the model the question it was taught with: the amount in rubles, as the
  /// save converts it, and the note of the part before the note of the operation —
  /// `LedgerTraining.query` of the operation the draft becomes.
  func testThePanelAsksWhatTheModelWasTaught() throws {
    let model = EntryDraftModel(environment: environment)
    model.reload()
    model.apply(line("hotel 100 usd"), amount: AmountE4(whole: 100), today: today)
    XCTAssertEqual(model.draft.currency, .usd)
    model.setManualRate("80")
    model.draft.parts[0].note = "breakfast"

    let asked = try XCTUnwrap(model.modelQuery())
    XCTAssertEqual(asked.amountWhole, 8_000, "asked about dollars, taught in rubles")
    XCTAssertEqual(asked.text, "breakfast", "the part's own note is what the model learns")

    environment.applyRate(to: &model.draft)
    let saved = try model.draft.materialize(
      rublesConverter: environment.rublesConverter(for: model.draft))
    let taught = LedgerTraining.query(
      entry: saved, part: saved.parts[0],
      day: environment.calendar.day(of: saved.transaction.occurredAt),
      calendar: environment.calendar, tree: CategoryTree())
    XCTAssertEqual(asked, taught)
  }

  /// A foreign amount with no rate known anywhere cannot be put in rubles: the model is not
  /// asked about a figure it was never taught, and offers nothing rather than a wrong bucket.
  func testAnAmountThatCannotBeConvertedIsNotAskedAbout() throws {
    try trainTheModel()
    let model = EntryDraftModel(environment: environment)
    model.reload()
    model.apply(line("coffee 3"), amount: AmountE4(whole: 3), today: today)
    XCTAssertNotNil(model.lastPrediction)
    model.apply(line("coffee 3 usd"), amount: AmountE4(whole: 3), today: today)

    XCTAssertNil(model.modelQuery())
    XCTAssertEqual(model.lastPrediction, nil, "what it said about rubles no longer stands")
    XCTAssertNil(model.categoryChoice())
  }
}
