import CoreKit
import Foundation
import Testing

@testable import CoreAccounting

/// The rules of the cards of an account: the card a new account starts with, the names a card
/// may take, how a picker's choice and a change of account treat a card.
@Suite("Cards of an account")
struct CardRulesTests {
  let tBank = PaymentMethod(id: id(1), name: "T-Bank", kind: .card)
  let sber = PaymentMethod(id: id(2), name: "Sber", kind: .card, aliases: ["sberbank"])
  let cash = PaymentMethod(id: id(3), name: "Cash", kind: .cash)
  let black = PaymentCard(id: id(11), accountId: id(1), name: "Black")
  let virtual = PaymentCard(id: id(12), accountId: id(1), name: "Virtual", aliases: ["virt"])
  let sberCard = PaymentCard(id: id(21), accountId: id(2), name: "Sber")

  var accounts: [PaymentMethod] { [tBank, sber, cash] }
  var cards: [PaymentCard] { [black, virtual, sberCard] }

  @Test func newCardAndAccountKindsGetACardNamedLikeThem() throws {
    let card = try #require(CardRules.startingCard(for: tBank))
    #expect(card.accountId == tBank.id && card.name == "T-Bank" && !card.archived)
    let deposit = PaymentMethod(id: id(4), name: " Deposit ", kind: .account)
    #expect(CardRules.startingCard(for: deposit)?.name == "Deposit")
    #expect(CardRules.startingCard(for: cash) == nil)
    #expect(CardRules.startingCard(for: PaymentMethod(name: "Wallet", kind: .other)) == nil)
    #expect(CardRules.startingCard(for: PaymentMethod(name: "  ", kind: .card)) == nil)
  }

  @Test func cardMayRepeatItsOwnAccountName() {
    let card = PaymentCard(id: id(30), accountId: id(2), name: "sber")
    #expect(CardRules.validate(card, previous: nil, cards: [], accounts: accounts).isEmpty)
    let alias = PaymentCard(id: id(30), accountId: id(2), name: "Visa", aliases: ["Sberbank"])
    #expect(CardRules.validate(alias, previous: nil, cards: [], accounts: accounts).isEmpty)
  }

  @Test func cardNameOfAnotherAccountIsRefused() {
    let card = PaymentCard(id: id(30), accountId: id(1), name: " cash ")
    #expect(
      CardRules.validate(card, previous: nil, cards: cards, accounts: accounts) == [
        .nameTaken(owner: .account(id(3)))
      ])
    let alias = PaymentCard(id: id(30), accountId: id(1), name: "Gold", aliases: ["SBERBANK"])
    #expect(
      CardRules.validate(alias, previous: nil, cards: cards, accounts: accounts) == [
        .otherNameTaken("SBERBANK", owner: .account(id(2)))
      ])
  }

  @Test func cardNameOfAnotherLiveCardIsRefused() {
    let same = PaymentCard(id: id(30), accountId: id(1), name: "black")
    #expect(
      CardRules.validate(same, previous: nil, cards: cards, accounts: accounts) == [
        .nameTaken(owner: .card(id(11)))
      ])
    let elsewhere = PaymentCard(id: id(30), accountId: id(2), name: "VIRT")
    #expect(
      CardRules.validate(elsewhere, previous: nil, cards: cards, accounts: accounts) == [
        .nameTaken(owner: .card(id(12)))
      ])
    // Saving a card over itself is no clash.
    #expect(CardRules.validate(black, previous: black, cards: cards, accounts: accounts).isEmpty)
  }

  @Test func archivedCardNameMayBeReused() {
    var old = black
    old.archived = true
    let card = PaymentCard(id: id(30), accountId: id(1), name: "Black")
    #expect(CardRules.validate(card, previous: nil, cards: [old], accounts: accounts).isEmpty)
    // Bringing the old card back is refused while the new one holds the name.
    var restored = old
    restored.archived = false
    #expect(
      CardRules.validate(restored, previous: old, cards: [old, card], accounts: accounts) == [
        .nameTaken(owner: .card(id(30)))
      ])
  }

  @Test func anEmptyNameAndAnArchivedAccountAreRefused() {
    let empty = PaymentCard(id: id(30), accountId: id(1), name: "  ")
    #expect(CardRules.validate(empty, previous: nil, cards: [], accounts: accounts) == [.emptyName])
    var archived = tBank
    archived.archived = true
    let card = PaymentCard(id: id(30), accountId: id(1), name: "Gold")
    #expect(
      CardRules.validate(card, previous: nil, cards: [], accounts: [archived])
        == [.accountArchived])
  }

  @Test func accountNameOfAnotherAccountsCardIsRefused() {
    #expect(CardRules.cardTaking("BLACK", except: id(2), cards: cards)?.id == id(11))
    #expect(CardRules.cardTaking("virt", except: id(2), cards: cards)?.id == id(12))
    // An account may carry the name of its own card, and an archived card holds no name.
    #expect(CardRules.cardTaking("Black", except: id(1), cards: cards) == nil)
    var archived = black
    archived.archived = true
    #expect(CardRules.cardTaking("Black", except: id(2), cards: [archived]) == nil)
  }

  @Test func displayNameJoinsAccountAndCard() {
    #expect(CardRules.displayName(account: "T-Bank", card: "Black") == "T-Bank › Black")
    #expect(CardRules.displayName(account: "T-Bank", card: nil) == "T-Bank")
  }

  @Test func displayNameOmitsCardNamedLikeItsAccount() {
    #expect(CardRules.displayName(account: "Сбер", card: " сбер") == "Сбер")
    #expect(CardRules.displayName(account: "Ёлка", card: "Елка") == "Ёлка")
  }

  @Test func resolvingACardPicksItsAccount() {
    let card = CardRules.resolve(selection: id(12), cards: cards)
    #expect(card.accountId == id(1) && card.cardId == id(12))
    let account = CardRules.resolve(selection: id(2), cards: cards)
    #expect(account.accountId == id(2) && account.cardId == nil)
    let none = CardRules.resolve(selection: nil, cards: cards)
    #expect(none.accountId == nil && none.cardId == nil)
  }

  @Test func orderedListsLiveCardsByTheirOrderThenName() {
    var archived = PaymentCard(id: id(13), accountId: id(1), name: "Old", archived: true)
    archived.sort = 0
    let first = PaymentCard(id: id(14), accountId: id(1), name: "Zeta", sort: 1)
    let ordered = CardRules.ordered(
      [virtual, archived, black, first, sberCard], of: id(1),
      locale: Locale(identifier: "en_US_POSIX"))
    #expect(ordered.map(\.id) == [id(11), id(12), id(14)])
  }

  @Test func placeDefaultBringsTheCardOnlyForTheSameAccount() {
    #expect(
      CardRules.cardForNewOperation(
        chosenAccount: id(1), lastAtPlace: (accountId: id(1), cardId: id(12)), cards: cards)
        == id(12))
    #expect(
      CardRules.cardForNewOperation(
        chosenAccount: id(2), lastAtPlace: (accountId: id(1), cardId: id(12)), cards: cards)
        == nil)
    var archived = virtual
    archived.archived = true
    #expect(
      CardRules.cardForNewOperation(
        chosenAccount: id(1), lastAtPlace: (accountId: id(1), cardId: id(12)),
        cards: [black, archived]) == nil)
    #expect(
      CardRules.cardForNewOperation(chosenAccount: id(1), lastAtPlace: nil, cards: cards) == nil)
  }

  @Test func accountChangeDropsTheCard() {
    #expect(CardRules.cardAfterAccountChange(id(11), to: id(2), cards: cards) == nil)
    #expect(CardRules.cardAfterAccountChange(id(11), to: id(1), cards: cards) == id(11))
    #expect(CardRules.cardAfterAccountChange(id(11), to: nil, cards: cards) == nil)
    #expect(CardRules.cardAfterAccountChange(nil, to: id(1), cards: cards) == nil)
  }
}

