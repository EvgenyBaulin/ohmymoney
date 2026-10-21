import CoreKit
import Foundation
import Testing

@testable import CoreAccounting

@Suite("What a list of accounts and cards calls its choices")
struct AccountLabelsTests {
  private let english = Locale(identifier: "en")

  /// A bank with accounts and cards, as the book is made of them.
  private struct Shelf {
    var banks: [Bank] = []
    var accounts: [PaymentMethod] = []
    var cards: [PaymentCard] = []

    @discardableResult
    mutating func bank(_ name: String) -> Bank {
      let bank = Bank(name: name)
      banks.append(bank)
      return bank
    }

    @discardableResult
    mutating func account(
      _ name: String, in bank: Bank?, archived: Bool = false, main: Bool = false
    ) -> PaymentMethod {
      let account = PaymentMethod(
        name: name, isDefault: main, archived: archived, bankId: bank?.id)
      accounts.append(account)
      return account
    }

    @discardableResult
    mutating func card(
      _ name: String, of account: PaymentMethod, archived: Bool = false
    ) -> PaymentCard {
      let card = PaymentCard(accountId: account.id, name: name, archived: archived)
      cards.append(card)
      return card
    }

    func book() -> AccountLabels {
      AccountLabels(accounts: accounts, cards: cards, banks: banks)
    }

    func names(withCards: Bool = true, offering: [PaymentMethod]? = nil) -> [String] {
      book().entries(
        offering: offering ?? accounts.filter { !$0.archived }, withCards: withCards,
        locale: Locale(identifier: "en")
      ).map(\.name)
    }
  }

  // MARK: One account, and its cards

  /// «Если 1 счёт и 1 карта, то при выборе просто показывается банк.»
  @Test func oneAccountAndOneCardShowOnlyTheBank() {
    var shelf = Shelf()
    let sber = shelf.bank("Сбер")
    let account = shelf.account("Сбер", in: sber)
    shelf.card("Сбер", of: account)
    #expect(shelf.names() == ["Сбер"])
  }

  /// The card that is called differently is still one card: the bank says it all.
  @Test func oneAccountAndOneCardOfAnotherNameShowOnlyTheBank() {
    var shelf = Shelf()
    let tbank = shelf.bank("Т-Банк")
    let account = shelf.account("Т-Банк", in: tbank)
    shelf.card("Black", of: account)
    #expect(shelf.names() == ["Т-Банк"])
  }

  @Test func theBankNamesTheAccountEvenWhenTheAccountIsCalledOtherwise() {
    var shelf = Shelf()
    let sber = shelf.bank("Сбер")
    let account = shelf.account("Основной", in: sber)
    shelf.card("Visa", of: account)
    #expect(shelf.names() == ["Сбер"])
  }

  @Test func anAccountWithoutCardsShowsOnlyTheBank() {
    var shelf = Shelf()
    let bank = shelf.bank("Накопительный")
    shelf.account("Накопительный", in: bank)
    #expect(shelf.names() == ["Накопительный"])
  }

  /// «Если 1 счёт но 2 карты, то при выборе показывается банк > карта.»
  @Test func oneAccountAndTwoCardsShowBankAndEachCard() {
    var shelf = Shelf()
    let tbank = shelf.bank("Т-Банк")
    let account = shelf.account("Т-Банк", in: tbank)
    shelf.card("Black", of: account)
    shelf.card("Virtual", of: account)
    #expect(shelf.names() == ["Т-Банк", "Т-Банк › Black", "Т-Банк › Virtual"])
  }

  /// The card called like its account is not shown twice: «Сбер › Сбер» says nothing the bank
  /// does not.
  @Test func aCardCalledLikeItsAccountOrItsBankIsNotShownAgain() {
    var shelf = Shelf()
    let sber = shelf.bank("Сбер")
    let account = shelf.account("Сбер", in: sber)
    shelf.card("Сбер", of: account)
    shelf.card("Сбер Мир", of: account)
    #expect(shelf.names() == ["Сбер", "Сбер › Сбер Мир"])

    var other = Shelf()
    let bank = other.bank("Сбер")
    let main = other.account("Основной", in: bank)
    other.card("сбер", of: main)  // called like the bank
    other.card("Мир", of: main)
    #expect(other.names() == ["Сбер", "Сбер › Мир"])
  }

