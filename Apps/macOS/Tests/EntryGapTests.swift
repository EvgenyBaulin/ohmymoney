import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// When the line alone does not tell the category — or the model filed it under a category with
/// subcategories without saying which — Enter does not save the words into the note alone: it
/// opens the ↓ panel on the missing field, marked. A missing category is asked until one is
/// chosen («Не помню» is the way out for «I do not know»); a missing subcategory once per line.
@MainActor
final class EntryGapTests: XCTestCase {
  private var stack: DatabaseStack!
  private var references: ReferenceRepository!
  private var transactions: TransactionRepository!
  private let cafe = CoreKit.Category(kind: .expense, name: "Cafe", quality: .neutral)
  private let transport = CoreKit.Category(kind: .expense, name: "Transport", quality: .neutral)
  private lazy var taxi = CoreKit.Category(parentId: transport.id, kind: .expense, name: "Taxi")
  private lazy var bus = CoreKit.Category(parentId: transport.id, kind: .expense, name: "Bus")
  private var today: DateOnly { DateOnly(year: 2026, month: 9, day: 18) }
  private var host: EntryHost?

  override func setUp() async throws {
    stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    references = ReferenceRepository(writer: stack.writer)
    transactions = TransactionRepository(writer: stack.writer)
    for category in [cafe, transport, taxi, bus] { try references.save(category) }
    try references.save(PaymentMethod(name: "Card", isDefault: true))
  }

  override func tearDown() async throws {
    host?.close()
    host = nil
  }

  private func makeModel(editing: Bool = false) -> EntryDraftModel {
    let model = EntryDraftModel(
      references: references, transactions: transactions, calendar: .utc,
      editsSavedOperation: editing)
    model.reload()
    return model
  }

  private func parse(_ text: String) -> ParsedInput {
    InputLineParser(vocabulary: .empty, calendar: .utc).parse(text, today: today)
  }

  private func enter(_ text: String, into model: EntryDraftModel) throws {
    let parsed = parse(text)
    model.apply(parsed, amount: try AmountE4(decimal: try XCTUnwrap(parsed.amount)), today: today)
  }

  func testALineWithoutACategoryIsAskedUntilOneIsChosen() throws {
    let model = makeModel()
    try enter("coffee 250", into: model)
    XCTAssertEqual(model.gapToAsk(), .category)
    XCTAssertEqual(model.markedGap, .category)
    // Enter on the same line does not go on: the operation is filed under a category, and
    // «Не помню» is there for what the owner does not remember.
    try enter("coffee 250", into: model)
    XCTAssertEqual(model.gapToAsk(), .category)
    XCTAssertEqual(model.markedGap, .category)
    model.setCategory(cafe.id, forPartAt: 0)
    XCTAssertNil(model.gapToAsk())
    XCTAssertNil(model.markedGap)
  }

  /// «Не помню» is a category like another one for the stop: choosing it fills the gap, and the
  /// operation is saved under it.
  func testUnknownFillsTheGap() throws {
    let unknown = CoreKit.Category(
      kind: .expense, name: "Unknown", sort: -1, quality: .neutral, systemRole: .unknown)
    try references.save(unknown)
    let model = makeModel()
    try enter("coffee 250", into: model)
    XCTAssertEqual(model.gapToAsk(), .category)
    model.setCategory(unknown.id, forPartAt: 0)
    XCTAssertNil(model.gapToAsk())
    XCTAssertEqual(model.draft.parts[0].categoryId, unknown.id)
  }

  func testAnotherLineIsAskedAgain() throws {
    let model = makeModel()
    try enter("coffee 250", into: model)
    XCTAssertEqual(model.gapToAsk(), .category)
    try enter("tea 150", into: model)
    XCTAssertEqual(model.gapToAsk(), .category)
  }

