import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// The ↓ panel and the line keep to the fields of the kind: income has no place, event,
/// «на кого», person, «за другого» or credit — the words that named them go to the note —
/// money back keeps the person it came from, a refund keeps everything a purchase has.
@MainActor
final class EntryKindFieldsTests: XCTestCase {
  private var stack: DatabaseStack!
  private var references: ReferenceRepository!
  private var transactions: TransactionRepository!
  private let anya = Person(name: "Аня")
  private let shop = Place(name: "Пятёрочка")
  private let trip = Event(
    name: "Отпуск", startDate: DateOnly(year: 2026, month: 9, day: 1),
    endDate: DateOnly(year: 2026, month: 9, day: 30))
  private let card = PaymentMethod(name: "Карта", isDefault: true)

  override func setUp() async throws {
    stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    references = ReferenceRepository(writer: stack.writer)
    transactions = TransactionRepository(writer: stack.writer)
    try references.save(anya)
    try references.save(shop)
    try references.save(trip)
    try references.save(card)
  }

  private var today: DateOnly { DateOnly(year: 2026, month: 9, day: 18) }

  private func makeModel() -> EntryDraftModel {
    let model = EntryDraftModel(
      references: references, transactions: transactions, calendar: .utc)
    model.reload()
    return model
  }

  private var vocabulary: ParserVocabulary {
    ParserVocabulary(
      people: [.init(id: anya.id, name: anya.name)],
      places: [.init(id: shop.id, name: shop.name)],
      paymentMethods: [.init(id: card.id, name: card.name)],
      events: [.init(id: trip.id, name: trip.name)])
  }

  /// The line as Enter reads it into the model.
  private func enter(_ line: String, into model: EntryDraftModel? = nil) throws -> EntryDraftModel {
    let model = model ?? makeModel()
    let parsed = InputLineParser(vocabulary: vocabulary, calendar: .utc).parse(line, today: today)
    let amount = try XCTUnwrap(parsed.amount)
    model.apply(parsed, amount: try AmountE4(decimal: amount), today: today)
    return model
  }

  func testIncomeForMumKeepsTheWordsInTheNote() throws {
    let model = try enter("+5000 для мамы")
    XCTAssertEqual(model.draft.kind, .income)
    XCTAssertEqual(model.draft.parts[0].forWhom, .me)
    XCTAssertEqual(model.draft.note, "для мамы")
  }

  func testIncomeLeavesOutAPersonAPlaceAndAnEventAndNotesThem() throws {
    let model = try enter("зарплата 90000 в Отпуск для Ани в Пятёрочке")
    XCTAssertEqual(model.draft.kind, .income)
    XCTAssertNil(model.draft.placeId)
    XCTAssertNil(model.draft.parts[0].forPersonId)
    XCTAssertEqual(model.draft.parts[0].forWhom, .me)
    XCTAssertNil(model.draft.parts[0].eventId)
    let note = try XCTUnwrap(model.draft.note)
    for words in ["для Ани", "в Пятёрочке", "в Отпуск"] {
      XCTAssertTrue(note.contains(words), "\(words) is missing from «\(note)»")
    }
    // The account is a field of income: «На счёт».
    XCTAssertEqual(model.draft.paymentMethodId, card.id)
    XCTAssertEqual(model.accountFieldKey, "entry.account.to")
  }

  func testEnterTwiceDoesNotRepeatTheWords() throws {
    let model = try enter("+5000 для мамы")
    _ = try enter("+5000 для мамы", into: model)
    XCTAssertEqual(model.draft.note, "для мамы")
  }

  func testAnUnknownNameOfIncomeIsNotOfferedAsAPerson() throws {
    let model = try enter("+5000 для Пети")
    XCTAssertEqual(model.draft.note, "для Пети")
    XCTAssertNil(model.suggestedPersonName)
    XCTAssertEqual(model.draft.parts[0].forWhom, .me)
  }

  func testAnExpenseKeepsEveryField() throws {
    let model = try enter("кофе 300 для Ани в Пятёрочке")
    XCTAssertEqual(model.draft.kind, .expense)
    XCTAssertEqual(model.draft.placeId, shop.id)
    XCTAssertEqual(model.draft.parts[0].forPersonId, anya.id)
    XCTAssertEqual(model.draft.note, "кофе")
  }

  func testARefundKeepsThePlaceAndThePerson() throws {
    let model = try enter("возврат 300 для Ани в Пятёрочке")
    XCTAssertEqual(model.draft.kind, .refund)
    XCTAssertEqual(model.draft.placeId, shop.id)
    XCTAssertEqual(model.draft.parts[0].forPersonId, anya.id)
  }

  func testMoneyBackKeepsThePersonItCameFrom() throws {
    let model = try enter("возврат денег 1700 от Ани")
    XCTAssertEqual(model.draft.kind, .reimbursement)
    XCTAssertEqual(model.draft.parts[0].forPersonId, anya.id)
    XCTAssertEqual(model.draft.note ?? "", "")
    XCTAssertTrue(model.recordsThroughReimbursementSheet)
    XCTAssertTrue(model.has(.fromPerson))
    XCTAssertFalse(model.has(.place))
    XCTAssertFalse(model.has(.category))
  }

  func testThePanelShowsTheFieldsOfTheKind() {
    let model = makeModel()
    model.draft.kind = .income
    XCTAssertFalse(model.has(.place))
    XCTAssertFalse(model.has(.event))
    XCTAssertFalse(model.has(.forWhom))
    XCTAssertFalse(model.has(.reimbursable))
    XCTAssertFalse(model.has(.credit))
    XCTAssertTrue(model.has(.split))
    XCTAssertTrue(model.has(.account))
    XCTAssertTrue(model.has(.periodMonth))
    model.draft.kind = .expense
    XCTAssertTrue(model.has(.place))
    XCTAssertTrue(model.has(.credit))
    model.draft.kind = .refund
    XCTAssertFalse(model.has(.credit))
    XCTAssertTrue(model.has(.refundOf))
  }

  func testAPlaceChosenBeforeTheKindBecameIncomeIsNotSaved() throws {
    let model = makeModel()
    model.draft.amount = AmountE4(whole: 5000)
    model.draft.normalizeSinglePart()
    model.setPlace(shop.id, today: today)
    model.draft.parts[0].eventId = trip.id
    model.draft.parts[0].forPersonId = anya.id
    model.draft.parts[0].forWhom = .other
    model.draft.kind = .income
    model.applyDefaults(today: today)

    let saved = try model.draftForSaving.materialize()
    XCTAssertNil(saved.transaction.placeId)
    XCTAssertNil(saved.parts[0].eventId)
    XCTAssertNil(saved.parts[0].forPersonId)
    XCTAssertEqual(saved.parts[0].forWhom, .me)
    // The panel still holds them: back to an expense, nothing is lost.
    model.draft.kind = .expense
    XCTAssertEqual(model.draftForSaving.placeId, shop.id)
  }

  func testSplitIncomeRowsKeepOnlyAmountAndCategory() throws {
    let model = try enter("+5000 зарплата")
    model.addPart()
    model.draft.parts[1].eventId = trip.id
    model.draft.parts[1].reimbursable = true
    let saved = model.draftForSaving
    XCTAssertEqual(saved.parts.count, 2)
    XCTAssertNil(saved.parts[1].eventId)
    XCTAssertFalse(saved.parts[1].reimbursable)
  }
}