  @Test func cardsComeInTheOrderOfTheLists() {
    var shelf = Shelf()
    let bank = shelf.bank("Банк")
    let account = shelf.account("Банк", in: bank)
    shelf.card("B", of: account)
    shelf.card("A", of: account)
    var dragged = shelf.card("C", of: account)
    dragged.sort = 1
    shelf.cards[2] = dragged
    #expect(shelf.names() == ["Банк", "Банк › A", "Банк › B", "Банк › C"])
  }

  @Test func anArchivedCardIsNeitherOfferedNorCounted() {
    var shelf = Shelf()
    let bank = shelf.bank("Банк")
    let account = shelf.account("Банк", in: bank)
    shelf.card("Black", of: account)
    shelf.card("Old", of: account, archived: true)
    // One live card: the bank alone.
    #expect(shelf.names() == ["Банк"])
  }

  @Test func aKindThatNamesNoCardOffersTheAccountsAlone() {
    var shelf = Shelf()
    let bank = shelf.bank("Т-Банк")
    let account = shelf.account("Т-Банк", in: bank)
    shelf.card("Black", of: account)
    shelf.card("Virtual", of: account)
    #expect(shelf.names(withCards: false) == ["Т-Банк"])
  }

  // MARK: Several accounts under a bank

  @Test func aBankWithSeveralAccountsNamesEachByItsOwnName() {
    var shelf = Shelf()
    let tbank = shelf.bank("Т-Банк")
    let black = shelf.account("Black", in: tbank)
    let savings = shelf.account("Накопительный", in: tbank)
    shelf.card("Black", of: black)
    #expect(shelf.names() == ["Т-Банк › Black", "Т-Банк › Накопительный"])
    #expect(shelf.book().label(account: savings.id) == "Т-Банк › Накопительный")
  }

  /// The account that carries the name of its bank is the bank itself.
  @Test func theAccountCalledLikeItsBankIsTheBank() {
    var shelf = Shelf()
    let tbank = shelf.bank("Т-Банк")
    shelf.account("Т-Банк", in: tbank)
    shelf.account("Накопительный", in: tbank)
    #expect(shelf.names() == ["Т-Банк", "Т-Банк › Накопительный"])
  }

