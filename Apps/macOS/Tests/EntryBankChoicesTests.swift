import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// The account picker of the ↓ panel in a book filed «bank → account → card»: a bank with one
/// account and one card is named by the bank alone, an account with two cards offers itself and
/// each card under it, a bank with several accounts names each one under it, and a card the list
/// does not offer as a choice of its own is shown as its account.
@MainActor
final class EntryBankChoicesTests: XCTestCase {
  private var book: CardEntryBook!

  override func setUp() async throws {
    book = try await CardEntryBook()
    // The accounts of the book stand under banks of their names, as an open of the app files them.
    _ = try XCTUnwrap(try XCTUnwrap(book.environment.accounts).ensureBanks())
  }

  override func tearDown() async throws {
    await book?.close()
    book = nil
  }

  private let locale = Locale(identifier: "ru_RU")

  private func names(_ model: EntryDraftModel) -> [String] {
    model.accountCardChoices(locale: locale).map(\.name)
  }

  func testABankWithOneAccountAndOneCardIsNamedByTheBankAlone() throws {
    let names = names(book.model())
    XCTAssertEqual(
      Set(names), ["Сбер", "Т-Банк", "Т-Банк › Black", "Т-Банк › Virtual", "Kaspi", "Наличные"])
    XCTAssertEqual(names.count, 6, "every choice once")
    XCTAssertEqual(names.first, "Сбер", "the main account first")
    XCTAssertFalse(names.contains("Сбер · Сбер"))
    XCTAssertFalse(names.contains("Сбер › Сбер"))
    // The cards of the account with two come right after it.
    let at = try XCTUnwrap(names.firstIndex(of: "Т-Банк"))
    XCTAssertEqual(
      Array(names.dropFirst(at + 1).prefix(2)), ["Т-Банк › Black", "Т-Банк › Virtual"])
  }

  func testTheOneCardOfAnAccountIsShownAsTheAccount() throws {
    let model = book.model()
    model.setPaymentMethod(book.sber.id)
    model.draft.cardId = book.sberCard.id
    XCTAssertEqual(
      model.accountOrCardSelection, book.sber.id,
      "the picker has no row for a card that is the only one of its account")
    let offered = model.accountCardChoices(locale: locale)
    XCTAssertTrue(offered.contains { $0.id == model.accountOrCardSelection })
    XCTAssertFalse(offered.contains { $0.archived }, "a live card is never told to be archived")
  }

  func testAPickedCardOfTwoIsShownAsItself() throws {
    let model = book.model()
    model.setAccountOrCard(book.black.id)
    XCTAssertEqual(model.accountOrCardSelection, book.black.id)
    XCTAssertTrue(model.accountCardChoices(locale: locale).contains { $0.id == book.black.id })
  }

  func testABankWithSeveralAccountsNamesEachOneUnderIt() throws {
    let references = try XCTUnwrap(book.environment.references)
    let accounts = try XCTUnwrap(book.environment.accounts).accounts()
    let tBankBank = try XCTUnwrap(accounts.first { $0.id == book.tBank.id }?.bankId)
    try references.save(
      PaymentMethod(name: "Накопительный", kind: .account, currency: .rub, bankId: tBankBank))
    let names = names(book.model())
    XCTAssertEqual(names.count, 7)
    // The account called like its bank is the bank; the other is told under it.
    XCTAssertTrue(names.contains("Т-Банк"))
    XCTAssertTrue(names.contains("Т-Банк › Накопительный"))
    XCTAssertFalse(names.contains("Накопительный"))
    let at = try XCTUnwrap(names.firstIndex(of: "Т-Банк"))
    XCTAssertEqual(
      Array(names.dropFirst(at + 1).prefix(2)), ["Т-Банк › Black", "Т-Банк › Virtual"])
  }

  /// An old operation names a card archived since: it stays under its account, and says so.
  func testAnArchivedCardOfAnOldOperationIsToldToBeArchived() throws {
    var archived = book.virtual
    archived.archived = true
    var other = book.black
    other.archived = true
    _ = try XCTUnwrap(book.environment.planning).apply(
      PlanningChange(upsert: PlanningRows(cards: [archived, other])))
    let model = book.model()
    model.setPaymentMethod(book.tBank.id)
    model.draft.cardId = archived.id
    let offered = model.accountCardChoices(locale: locale)
    let told = try XCTUnwrap(offered.first { $0.id == archived.id })
    XCTAssertTrue(told.archived)
    XCTAssertEqual(told.name, "Т-Банк › Virtual")
    XCTAssertEqual(model.accountOrCardSelection, archived.id)
  }
}