  /// The stop is remembered by the text of the line: once a name in it is made known, the same
  /// text parses anew, and it is still the line the stop was for — the arrows go on walking
  /// the menu it asked for, and the category is still the one thing missing.
  func testTheStopIsRememberedByTheTextOfTheLine() throws {
    let text = "coffee 300 at Nowhere"
    let model = makeModel()
    let before = parse(text)
    model.apply(before, amount: AmountE4(whole: 300), today: today, text: text)
    XCTAssertEqual(model.gapToAsk(), .category)

    let nowhere = Place(name: "Nowhere")
    try references.save(nowhere)
    let after = InputLineParser(
      vocabulary: ParserVocabulary(places: [.init(id: nowhere.id, name: "Nowhere", aliases: [])]),
      calendar: .utc
    ).parse(text, today: today)
    XCTAssertNotEqual(after, before, "the place is known now")
    model.apply(after, amount: AmountE4(whole: 300), today: today, text: text)
    XCTAssertEqual(model.draft.placeId, nowhere.id)
    XCTAssertEqual(model.gapToAsk(), .category, "a place does not say the category")
    XCTAssertTrue(model.stepTheAskedMenu(by: 1, today: today), "still the line the stop was for")
    XCTAssertNil(model.gapToAsk())
  }

  /// ↓ and ↑ while the stop stands walk the menu it asked for, «—» first, as choices made in the
  /// menu; with no stop for the line they are not the menu's.
  func testTheArrowsWalkTheAskedMenuWhileTheStopStands() throws {
    let model = makeModel()
    try enter("coffee 250", into: model)
    XCTAssertFalse(model.stepTheAskedMenu(by: 1, today: today), "no stop yet")
    XCTAssertEqual(model.gapToAsk(), .category)
    let options = model.categoryOptions(forPartAt: 0).map(\.id)
    XCTAssertGreaterThanOrEqual(options.count, 2)

    XCTAssertTrue(model.stepTheAskedMenu(by: 1, today: today))
    XCTAssertEqual(model.draft.parts[0].categoryId, options[0])
    XCTAssertEqual(model.draft.parts[0].categorySource, .manual)
    XCTAssertTrue(model.stepTheAskedMenu(by: 1, today: today))
    XCTAssertEqual(model.draft.parts[0].categoryId, options[1])
    XCTAssertTrue(model.stepTheAskedMenu(by: -2, today: today))
    XCTAssertNil(model.draft.parts[0].categoryId, "«—» is the first choice")
    XCTAssertTrue(model.stepTheAskedMenu(by: -1, today: today), "nothing above «—»")
    XCTAssertNil(model.draft.parts[0].categoryId)

    try enter("tea 150", into: model)
    XCTAssertFalse(model.stepTheAskedMenu(by: 1, today: today), "no stop for this line")
  }

  /// The categories of the app stand at the end of the walk, whatever place the dictionary
  /// gave them: the owner's own categories are what the arrows reach first.
  func testTheArrowsReachTheCategoriesOfTheAppLast() throws {
    let unknown = CoreKit.Category(
      kind: .expense, name: "Unknown", sort: -3, quality: .neutral, systemRole: .unknown)
    let goals = CoreKit.Category(
      kind: .expense, name: "Goals", sort: -2, quality: .good, systemRole: .goals)
    let loans = CoreKit.Category(
      kind: .expense, name: "Loans", sort: -1, quality: .neutral, systemRole: .loans)
    for category in [unknown, goals, loans] { try references.save(category) }
    let model = makeModel()
    try enter("coffee 250", into: model)
    XCTAssertEqual(model.gapToAsk(), .category)
    let own = model.categoryOptions(forPartAt: 0).filter {
      $0.systemRole == nil
    }.map(\.id)
    XCTAssertEqual(own.count, 2, "cafe and transport")

    var walked: [UUID?] = []
    for _ in 0..<(own.count + 3) {
      XCTAssertTrue(model.stepTheAskedMenu(by: 1, today: today))
      walked.append(model.draft.parts[0].categoryId)
    }
    XCTAssertEqual(walked, own + [goals.id, loans.id, unknown.id])
    XCTAssertTrue(model.stepTheAskedMenu(by: 1, today: today), "nothing after the last one")
    XCTAssertEqual(model.draft.parts[0].categoryId, unknown.id)
  }

  func testAChosenCategoryIsNotAsked() throws {
    let model = makeModel()
    try enter("coffee 250", into: model)
    model.setCategory(cafe.id, forPartAt: 0)
    XCTAssertNil(model.gapToAsk())
  }

  func testHistoryDeterminesTheCategory() throws {
    var earlier = TransactionDraft(amount: AmountE4(whole: 200), note: "coffee")
    earlier.normalizeSinglePart()
    earlier.parts[0].categoryId = cafe.id
    try transactions.save(try earlier.materialize())
    let model = makeModel()
    try enter("coffee 250", into: model)
    XCTAssertEqual(model.draft.parts[0].categoryId, cafe.id)
    XCTAssertNil(model.gapToAsk())
  }

