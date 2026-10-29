import CoreKit
import Foundation
import Testing

@testable import CoreAccounting

/// A credit card is never opened, or left, without a card.
@Suite("Credit card needs a card")
struct CreditCardCardRulesTests {
  let tBank = PaymentMethod(id: id(1), name: "T-Bank", kind: .card)
  let sber = PaymentMethod(id: id(2), name: "Sber", kind: .card)
  let black = PaymentCard(id: id(11), accountId: id(1), name: "Black")
  let sberCard = PaymentCard(id: id(21), accountId: id(2), name: "Sber")
  var accounts: [PaymentMethod] { [tBank, sber] }
  var cards: [PaymentCard] { [black, sberCard] }

  var credit: PaymentMethod {
    PaymentMethod(
      id: id(5), name: "Loan card", kind: .other,
      credit: CreditCardTerms(limitE4: AmountE4(whole: 1)))
  }

  @Test func aCreditCardOfAnyKindStartsWithACardNamedAsTyped() throws {
    let named = try #require(CardRules.startingCard(for: credit, named: " Gold "))
    #expect(named.name == "Gold" && named.accountId == credit.id)
    #expect(CardRules.startingCard(for: credit)?.name == "Loan card")
    #expect(CardRules.startingCard(for: credit, named: "   ")?.name == "Loan card")
  }

  @Test func aCreditCardLacksACardUntilOneIsLive() {
    #expect(CardRules.creditCardLacksCard(credit, cards: []))
    #expect(!CardRules.creditCardLacksCard(tBank, cards: []))
    let archived = PaymentCard(accountId: credit.id, name: "Old", archived: true)
    #expect(CardRules.creditCardLacksCard(credit, cards: [archived, black]))
    let live = PaymentCard(accountId: credit.id, name: "Gold")
    #expect(!CardRules.creditCardLacksCard(credit, cards: [archived, live]))
    var shut = credit
    shut.archived = true
    #expect(!CardRules.creditCardLacksCard(shut, cards: []))
  }

  @Test func theOnlyCardOfACreditCardStays() {
    let only = PaymentCard(accountId: credit.id, name: "Gold")
    let all = accounts + [credit]
    #expect(CardRules.isLastCardOfCreditCard(only, cards: [only], accounts: all))
    let second = PaymentCard(accountId: credit.id, name: "Silver")
    #expect(!CardRules.isLastCardOfCreditCard(only, cards: [only, second], accounts: all))
    let gone = PaymentCard(accountId: credit.id, name: "Old", archived: true)
    #expect(CardRules.isLastCardOfCreditCard(only, cards: [only, gone], accounts: all))
    // A plain card may go.
    #expect(!CardRules.isLastCardOfCreditCard(sberCard, cards: cards, accounts: all))
  }
}
