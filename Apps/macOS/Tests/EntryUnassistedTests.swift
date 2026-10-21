import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// The form at the side of the window takes nothing from history and the model but the category
/// a chosen place brings: the people and the account are what the owner chooses, and the words
/// file nothing. The line, which does, is the control.
@MainActor
final class EntryUnassistedTests: XCTestCase {
  private var stack: DatabaseStack!
  private var references: ReferenceRepository!
  private var transactions: TransactionRepository!
  private let cafe = CoreKit.Category(kind: .expense, name: "Cafe", quality: .neutral)
  private let main = PaymentMethod(name: "Main", isDefault: true)
  private let other = PaymentMethod(name: "Other")
  private let place = Place(name: "Corner")
  private var today: DateOnly { DateOnly(year: 2026, month: 9, day: 18) }

  override func setUp() async throws {
    stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    references = ReferenceRepository(writer: stack.writer)
    transactions = TransactionRepository(writer: stack.writer)
    for record in [main, other] { try references.save(record) }
    try references.save(cafe)
    try references.save(place)
    // Two weeks ago, the same words at the same place: a category, an account, «на кого».
    var earlier = TransactionDraft(
      amount: AmountE4(whole: 100), note: "coffee", placeId: place.id,
      paymentMethodId: other.id)
    earlier.normalizeSinglePart()
    earlier.parts[0].categoryId = cafe.id
    earlier.parts[0].forWhom = .friends
    try transactions.save(try earlier.materialize())
  }

  private func makeModel(assisted: Bool, atThePlace: Bool = true) -> EntryDraftModel {
    let model = EntryDraftModel(
      references: references, transactions: transactions, calendar: .utc)
    model.assisted = assisted
    model.reload()
    model.setTotal(AmountE4(whole: 250))
    model.draft.note = "coffee"
    if atThePlace { model.setPlace(place.id, today: today) }
    model.applyDefaults(today: today)
    return model
  }

  /// The control: the line files the money by what history knows.
  func testTheAssistedModelFollowsHistory() {
    let model = makeModel(assisted: true)
    XCTAssertEqual(model.draft.parts[0].categoryId, cafe.id)
    XCTAssertEqual(model.draft.paymentMethodId, other.id, "the account of the place")
    XCTAssertEqual(model.draft.parts[0].forWhom, .friends, "«на кого» of the last time")
  }

  func testTheFormFilesNothingByHistory() {
    let model = makeModel(assisted: false, atThePlace: false)
    XCTAssertNil(model.draft.parts[0].categoryId, "no category from the same words")
    XCTAssertTrue(model.categorySuggestions.isEmpty, "no chips")
    XCTAssertEqual(model.draft.parts[0].forWhom, .me, "«на кого» is the default one")
  }

  /// The one thing the form takes from history: a place chosen brings the category of the last
  /// operation there — and nothing else, not «на кого», not the account.
  func testAPlaceChosenInTheFormBringsItsCategoryAlone() {
    let model = makeModel(assisted: false)
    XCTAssertEqual(model.draft.parts[0].categoryId, cafe.id, "the category of the place")
    XCTAssertTrue(model.categorySuggestions.isEmpty, "no chips")
    XCTAssertEqual(model.draft.parts[0].forWhom, .me, "«на кого» is the default one")
    XCTAssertEqual(model.draft.paymentMethodId, main.id, "the main account")
  }

  /// The account is the main one, as it is for a place never seen before.
  func testTheFormTakesTheMainAccountWhateverThePlaceHistorySays() {
    let model = makeModel(assisted: false)
    XCTAssertEqual(model.draft.paymentMethodId, main.id)
  }

  /// What the owner chooses is kept: the form leaves the pickers to them.
  func testWhatTheOwnerChoosesInTheFormStays() {
    let model = makeModel(assisted: false)
    model.setCategory(cafe.id, forPartAt: 0)
    model.setPaymentMethod(other.id)
    model.applyDefaults(today: today)
    XCTAssertEqual(model.draft.parts[0].categoryId, cafe.id)
    XCTAssertEqual(model.draft.paymentMethodId, other.id)
  }
}