  @Test func cardsOfAnAccountOfSeveralAreFiledUnderIt() {
    var shelf = Shelf()
    let bank = shelf.bank("Т-Банк")
    let black = shelf.account("Black", in: bank)
    shelf.account("Накопительный", in: bank)
    shelf.card("Debit", of: black)
    shelf.card("Virtual", of: black)
    #expect(
      shelf.names() == [
        "Т-Банк › Black", "Т-Банк › Black › Debit", "Т-Банк › Black › Virtual",
        "Т-Банк › Накопительный",
      ])
  }

  /// An account in the archive does not make its bank look like several accounts.
  @Test func anArchivedAccountDoesNotCountAsAPeer() {
    var shelf = Shelf()
    let bank = shelf.bank("Т-Банк")
    shelf.account("Т-Банк", in: bank)
    shelf.account("Старый", in: bank, archived: true)
    #expect(shelf.names() == ["Т-Банк"])
  }

  // MARK: No bank

  @Test func anAccountWithoutABankIsNamedByItself() {
    var shelf = Shelf()
    let account = shelf.account("Наличные", in: nil)
    shelf.card("A", of: account)
    shelf.card("B", of: account)
    #expect(shelf.names() == ["Наличные", "Наличные › A", "Наличные › B"])
  }

  @Test func anAccountWhoseBankIsGoneIsNamedByItself() {
    var shelf = Shelf()
    shelf.accounts.append(PaymentMethod(name: "Сбер", bankId: UUID()))
    #expect(shelf.names() == ["Сбер"])
  }

  // MARK: The order and the identity of the choices

  @Test func choicesFollowTheOrderOfTheAccountsGiven() {
    var shelf = Shelf()
    let a = shelf.bank("Альфа")
    let s = shelf.bank("Сбер")
    let alfa = shelf.account("Альфа", in: a)
    let sber = shelf.account("Сбер", in: s, main: true)
    let entries = shelf.book().entries(offering: [sber, alfa], withCards: true, locale: english)
    #expect(entries.map(\.name) == ["Сбер", "Альфа"])
    #expect(entries.map(\.id) == [sber.id, alfa.id])
    #expect(entries.allSatisfy { !$0.isCard })
  }

  @Test func aCardChoiceCarriesTheIdOfTheCard() {
    var shelf = Shelf()
    let bank = shelf.bank("Т-Банк")
    let account = shelf.account("Т-Банк", in: bank)
    let black = shelf.card("Black", of: account)
    shelf.card("Virtual", of: account)
    let entries = shelf.book().entries(offering: [account], withCards: true, locale: english)
    #expect(entries.map(\.isCard) == [false, true, true])
    #expect(entries[0].id == account.id)
    #expect(entries[1].id == black.id)
  }

  @Test func onlyTheAccountsOfferedAreListedAndTheirCards() {
    var shelf = Shelf()
    let bank = shelf.bank("Т-Банк")
    let tinkoff = shelf.account("Т-Банк", in: bank)
    shelf.card("A", of: tinkoff)
    shelf.card("B", of: tinkoff)
    let sber = shelf.account("Сбер", in: shelf.bank("Сбер"))
    #expect(shelf.names(offering: [sber]) == ["Сбер"])
  }

  // MARK: What a column shows

  @Test func anOperationShowsItsAccountAsTheListsNameIt() {
    var shelf = Shelf()
    let sber = shelf.bank("Сбер")
    let account = shelf.account("Сбер", in: sber)
    let card = shelf.card("Сбер", of: account)
    let book = shelf.book()
    #expect(book.label(account: account.id, card: nil) == "Сбер")
    #expect(book.label(account: account.id, card: card.id) == "Сбер")
  }

  @Test func anOperationOnACardNamedByTheOwnerShowsTheCard() {
    var shelf = Shelf()
    let bank = shelf.bank("Т-Банк")
    let account = shelf.account("Т-Банк", in: bank)
    let black = shelf.card("Black", of: account)
    shelf.card("Virtual", of: account)
    let book = shelf.book()
    #expect(book.label(account: account.id, card: black.id) == "Т-Банк › Black")
    #expect(book.label(account: account.id, card: nil) == "Т-Банк")
  }

  /// The card of an old operation, archived since, is still told.
  @Test func anArchivedCardIsStillTold() {
    var shelf = Shelf()
    let bank = shelf.bank("Т-Банк")
    let account = shelf.account("Т-Банк", in: bank)
    let old = shelf.card("Old", of: account, archived: true)
    #expect(shelf.book().label(card: old.id) == "Т-Банк › Old")
    #expect(shelf.book().label(account: account.id, card: old.id) == "Т-Банк › Old")
  }

  @Test func anArchivedAccountIsNamedWithItsBankAndItself() {
    var shelf = Shelf()
    let bank = shelf.bank("Т-Банк")
    shelf.account("Т-Банк", in: bank)
    let old = shelf.account("Старый", in: bank, archived: true)
    // As far as the old one is concerned the bank has two accounts: it and the live one.
    #expect(shelf.book().label(account: old.id) == "Т-Банк › Старый")
  }

  @Test func anUnknownAccountHasNoLabel() {
    #expect(Shelf().book().label(account: UUID()) == nil)
    #expect(Shelf().book().label(card: UUID()) == nil)
    #expect(Shelf().book().label(account: UUID(), card: UUID()) == nil)
  }

  @Test func theSeparatorIsOneAngleBracket() {
    #expect(AccountLabels.separator == " › ")
    #expect(CardRules.displayName(account: "T-Bank", card: "Black") == "T-Bank › Black")
  }
}
