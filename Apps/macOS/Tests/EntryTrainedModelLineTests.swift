import AppCore
import AppDatabase
import AppKit
import XCTest

@testable import OhMyMoney

/// The line over a book like the demo's: a category model trained on a lopsided history, most of
/// it groceries. Words the model never saw — «абв 250» — fill nothing in, and Enter opens the
/// panel on the category and writes nothing until one is chosen; a word the book knows —
/// «кофе 300 вчера» — is filed where the book filed it, yesterday, without a question.
@MainActor
final class EntryTrainedModelLineTests: XCTestCase {
  private var host: EntryHost?
  private let today = DateOnly(year: 2026, month: 10, day: 7)

  override func tearDown() async throws {
    host?.close()
    host = nil
  }

  /// Ninety examples of groceries and ten of a taxi and of coffee each: past the fifty and five a
  /// class the model needs before it fills anything in, and lopsided, so the prior alone would
  /// put any line into groceries.
  private static func train(
    _ box: CategoryModelBox, groceries: CoreKit.Category, taxi: CoreKit.Category,
    coffee: CoreKit.Category, today: DateOnly
  ) {
    func example(_ text: String, _ category: CoreKit.Category, _ daysAgo: Int) -> CategoryExample {
      let day = CalendarContext.utc.adding(days: -daysAgo, to: today)
      return CategoryExample(
        query: CategoryQuery(
          day: day, weekday: CalendarContext.utc.weekdayIndex(day), kind: .expense, text: text,
          amountWhole: 250),
        partId: UUID(), categoryId: category.id)
    }
    var examples = (0..<90).map { example("продукты в магазине", groceries, $0 % 20) }
    examples += (0..<10).map { example("такси домой", taxi, $0) }
    examples += (0..<10).map { example("кофе", coffee, $0) }
    box.hold(CategoryModel.train(on: examples, anchor: today), trainedOn: examples)
  }

  private func categories() -> (CoreKit.Category, CoreKit.Category, CoreKit.Category) {
    (
      CoreKit.Category(kind: .expense, name: "Groceries", quality: .neutral),
      CoreKit.Category(kind: .expense, name: "Taxi", quality: .neutral),
      CoreKit.Category(kind: .expense, name: "Coffee", quality: .neutral)
    )
  }

  // MARK: The draft

  func testUnknownWordsAskForTheCategoryAndKnownOnesAreFiled() throws {
    let stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    let references = ReferenceRepository(writer: stack.writer)
    let (groceries, taxi, coffee) = categories()
    for category in [groceries, taxi, coffee] { try references.save(category) }
    try references.save(PaymentMethod(name: "Card", isDefault: true))
    let box = CategoryModelBox()
    Self.train(box, groceries: groceries, taxi: taxi, coffee: coffee, today: today)

    func model(for line: String) throws -> EntryDraftModel {
      let model = EntryDraftModel(
        references: references, transactions: TransactionRepository(writer: stack.writer),
        calendar: .utc)
      model.predictor = box
      model.reload()
      let parsed = InputLineParser(vocabulary: .empty, calendar: .utc).parse(line, today: today)
      model.apply(
        parsed, amount: try AmountE4(decimal: try XCTUnwrap(parsed.amount)), today: today)
      return model
    }

    let unknown = try model(for: "абв 250")
    XCTAssertNil(unknown.draft.parts[0].categoryId, "the prior alone fills nothing in")
    XCTAssertEqual(unknown.gapToAsk(), .category)

    let known = try model(for: "кофе 300 вчера")
    XCTAssertEqual(known.draft.parts[0].categoryId, coffee.id)
    XCTAssertNil(known.gapToAsk(), "a known word is not asked about")
  }

  // MARK: In the window

  /// The model the line asks is the one the app holds (`AppEnvironment.categoryModel`).
  private func openLine() async throws -> (EntryHost, CoreKit.Category) {
    let (groceries, taxi, coffee) = categories()
    let host = try await EntryHost(opensDetails: false) { environment in
      for category in [groceries, taxi, coffee] { try environment.references!.save(category) }
      Self.train(
        environment.categoryModel, groceries: groceries, taxi: taxi, coffee: coffee,
        today: environment.today)
    }
    self.host = host
    return (host, coffee)
  }

  func testAbvOpensThePanelOnTheCategoryAndWritesNothing() async throws {
    let (host, _) = try await openLine()
    let editor = try host.type("абв 250", into: try host.line())
    editor.insertNewline(nil)
    XCTAssertTrue(host.settle(until: { host.panelIsOpen }), "the panel is open")
    XCTAssertEqual(try host.transactions.count(), 0, "nothing written at Enter")
    try XCTUnwrap(host.window.firstResponder as? NSTextView).insertNewline(nil)
    host.settle()
    XCTAssertEqual(try host.transactions.count(), 0, "nor at the next Return")

    // ↓ chooses a category, and Return writes it there.
    host.settle(0.3)
    try host.pressDown()
    try XCTUnwrap(host.window.firstResponder as? NSTextView).insertNewline(nil)
    host.settle()
    let saved = try XCTUnwrap(try host.transactions.recentEntries(limit: 5).first)
    XCTAssertNotNil(saved.parts.first?.categoryId)
    XCTAssertEqual(saved.transaction.note, "абв")
  }

  func testAKnownWordIsFiledByTheModelWithoutAQuestion() async throws {
    let (host, coffee) = try await openLine()
    let editor = try host.type("кофе 300 вчера", into: try host.line())
    editor.insertNewline(nil)
    host.settle()
    let saved = try XCTUnwrap(
      try host.transactions.recentEntries(limit: 5).first, "written at once")
    XCTAssertEqual(saved.parts.first?.categoryId, coffee.id)
    XCTAssertEqual(saved.transaction.amountE4, AmountE4(whole: 300))
    let environment = host.environment
    XCTAssertEqual(
      environment.calendar.day(of: saved.transaction.occurredAt),
      environment.calendar.adding(days: -1, to: environment.today), "yesterday")
  }
}
