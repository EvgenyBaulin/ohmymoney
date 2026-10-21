import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// The editor beside the table of «Операции» (and the edit sheet): what names the operation,
/// when it holds unsaved changes, how it follows the operation changed or deleted elsewhere,
/// and saving it — a description, another kind, a rating, a split — each one step of ⌘Z that
/// brings the operation back as it was.
final class OperationsScenarioEditorTests: OperationsScenarioStoreCase {
  private var environment: AppEnvironment!

  override func setUp() async throws {
    try await super.setUp()
    environment = AppEnvironment()
  }

  override func tearDown() async throws {
    environment = nil
    try await super.tearDown()
  }

  private func editor(_ entry: TransactionEntry) -> TransactionEditorModel {
    TransactionEditorModel(
      entry: entry, environment: environment, tree: CategoryTree([food, coffee, salary, fines]))
  }

  private func save(_ editor: TransactionEditorModel) -> Bool {
    editor.save(store: store, environment: environment, balances: .empty, now: at(minute: 59))
  }

  // MARK: What the editor shows

  func testTheEditorIsNamedByTheDescription() throws {
    XCTAssertEqual(editor(try saved("lunch")).title, .note("lunch"))
  }

  func testWithoutADescriptionTheEditorIsNamedByTheCategory() throws {
    var draft = TransactionDraft(occurredAt: at(), amount: AmountE4(whole: 100))
    draft.normalizeSinglePart()
    draft.parts[0].categoryId = coffee.id
    let latte = try draft.materialize()
    guard case .category = editor(latte).title else {
      return XCTFail("named by its category")
    }
  }

  func testAFreshEditorHoldsNoChanges() throws {
    let model = editor(try saved("lunch"))
    XCTAssertFalse(model.hasChanges)
    XCTAssertEqual(model.id, model.entry.id)
    XCTAssertTrue(model.canSave(in: store))
  }

  func testAChangeTypedAndTypedBackIsNoChange() throws {
    let model = editor(try saved("lunch"))
    model.draft.draft.note = "dinner"
    XCTAssertTrue(model.hasChanges)
    model.draft.draft.note = "lunch"
    XCTAssertFalse(model.hasChanges)
  }

  // MARK: Following the data

  func testAnUntouchedEditorFollowsTheOperation() throws {
    let lunch = try saved("lunch")
    let model = editor(lunch)
    XCTAssertEqual(model.follow(lunch), .stay)
    XCTAssertEqual(model.follow(nil), .close)
    var changed = lunch
    changed.transaction.note = "brunch"
    XCTAssertEqual(model.follow(changed), .reopen(changed))
  }

  func testAnEditorWithChangesStaysAndSaysTheOperationIsGone() throws {
    let lunch = try saved("lunch")
    let model = editor(lunch)
    model.draft.draft.note = "dinner"
    XCTAssertEqual(model.follow(nil), .stay)
    XCTAssertEqual(model.errorKey, "entry.error.gone")
    XCTAssertEqual(model.follow(lunch), .stay)
    XCTAssertNil(model.errorKey, "back again with ⌘Z of the deletion")
  }

  func testTheWordsOfAGoneOperationExistInBothLanguages() {
    for language in ["ru", "en"] {
      let bundle = Bundle.main.path(forResource: language, ofType: "lproj")
        .flatMap(Bundle.init(path:))
      let found = ["Entry", "Transactions", "Common"].contains { table in
        bundle?.localizedString(forKey: "entry.error.gone", value: nil, table: table)
          != "entry.error.gone"
      }
      XCTAssertTrue(found, language)
    }
  }

  // MARK: Saving

  func testADescriptionSavedComesBackWithUndo() throws {
    let lunch = try saved("lunch")
    let model = editor(lunch)
    model.draft.draft.note = "business lunch"
    XCTAssertTrue(save(model), model.errorKey ?? "")
    XCTAssertEqual(try stored(lunch.id).transaction.note, "business lunch")
    store.undo()
    XCTAssertEqual(try stored(lunch.id).transaction.note, "lunch")
  }

  func testASpendingTurnedIntoIncomeLosesItsRating() throws {
    let lunch = try saved(
      "refund from work",
      parts: [
        PartDraft(
          categoryId: food.id, quality: .bad, qualitySource: .manual,
          amount: AmountE4(whole: 100))
      ])
    let model = editor(lunch)
    model.draft.draft.kind = .income
    model.draft.draft.parts[0].categoryId = salary.id
    XCTAssertTrue(save(model), model.errorKey ?? "")
    let after = try stored(lunch.id)
    XCTAssertEqual(after.transaction.kind, .income)
    XCTAssertEqual(after.parts[0].categoryId, salary.id)
    store.undo()
    let back = try stored(lunch.id)
    XCTAssertEqual(back.transaction.kind, .expense)
    XCTAssertEqual(back.parts[0].quality, .bad)
  }

