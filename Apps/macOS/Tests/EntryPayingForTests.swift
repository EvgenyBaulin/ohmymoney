import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// «За кого» in the ↓ panel and the line: each way gives the right money in my spending, in
/// «Мне должны» and in the analytics of others; ⌘Z takes the expense and what is owed together.
@MainActor
final class EntryPayingForTests: XCTestCase {
  private var stack: DatabaseStack!
  private var references: ReferenceRepository!
  private var transactions: TransactionRepository!
  private var store: TransactionsStore!
  private let cafe = CoreKit.Category(kind: .expense, name: "Кафе", quality: .neutral)
  private let masha = Person(name: "Маша")
  private let petya = Person(name: "Петя")
  private let today = DateOnly(year: 2026, month: 10, day: 7)

  override func setUp() async throws {
    stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    references = ReferenceRepository(writer: stack.writer)
    transactions = TransactionRepository(writer: stack.writer)
    try references.save(cafe)
    try references.save(masha)
    try references.save(petya)
    try references.save(PaymentMethod(name: "Карта", isDefault: true))
    store = TransactionsStore()
    store.attach(
      transactions, references: references, planning: PlanningRepository(writer: stack.writer))
  }

  /// «Вернёт ли человек деньги?» is asked whenever somebody else is chosen, and what was
  /// answered for that person is offered next time (owner, 18.10): Маша returns, Петя is a gift.
  func testTheAnswerAboutAPersonIsOfferedAgain() throws {
    let suite = "ohmymoney.test.paysback.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let memory = PaysBackMemory(defaults: defaults)
    XCTAssertNil(memory.answer(for: masha.id), "nothing answered yet")

    let model = makeModel()
    model.paysBackMemory = memory
    model.draft.amount = AmountE4(whole: 1_000)
    model.choosePayingForWay(.somebody)
    model.setPayingForPerson(masha.id, slot: 0)
    XCTAssertTrue(model.payingForPaysBack, "asked first time: the default is «Вернёт»")
    model.setPaysBack(true)
    model.setPayingForPerson(petya.id, slot: 0)
    model.setPaysBack(false)

    let next = makeModel()
    next.paysBackMemory = memory
    next.draft.amount = AmountE4(whole: 500)
    next.choosePayingForWay(.somebody)
    next.setPayingForPerson(petya.id, slot: 0)
    XCTAssertFalse(next.payingForPaysBack, "Петя was a gift last time")
    next.setPayingForPerson(masha.id, slot: 0)
    XCTAssertTrue(next.payingForPaysBack, "Маша returned last time")
    XCTAssertEqual(memory.answer(for: petya.id), false)
    XCTAssertEqual(memory.answer(for: masha.id), true)
  }

  private func makeModel() -> EntryDraftModel {
    let model = EntryDraftModel(references: references, transactions: transactions, calendar: .utc)
    model.reload()
    return model
  }

  private func enter(_ text: String, into model: EntryDraftModel) throws {
    let vocabulary = ParserVocabulary(
      people: [.init(id: masha.id, name: masha.name), .init(id: petya.id, name: petya.name)])
    let parsed = InputLineParser(vocabulary: vocabulary, calendar: .utc).parse(text, today: today)
    model.apply(parsed, amount: try AmountE4(decimal: try XCTUnwrap(parsed.amount)), today: today)
    model.setCategory(cafe.id, forPartAt: 0)
  }

  private func save(_ model: EntryDraftModel) throws -> TransactionEntry {
    let entry = try model.draftForSaving.materialize()
    XCTAssertTrue(store.save(entry))
    return entry
  }

  private func totals() throws -> RowTotals {
    RowTotals(entries: try transactions.entries(from: .distantPast, to: .distantFuture))
  }

  private func others() throws -> OthersReport {
    let ledger = Ledger(
      dataset: Dataset(entries: try transactions.entries(from: .distantPast, to: .distantFuture)),
      calendar: .utc)
    return OthersReport(ledger: ledger, period: .year(2026))
  }

  func testHalfWithMashaFromTheLine() throws {
    let model = makeModel()
    try enter("ужин 1200 пополам с машей", into: model)
    XCTAssertEqual(model.payingFor, .half(masha.id))
    XCTAssertEqual(model.draft.parts.map(\.amount), [AmountE4(whole: 600), AmountE4(whole: 600)])
    _ = try save(model)
    XCTAssertEqual(try totals().myExpenses, AmountE4(whole: 600))
    XCTAssertEqual(try totals().forOthers, AmountE4(whole: 600))
    XCTAssertEqual(
      try others().byPerson.first { $0.personId == masha.id }?.totals.waiting,
      AmountE4(whole: 600))
  }

