import CoreAccounting
import CoreKit
import Foundation
import Testing

@Suite("Financial names stay unique only among live records")
struct FinancialNameRulesTests {
  @Test func archivedAccountNamesAndAliasesAreFreeButLiveOnesStayReserved() {
    var old = PaymentMethod(name: "Ёлка", aliases: ["Reserve"], archived: true)
    let new = PaymentMethod(name: " елка ")
    #expect(AccountRules.nameConflict(new, accounts: [old], cards: []) == nil)
    var alias = PaymentMethod(name: "New", aliases: ["RESERVE"])
    #expect(AccountRules.nameConflict(alias, accounts: [old], cards: []) == nil)
    old.archived = false
    #expect(AccountRules.nameConflict(new, accounts: [old], cards: []) == .nameTaken)
    #expect(
      AccountRules.nameConflict(alias, accounts: [old], cards: [])
        == .otherNameTaken("RESERVE"))
    alias.archived = true
    #expect(AccountRules.nameConflict(alias, accounts: [old], cards: []) == nil)
  }

  @Test func cardsOfArchivedAccountsDoNotReserveNamesOrAliases() {
    var old = PaymentMethod(name: "Old", archived: true)
    let card = PaymentCard(accountId: old.id, name: "Gold", aliases: ["Travel"])
    let account = PaymentMethod(name: "GOLD")
    #expect(AccountRules.nameConflict(account, accounts: [old], cards: [card]) == nil)
    let new = PaymentCard(accountId: account.id, name: "travel")
    #expect(
      CardRules.validate(new, previous: nil, cards: [card], accounts: [old, account]).isEmpty)
    old.archived = false
    #expect(
      AccountRules.nameConflict(account, accounts: [old], cards: [card])
        == .nameTakenByCard("Gold"))
    #expect(
      CardRules.validate(new, previous: nil, cards: [card], accounts: [old, account])
        == [.nameTaken(owner: .card(card.id))])
  }

  @Test func anArchivedAccountDoesNotReserveItsNameForCards() {
    var old = PaymentMethod(name: "Old", aliases: ["Travel"], archived: true)
    let owner = PaymentMethod(name: "Current")
    let new = PaymentCard(accountId: owner.id, name: "Visa", aliases: ["travel"])
    #expect(CardRules.validate(new, previous: nil, cards: [], accounts: [old, owner]).isEmpty)
    old.archived = false
    #expect(
      CardRules.validate(new, previous: nil, cards: [], accounts: [old, owner])
        == [.otherNameTaken("travel", owner: .account(old.id))])
  }
}
