import CoreKit
import Foundation
import Testing

@testable import CoreAccounting

/// A credit card is an account with a minus; a debt of the same name would count the same money
/// twice. The form of a new debt says so while the name is one an account answers to.
@Suite("A debt called like an account")
struct DebtNamingTests {
  let credit = PaymentMethod(name: "Кредитка", kind: .card, aliases: ["кредитная карта"])
  let sber = PaymentMethod(name: "Сбер", kind: .card)

  @Test func aDebtCalledLikeALiveAccountIsTold() {
    let match = DebtNaming.accountAnswering(to: "Кредитка", accounts: [sber, credit], cards: [])
    #expect(match == DebtNaming.Match(accountName: "Кредитка", isCard: false))
  }

  /// Case, spaces around and «ё» against «е» do not count, as everywhere the line reads a name.
  @Test func theNameIsReadTheWayTheEntryLineReadsIt() {
    let elka = PaymentMethod(name: "Ёлка")
    #expect(
      DebtNaming.accountAnswering(to: "  елка ", accounts: [elka], cards: [])?.accountName
        == "Ёлка")
    #expect(
      DebtNaming.accountAnswering(to: "КРЕДИТКА", accounts: [credit], cards: [])?.accountName
        == "Кредитка")
  }

  @Test func anotherNameOfAnAccountIsToldToo() {
    let match = DebtNaming.accountAnswering(
      to: "Кредитная карта", accounts: [credit], cards: [])
    #expect(match?.accountName == "Кредитка")
  }

  @Test func aLiveCardIsToldByItsAccount() {
    let black = PaymentCard(accountId: sber.id, name: "Black", aliases: ["блэк"])
    #expect(
      DebtNaming.accountAnswering(to: "Black", accounts: [sber], cards: [black])
        == DebtNaming.Match(accountName: "Сбер", isCard: true))
    #expect(
      DebtNaming.accountAnswering(to: "Блэк", accounts: [sber], cards: [black])?.isCard == true)
  }

  @Test func whatIsInTheArchiveAnswersToNothing() {
    var old = credit
    old.archived = true
    #expect(DebtNaming.accountAnswering(to: "Кредитка", accounts: [old], cards: []) == nil)
    let gone = PaymentCard(accountId: sber.id, name: "Old", archived: true)
    #expect(DebtNaming.accountAnswering(to: "Old", accounts: [sber], cards: [gone]) == nil)
    // A live card of an archived account is read by nobody.
    var archivedSber = sber
    archivedSber.archived = true
    let card = PaymentCard(accountId: sber.id, name: "Black")
    #expect(
      DebtNaming.accountAnswering(to: "Black", accounts: [archivedSber], cards: [card]) == nil)
  }

  @Test func otherNamesAreNotTold() {
    #expect(DebtNaming.accountAnswering(to: "Ипотека", accounts: [sber, credit], cards: []) == nil)
    #expect(DebtNaming.accountAnswering(to: "Кредит", accounts: [credit], cards: []) == nil)
  }

  @Test func anEmptyNameIsNoName() {
    #expect(DebtNaming.accountAnswering(to: "   ", accounts: [credit], cards: []) == nil)
    #expect(DebtNaming.accountAnswering(to: "", accounts: [credit], cards: []) == nil)
  }

  /// An account wins over a card of the same word: the account is what the owner has named.
  @Test func anAccountIsToldBeforeACard() {
    let card = PaymentCard(accountId: sber.id, name: "Кредитка")
    let match = DebtNaming.accountAnswering(
      to: "Кредитка", accounts: [sber, credit], cards: [card])
    #expect(match == DebtNaming.Match(accountName: "Кредитка", isCard: false))
  }
}