  func testASpendingTurnedIntoARefundKeepsItsCategory() throws {
    let lunch = try saved("returned lunch")
    let model = editor(lunch)
    model.draft.draft.kind = .refund
    XCTAssertTrue(save(model), model.errorKey ?? "")
    let after = try stored(lunch.id)
    XCTAssertEqual(after.transaction.kind, .refund)
    XCTAssertEqual(after.parts[0].categoryId, food.id)
  }

  func testARatingChangedInTheEditorIsTheOwners() throws {
    let lunch = try saved("lunch")
    let model = editor(lunch)
    model.draft.draft.parts[0].quality = .bad
    model.draft.draft.parts[0].qualitySource = .manual
    XCTAssertTrue(save(model), model.errorKey ?? "")
    XCTAssertEqual(try part(lunch.id).quality, .bad)
    XCTAssertEqual(try part(lunch.id).qualitySource, .manual)
  }

  func testAnOperationSplitInTheEditorComesBackWhole() throws {
    let lunch = try saved("lunch", whole: 300)
    let model = editor(lunch)
    model.draft.draft.parts[0].amount = AmountE4(whole: 200)
    model.draft.draft.parts.append(
      PartDraft(categoryId: fines.id, amount: AmountE4(whole: 100)))
    XCTAssertTrue(save(model), model.errorKey ?? "")
    XCTAssertEqual(
      try stored(lunch.id).parts.map(\.amountE4),
      [
        AmountE4(whole: 200), AmountE4(whole: 100),
      ])
    store.undo()
    XCTAssertEqual(try stored(lunch.id).parts.map(\.id), lunch.parts.map(\.id))
  }

  func testASplitThatDoesNotAddUpIsNotSaved() throws {
    let lunch = try saved("lunch", whole: 300)
    let model = editor(lunch)
    model.draft.draft.parts.append(PartDraft(categoryId: fines.id, amount: AmountE4(whole: 1)))
    XCTAssertFalse(model.canSave(in: store))
    XCTAssertFalse(save(model))
    XCTAssertEqual(model.errorKey, "entry.error.notBalanced")
    XCTAssertFalse(store.canUndo)
  }

  func testAnOperationMovedToTheNextMonthInTheEditorComesBack() throws {
    let lunch = try saved("lunch", on: DateOnly(year: 2026, month: 8, day: 31))
    let model = editor(lunch)
    model.draft.draft.occurredAt = at(DateOnly(year: 2026, month: 9, day: 1))
    XCTAssertTrue(save(model), model.errorKey ?? "")
    XCTAssertEqual(
      CalendarContext.utc.day(of: try stored(lunch.id).transaction.occurredAt).month, 9)
    store.undo()
    XCTAssertEqual(
      CalendarContext.utc.day(of: try stored(lunch.id).transaction.occurredAt).month, 8)
  }

  func testAnEditorOfAnOperationDeletedMeanwhileSavesNothing() throws {
    let lunch = try saved("lunch")
    let model = editor(lunch)
    model.draft.draft.note = "dinner"
    XCTAssertTrue(store.delete(id: lunch.id))
    XCTAssertFalse(save(model))
    XCTAssertEqual(model.errorKey, "entry.error.gone")
    store.undo()
    XCTAssertTrue(save(model), model.errorKey ?? "")
    XCTAssertEqual(try stored(lunch.id).transaction.note, "dinner")
  }

  // MARK: The fields of a kind

  func testAKindWithoutACardOrCashbackDropsThem() throws {
    var draft = TransactionDraft(
      occurredAt: at(), amount: AmountE4(whole: 100), cardId: card.id,
      cashback: Money(amount: AmountE4(whole: 5), currency: .rub))
    draft.normalizeSinglePart()
    let kept = TransactionEditorModel.cardAndCashbackOfItsKind(draft, fields: [.card, .cashback])
    XCTAssertEqual(kept.cardId, card.id)
    XCTAssertNotNil(kept.cashback)
    let dropped = TransactionEditorModel.cardAndCashbackOfItsKind(draft, fields: [])
    XCTAssertNil(dropped.cardId)
    XCTAssertNil(dropped.cashback)
    let cardOnly = TransactionEditorModel.cardAndCashbackOfItsKind(draft, fields: [.card])
    XCTAssertEqual(cardOnly.cardId, card.id)
    XCTAssertNil(cardOnly.cashback)
  }

  func testEveryRefusalOfAnEditHasItsOwnWords() {
    let keys = EditRefusal.allCases.map(TransactionEditorModel.errorKey(of:))
    XCTAssertEqual(Set(keys).count, keys.count)
  }
}
