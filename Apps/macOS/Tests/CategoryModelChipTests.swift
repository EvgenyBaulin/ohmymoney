import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// What the ↓ panel stores as the source of a category the model had a say in, and what that
/// source means for the next training.
///
/// A category the model filled in by itself is stored `.model` and is not evidence — the model
/// does not learn from its own guesses. A category the owner chose — a chip pressed, a picker
/// set — is evidence.
@MainActor
final class CategoryModelChipTests: XCTestCase {
  private var stack: DatabaseStack!
  private var references: ReferenceRepository!
  private var transactions: TransactionRepository!
  private let box = CategoryModelBox()

  override func setUp() async throws {
    stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    references = ReferenceRepository(writer: stack.writer)
    transactions = TransactionRepository(writer: stack.writer)
  }

  private var today: DateOnly { DateOnly(year: 2026, month: 9, day: 18) }

  /// Ten categories, each the one home of its own word, six times over: sixty examples and six
  /// a class — past the fifty and five the model needs before it says anything.
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
              day: today, weekday: CalendarContext.utc.weekdayIndex(today), kind: .expense,
              text: word, amountWhole: 250),
            partId: UUID(), categoryId: category.id))
      }
    }
    box.hold(CategoryModel.train(on: examples, anchor: today), trainedOn: examples)
    return filed
  }

  private func makeModel() -> EntryDraftModel {
    let model = EntryDraftModel(
      references: references, transactions: transactions, calendar: .utc)
    model.predictor = box
    model.reload()
    return model
  }

  private func line(_ text: String) -> ParsedInput {
    InputLineParser(vocabulary: .empty, calendar: .utc).parse(text, today: today)
  }

  /// Whether the next training learns from this part: the rule `CategoryTraining` applies.
  private func isEvidence(_ source: CategorySource) -> Bool {
    let row = CategoryTraining.Row(
      partId: UUID(), categoryId: UUID(), systemRole: nil, categorySource: source,
      externalId: nil, isDeleted: false,
      query: CategoryQuery(
        day: today, weekday: 1, kind: .expense, text: "coffee", amountWhole: 250))
    return !CategoryTraining.examples(from: [row]).isEmpty
  }

  // MARK: A chip the owner pressed (model-insights~12)

  /// A model chip pressed by hand is the owner's choice: stored `.manual` — evidence, like any
  /// choice of the owner's — and not `.history`, which would say that history had filed it.
  /// That it was the model's suggestion, and how sure the model was, is the business of
  /// `category_feedback` («мой выбор пишется в `category_feedback`»).
  func testAPressedModelChipIsTheOwnersChoiceAndNotHistory() throws {
    let filed = try trainTheModel()
    let coffee = try XCTUnwrap(filed["coffee"])
    let model = makeModel()
    model.apply(line("coffee 250"), amount: AmountE4(whole: 250), today: today)
    XCTAssertEqual(model.suggestionSources[coffee.id], .model)

    model.applySuggestion(coffee)

    XCTAssertEqual(model.draft.parts[0].categoryId, coffee.id)
    XCTAssertEqual(model.draft.parts[0].categorySource, .manual)
    XCTAssertTrue(isEvidence(model.draft.parts[0].categorySource))
  }

  /// A chip history offered stays history's when pressed, as before.
  func testAPressedHistoryChipStaysHistorys() throws {
    let filed = try trainTheModel()
    let coffee = try XCTUnwrap(filed["coffee"])
    var past = TransactionDraft(amount: AmountE4(whole: 250), note: "coffee")
    past.parts = [PartDraft(categoryId: coffee.id, amount: AmountE4(whole: 250))]
    try transactions.save(try past.materialize())

    let model = makeModel()
    model.apply(line("coffee 250"), amount: AmountE4(whole: 250), today: today)
    XCTAssertEqual(model.suggestionSources[coffee.id], .history)

    model.applySuggestion(coffee)

    XCTAssertEqual(model.draft.parts[0].categorySource, .history)
  }

  // MARK: What the model filled in by itself (model-insights~11)

  /// The model fills a category in only where history has nothing to say. Once that operation
  /// is saved, the next one at the same place is filed by history — level one — and history's
  /// category is evidence: a habit the model found does not stay the model's guess for ever.
  func testWhatTheModelFilledInComesBackAsHistoryAtThatPlace() throws {
    let filed = try trainTheModel()
    let coffee = try XCTUnwrap(filed["coffee"])
    let corner = Place(name: "Corner")
    try references.save(corner)

    let first = makeModel()
    first.apply(line("coffee 250"), amount: AmountE4(whole: 250), today: today)
    first.draft.placeId = corner.id
    first.applyDefaults(today: today)
    XCTAssertEqual(first.draft.parts[0].categoryId, coffee.id)
    XCTAssertEqual(first.draft.parts[0].categorySource, .model)
    XCTAssertFalse(isEvidence(.model))
    try transactions.save(try first.draft.materialize())

    let next = makeModel()
    next.apply(line("300"), amount: AmountE4(whole: 300), today: today)
    next.draft.placeId = corner.id
    next.applyDefaults(today: today)

    XCTAssertEqual(next.draft.parts[0].categoryId, coffee.id)
    XCTAssertEqual(next.draft.parts[0].categorySource, .history)
    XCTAssertTrue(isEvidence(.history))
  }

}
