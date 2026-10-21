import CoreKit
import Foundation
import Testing

@testable import CoreAccounting

/// Whose rules price an operation: the card it names; else its account — whatever cards the
/// account has. A second card, or a card in the archive, never changes the past.
@Suite("Whose cashback rules price an operation")
struct CashbackHolderTests {
  let fixture = CashbackFixture()

  func holder(account: UUID?, card: UUID? = nil) -> CashbackHolder? {
    CashbackHolders.holder(accountId: account, cardId: card, mainAccountId: fixture.sber)
  }

  /// «хлеб 60 сбер»: no card named, Sber has one card → the account, whose rule is 0.5 %: 0.30.
  @Test func noCardNamedIsTheAccountEvenWithOneCard() throws {
    #expect(holder(account: fixture.sber) == .account(fixture.sber))
    let bread = fixture.operation(
      on: "09-12", parts: [(fixture.home, money(60))], account: fixture.sber)
    #expect(try #require(fixture.expected(bread)).money.amount == money("0.3"))
  }

  /// «кофе 300 т-банк»: two cards, none named → the account itself, which holds no rules here.
  @Test func twoCardsAndNoneNamedIsTheAccount() {
    #expect(holder(account: fixture.tBank) == .account(fixture.tBank))
    let coffee = fixture.operation(
      on: "09-12", parts: [(fixture.coffee, money(300))], account: fixture.tBank)
    #expect(fixture.expected(coffee) == nil)
  }

  /// «кофе 300 black»: the card named → 10 % → 30.00.
  @Test func theNamedCard() throws {
    #expect(holder(account: fixture.tBank, card: fixture.black) == .card(fixture.black))
    let coffee = fixture.operation(
      on: "09-12", parts: [(fixture.coffee, money(300))], account: fixture.tBank,
      card: fixture.black)
    #expect(try #require(fixture.expected(coffee)).money.amount == money(30))
  }

  /// «хлеб 60» with no account: the main account's, Sber.
  @Test func noAccountIsTheMainAccount() {
    #expect(holder(account: nil) == .account(fixture.sber))
    #expect(CashbackHolders.holder(accountId: nil, cardId: nil, mainAccountId: nil) == nil)
  }

  /// «кофе 200 наличные»: cash has no card → the account, no rules → no expectation.
  @Test func anAccountWithoutCards() {
    #expect(holder(account: fixture.cash) == .account(fixture.cash))
  }

  /// An archived card named by an old purchase still prices it with its own rules and the
  /// account's.
  @Test func anArchivedCardNamedStillPrices() {
    var archived = fixture.cards
    archived[1].archived = true
    #expect(holder(account: fixture.tBank, card: fixture.virtual) == .card(fixture.virtual))
    #expect(
      CashbackHolders.editableHolders(of: fixture.tBank, cards: archived) == [
        .account(fixture.tBank), .card(fixture.black),
      ])
  }

  @Test func editableHoldersAreTheAccountThenItsLiveCards() {
    #expect(
      CashbackHolders.editableHolders(of: fixture.tBank, cards: fixture.cards) == [
        .account(fixture.tBank), .card(fixture.black), .card(fixture.virtual),
      ])
    #expect(
      CashbackHolders.editableHolders(of: fixture.cash, cards: fixture.cards) == [
        .account(fixture.cash)
      ])
    #expect(
      CashbackHolders.account(of: .card(fixture.virtual), cards: fixture.cards) == fixture.tBank)
  }
}