  /// The model is sure of «Transport», which has «Taxi» and «Bus»: the subcategory is asked, and
  /// Return without choosing saves the operation in «Transport».
  func testASubcategoryTheModelLeftOpenIsAsked() throws {
    var examples: [CategoryExample] = []
    for (index, word) in ["ride", "pizza", "bread", "cinema", "books", "gym"].enumerated() {
      let category: CoreKit.Category
      if index == 0 {
        category = transport
      } else {
        category = CoreKit.Category(kind: .expense, name: "Model \(word)")
        try references.save(category)
      }
      for _ in 0..<10 {
        examples.append(
          CategoryExample(
            query: CategoryQuery(
              day: today, weekday: CalendarContext.utc.weekdayIndex(today), kind: .expense,
              text: word, amountWhole: 250),
            partId: UUID(), categoryId: category.id))
      }
    }
    let box = CategoryModelBox()
    box.hold(CategoryModel.train(on: examples, anchor: today), trainedOn: examples)
    let model = makeModel()
    model.predictor = box
    try enter("ride 400", into: model)
    XCTAssertEqual(model.draft.parts[0].categoryId, transport.id)
    XCTAssertEqual(model.draft.parts[0].categorySource, .model)
    XCTAssertEqual(model.gapToAsk(), .subcategory)
    XCTAssertEqual(model.markedGap, .subcategory)
    XCTAssertNil(model.gapToAsk(), "Return again saves it in «Transport»")
  }

  func testTheMarkGoesOnceTheGapIsFilled() throws {
    let model = makeModel()
    try enter("coffee 250", into: model)
    XCTAssertEqual(model.gapToAsk(), .category)
    model.setCategory(cafe.id, forPartAt: 0)
    XCTAssertNil(model.markedGap)
  }

  func testASavedOperationIsNeverAsked() throws {
    var saved = TransactionDraft(amount: AmountE4(whole: 250), note: "coffee")
    saved.normalizeSinglePart()
    let entry = try saved.materialize()
    try transactions.save(entry)
    let model = makeModel(editing: true)
    model.draft = TransactionDraft(entry: entry)
    XCTAssertNil(model.gapToAsk())
  }

  /// Money back the confirmation recorded as income is not stopped for a category: the owner
  /// has just confirmed a form. The money-back line itself has no category to ask for.
  func testMoneyBackRecordedAsIncomeIsNotStoppedForACategory() throws {
    let model = makeModel()
    try enter("возврат денег 500", into: model)
    XCTAssertEqual(model.draft.kind, .reimbursement)
    XCTAssertNil(model.gapToAsk(), "money back has no category to ask for")
    var sheet = model.draftForSaving
    sheet.amount = AmountE4(whole: 500)
    model.recordMoneyBackInstead(.income, from: sheet, fromNote: { $0 }, today: today)
    XCTAssertEqual(model.draft.kind, .income)
    XCTAssertNil(model.draft.parts.first?.categoryId)
    XCTAssertNil(model.gapToAsk(), "the income the confirmation made is saved as it is")
  }

  /// Return in the line, with the focus put back there first: what the next Enter does.
  private func returnInTheLine(of host: EntryHost) throws {
    host.settle(0.3)
    XCTAssertTrue(host.window.makeFirstResponder(try host.line()))
    try XCTUnwrap(host.window.firstResponder as? NSTextView).insertNewline(nil)
    host.settle()
  }