  func testForSomebodyWhoPaysBackAndUndoTakesBoth() throws {
    let model = makeModel()
    try enter("билеты 1200 за машу", into: model)
    XCTAssertEqual(model.payingFor, .somebody(masha.id, paysBack: true))
    _ = try save(model)
    XCTAssertEqual(try totals().myExpenses, .zero)
    XCTAssertEqual(
      try others().byPerson.first { $0.personId == masha.id }?.totals.waiting,
      AmountE4(whole: 1200))
    // One ⌘Z: the expense and what Masha owes go together.
    store.undo()
    XCTAssertTrue(try transactions.entries(from: .distantPast, to: .distantFuture).isEmpty)
    XCTAssertTrue(try others().byPerson.isEmpty)
  }

  func testATreatIsMineAndOwesNothing() throws {
    let model = makeModel()
    try enter("кофе 300 угостил машу", into: model)
    XCTAssertEqual(model.payingFor, .somebody(masha.id, paysBack: false))
    _ = try save(model)
    XCTAssertEqual(try totals().myExpenses, AmountE4(whole: 300))
    XCTAssertEqual(try totals().forOthers, .zero)
  }

  func testEvenlyOnThreeInThePanel() throws {
    let model = makeModel()
    try enter("пицца 900", into: model)
    model.choosePayingForWay(.evenly)
    XCTAssertEqual(model.draft.parts.count, 1, "nobody chosen yet: the parts stay mine")
    model.setPayingForPerson(masha.id, slot: 0)
    model.setPayingForPerson(petya.id, slot: 1)
    XCTAssertEqual(model.payingFor, .evenly([masha.id, petya.id]))
    XCTAssertEqual(
      model.draft.parts.map(\.amount), Array(repeating: AmountE4(whole: 300), count: 3))
    _ = try save(model)
    XCTAssertEqual(try totals().myExpenses, AmountE4(whole: 300))
    XCTAssertEqual(try totals().forOthers, AmountE4(whole: 600))
  }

  func testTheSharesFollowTheAmount() throws {
    let model = makeModel()
    try enter("ужин 1200 пополам с машей", into: model)
    model.draft.amount = AmountE4(whole: 1000)
    model.relayPayingFor()
    XCTAssertEqual(model.draft.parts.map(\.amount), [AmountE4(whole: 500), AmountE4(whole: 500)])
  }

  func testTheWaysInThePanel() throws {
    let model = makeModel()
    try enter("ужин 1200", into: model)
    XCTAssertTrue(model.offersPayingFor)
    model.choosePayingForWay(.somebody)
    XCTAssertEqual(model.shownPayingForWay, .somebody)
    XCTAssertFalse(model.draft.parts[0].reimbursable)
    model.setPayingForPerson(masha.id, slot: 0)
    XCTAssertTrue(model.draft.parts[0].reimbursable)
    model.setPaysBack(false)
    XCTAssertFalse(model.draft.parts[0].reimbursable)
    XCTAssertEqual(model.draft.parts[0].forPersonId, masha.id)
    model.choosePayingForWay(.me)
    XCTAssertEqual(model.payingFor, .me)
    XCTAssertNil(model.draft.parts[0].forPersonId)
  }

  /// The form at the side has no line to read again: the category chosen after «Пополам» is
  /// every share's.
  func testTheCategoryChosenAfterHalfIsEveryShares() throws {
    let model = makeModel()
    let parsed = InputLineParser(vocabulary: .empty, calendar: .utc).parse(
      "ужин 1200", today: today)
    model.apply(parsed, amount: AmountE4(whole: 1200), today: today)
    model.choosePayingForWay(.half)
    model.setPayingForPerson(masha.id, slot: 0)
    model.setCategory(cafe.id, forPartAt: 0)
    XCTAssertEqual(model.draft.parts.map(\.categoryId), [cafe.id, cafe.id])
  }

  func testIncomeHasNoPayingFor() throws {
    let model = makeModel()
    let parsed = InputLineParser(vocabulary: .empty, calendar: .utc).parse("+5000", today: today)
    model.apply(parsed, amount: AmountE4(whole: 5000), today: today)
    XCTAssertFalse(model.offersPayingFor)
  }
}