/// The card a purchase on an account is made with unless it says otherwise.
@Suite("The main card of an account")
struct MainCardTests {
  let account = PaymentMethod(id: id(1), name: "Сбер")
  var cards: [PaymentCard] {
    [
      PaymentCard(id: id(11), accountId: id(1), name: "Мир"),
      PaymentCard(id: id(12), accountId: id(1), name: "Visa"),
      PaymentCard(id: id(13), accountId: id(1), name: "Старая", archived: true),
      PaymentCard(id: id(21), accountId: id(2), name: "Чужая"),
    ]
  }

  /// The main card while it is a live card of the account; else the one live card; else none.
  @Test func theDefaultCard() {
    var main = account
    main.mainCardId = id(12)
    #expect(CardRules.defaultCard(account: main, cards: cards) == id(12))
    #expect(CardRules.defaultCard(account: account, cards: cards) == nil)
    main.mainCardId = id(13)
    #expect(CardRules.defaultCard(account: main, cards: cards) == nil)
    main.mainCardId = id(21)
    #expect(CardRules.defaultCard(account: main, cards: cards) == nil)
    let single = cards.filter { $0.id != id(12) }
    #expect(CardRules.defaultCard(account: account, cards: single) == id(11))
  }

  /// The order: the card the line named → «со счёта» → the card of the place → the main card.
  @Test func theOrderOfTheChoice() {
    var main = account
    main.mainCardId = id(12)
    func card(_ named: UUID?, _ without: Bool, _ place: UUID?) -> UUID? {
      CardRules.operationCard(
        named: named, withoutCard: without, placeCard: place, account: main, cards: cards)
    }
    #expect(card(id(11), true, id(12)) == id(11))
    #expect(card(nil, true, id(11)) == nil)
    #expect(card(nil, false, id(11)) == id(11))
    #expect(card(nil, false, nil) == id(12))
  }

  /// The main card into the archive: the account loses it in the same write; merged away: the
  /// kept card is main.
  @Test func archivingAndMergingTheMainCard() throws {
    var main = account
    main.mainCardId = id(11)
    #expect(CardRules.account(main, afterArchiving: id(11))?.mainCardId == nil)
    #expect(CardRules.account(main, afterArchiving: id(12)) == nil)
    let plan = try CardMerge.plan(
      merging: id(11), into: id(12), cards: cards, rules: [], accounts: [main]
    ).get()
    #expect(CardMerge.account(main, after: plan)?.mainCardId == id(12))
    #expect(CardRules.validMainCard(of: main, cards: cards) == id(11))
    main.mainCardId = id(21)
    #expect(CardRules.validMainCard(of: main, cards: cards) == nil)
  }
}
