import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// A place in the archive stays in analytics but leaves entry: it is not read in the line
/// nor offered in the menu of a new operation, history never brings it, and an operation already
/// at it shows it — «(архив)» — and keeps it when saved.
@MainActor
final class EntryArchivedPlaceTests: XCTestCase {
  private var stack: DatabaseStack!
  private var references: ReferenceRepository!
  private var transactions: TransactionRepository!
  private let live = Place(name: "Пятёрочка")
  private let archived = Place(name: "Кофемания", archived: true)
  private let cafe = CoreKit.Category(kind: .expense, name: "Кафе", quality: .neutral)
  private var today: DateOnly { DateOnly(year: 2026, month: 9, day: 18) }

  override func setUp() async throws {
    stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    references = ReferenceRepository(writer: stack.writer)
    transactions = TransactionRepository(writer: stack.writer)
    try references.save(PaymentMethod(name: "Card", isDefault: true))
    try references.save(live)
    try references.save(archived)
    try references.save(cafe)
  }

  private func makeModel(editing: Bool = false) -> EntryDraftModel {
    let model = EntryDraftModel(
      references: references, transactions: transactions, calendar: .utc,
      editsSavedOperation: editing)
    model.reload()
    return model
  }

  @discardableResult
  private func purchase(at place: Place, note: String) throws -> TransactionEntry {
    var draft = TransactionDraft(
      occurredAt: CalendarContext.utc.startOfDay(today).addingTimeInterval(-86_400),
      amount: AmountE4(whole: 450), note: note, placeId: place.id)
    draft.normalizeSinglePart()
    draft.parts[0].categoryId = cafe.id
    return try transactions.save(try draft.materialize())
  }

  func testANewOperationIsNotOfferedAnArchivedPlace() {
    let model = makeModel()
    XCTAssertEqual(model.placeChoices.map(\.id), [live.id])
  }

  func testAnOperationAtAnArchivedPlaceShowsAndKeepsIt() throws {
    let saved = try purchase(at: archived, note: "кофе")
    let model = makeModel(editing: true)
    model.draft = TransactionDraft(entry: saved)
    XCTAssertEqual(
      model.placeChoices,
      [
        .init(id: live.id, name: live.name, archived: false),
        .init(id: archived.id, name: archived.name, archived: true),
      ])
    model.draft.note = "кофе с собой"
    XCTAssertEqual(model.draftForSaving.placeId, archived.id)
  }

  func testHistoryNeverBringsAPlace() throws {
    try purchase(at: archived, note: "кофе")
    let model = makeModel()
    let parsed = InputLineParser(vocabulary: .empty, calendar: .utc).parse("кофе 300", today: today)
    model.apply(parsed, amount: AmountE4(whole: 300), today: today)
    XCTAssertEqual(model.draft.parts[0].categoryId, cafe.id, "history still files it")
    XCTAssertNil(model.draft.placeId)
    XCTAssertEqual(model.placeChoices.map(\.id), [live.id])
  }

  func testTheLineDoesNotReadAnArchivedPlace() throws {
    let vocabulary = try references.vocabulary(enabledCurrencies: [.rub])
    let parser = InputLineParser(vocabulary: vocabulary, calendar: .utc)
    let parsed = parser.parse("кофе 300 в Кофемании", today: today)
    XCTAssertNil(parsed.placeId)
    XCTAssertEqual(parsed.unknownPlaceName, "Кофемании")
    XCTAssertEqual(parser.parse("хлеб 60 в Пятёрочке", today: today).placeId, live.id)
  }
}