  /// In the window: Enter on a line of new words saves nothing, opens the panel and says why;
  /// the next Return saves nothing either — an operation is filed under a category, or under
  /// «Не помню» — until one is chosen, and then Return saves it, its words in the note.
  func testEnterOpensThePanelOnTheCategoryAndTheNextReturnWaitsForOne() async throws {
    let host = try await EntryHost(opensDetails: false)
    self.host = host
    let first = try XCTUnwrap(
      try host.references.categories().first {
        $0.parentId == nil && $0.kind == .expense && $0.systemRole == nil
      }, "the first category of the menu")
    let editor = try host.type("coffee 250", into: try host.line())
    editor.insertNewline(nil)
    XCTAssertTrue(host.settle(until: { host.panelIsOpen }), "the panel is open")
    XCTAssertEqual(try host.transactions.count(), 0, "nothing saved at the first Enter")

    try returnInTheLine(of: host)
    XCTAssertEqual(try host.transactions.count(), 0, "the second Return waits for a category")
    XCTAssertNotNil(
      host.textFields().first { $0.placeholderString == "0" }, "the panel stays open")

    try host.pressDown()
    try returnInTheLine(of: host)
    let saved = try XCTUnwrap(try host.transactions.recentEntries(limit: 5).first)
    XCTAssertEqual(saved.parts.first?.categoryId, first.id)
    XCTAssertEqual(saved.transaction.note, "coffee")
  }

  /// The stop opened the panel on the category; the owner chooses it, corrects the amount there
  /// too, and Return in the field saves the amount the panel shows, not the one the line still
  /// says.
  func testAnAmountCorrectedInThePanelAfterTheStopIsSaved() async throws {
    let host = try await EntryHost(opensDetails: false)
    self.host = host
    let editor = try host.type("coffee 250", into: try host.line())
    editor.insertNewline(nil)
    host.settle()
    XCTAssertEqual(try host.transactions.count(), 0, "the first Enter stops for the category")

    host.settle(0.3)
    try host.pressDown()
    // The field selects what it holds as it takes the focus: typing replaces «250».
    let amount = try host.type("260", into: try host.field(prompt: "0"))
    amount.insertNewline(nil)
    host.settle()
    let saved = try host.transactions.recentEntries(limit: 5)
    XCTAssertEqual(saved.count, 1, "Return in the panel saves")
    XCTAssertEqual(saved.first?.transaction.amountE4, AmountE4(whole: 260))
    XCTAssertEqual(saved.first?.transaction.note, "coffee")
  }

  /// Where macOS keeps Tab away from menus, the focus stays in the line after the stop: ↓ there
  /// chooses the first category of the menu, and Return saves the operation in it.
  func testTheCategoryCanBeChosenFromTheKeyboardAfterTheStop() async throws {
    let host = try await EntryHost(opensDetails: false)
    self.host = host
    let first = try XCTUnwrap(
      try host.references.categories().first {
        $0.parentId == nil && $0.kind == .expense && $0.systemRole == nil
      }, "the first category of the menu")
    let editor = try host.type("coffee 250", into: try host.line())
    editor.insertNewline(nil)
    host.settle()
    XCTAssertEqual(try host.transactions.count(), 0, "the first Enter stops for the category")

    host.settle(0.3)
    try host.pressDown()
    XCTAssertTrue(
      ((host.window.firstResponder as? NSTextView)?.delegate as? NSTextField)
        === (try host.line()), "the focus stays in the line")
    try XCTUnwrap(host.window.firstResponder as? NSTextView).insertNewline(nil)
    host.settle()
    let saved = try XCTUnwrap(try host.transactions.recentEntries(limit: 5).first)
    XCTAssertEqual(saved.parts.first?.categoryId, first.id, "saved in «\(first.name)»")
  }

  /// A place the line names that nobody has made yet is made with «Добавить…» after the stop:
  /// the same line now reads with the place, and is still the line the stop was for — the
  /// category is still what is missing, and once it is chosen Return saves the place with it.
  func testAddingThePlaceOfTheLineKeepsTheStopForTheCategory() async throws {
    let host = try await EntryHost(opensDetails: false)
    self.host = host
    let editor = try host.type("coffee 300 at Nowhere", into: try host.line())
    editor.insertNewline(nil)
    host.settle()
    XCTAssertEqual(try host.transactions.count(), 0, "the first Enter stops for the category")

    // What «Добавить…» of the menu of places does: the place is written, the line learns it.
    let nowhere = Place(name: "Nowhere")
    try host.references.save(nowhere)
    host.environment.refreshVocabulary()
    try returnInTheLine(of: host)
    XCTAssertEqual(try host.transactions.count(), 0, "a place does not say the category")

    try host.pressDown()
    try returnInTheLine(of: host)
    let saved = try host.transactions.recentEntries(limit: 5)
    XCTAssertEqual(saved.count, 1, "the Return after the choice saves")
    XCTAssertEqual(saved.first?.transaction.placeId, nowhere.id)
  }
}
