import CoreKit
import Foundation
import Testing

@testable import CoreAccounting

@Suite("Rules of the banks")
struct BankRulesTests {
  private let english = Locale(identifier: "en")

  // MARK: Names

  @Test func aBankNeedsAName() {
    #expect(BankRules.validate(Bank(name: "  "), among: []) == [.emptyName])
    #expect(BankRules.validate(Bank(name: ""), among: []) == [.emptyName])
  }

  @Test func aLiveBankIsNotCalledLikeAnotherLiveBank() {
    let sber = Bank(name: "Сбер")
    #expect(BankRules.validate(Bank(name: " сбер "), among: [sber]) == [.nameTaken(sber.id)])
    // «ё» and «е» are one letter to the entry line, so they are to the banks.
    let elka = Bank(name: "Ёлка")
    #expect(BankRules.validate(Bank(name: "елка"), among: [elka]) == [.nameTaken(elka.id)])
  }

  @Test func aBankDoesNotClashWithItself() {
    let sber = Bank(name: "Сбер")
    #expect(BankRules.validate(sber, among: [sber]).isEmpty)
    var renamed = sber
    renamed.name = "СБЕР"
    #expect(BankRules.validate(renamed, among: [sber]).isEmpty)
  }

  /// The archive keeps names the way every other list does: a name in it is free.
  @Test func aNameInTheArchiveIsFree() {
    let old = Bank(name: "Сбер", archived: true)
    #expect(BankRules.validate(Bank(name: "Сбер"), among: [old]).isEmpty)
  }

  /// A bank brought back from the archive meets the live ones again.
  @Test func aBankComingBackMeetsTheLiveOnes() {
    let live = Bank(name: "Сбер")
    let old = Bank(name: "Сбер", archived: true)
    var back = old
    back.archived = false
    #expect(BankRules.validate(back, among: [live, old]) == [.nameTaken(live.id)])
  }

  @Test func anArchivedBankIsNotHeldToTheNames() {
    let live = Bank(name: "Сбер")
    #expect(BankRules.validate(Bank(name: "Сбер", archived: true), among: [live]).isEmpty)
  }

  // MARK: Order

  @Test func banksAreOrderedByPlaceThenNameAndTheArchiveIsLeftOut() {
    let a = Bank(name: "Альфа")
    let v = Bank(name: "ВТБ")
    let s = Bank(name: "Сбер")
    let gone = Bank(name: "Аaa", archived: true)
    #expect(
      BankRules.ordered([s, v, a, gone], locale: english).map(\.name) == ["Альфа", "ВТБ", "Сбер"])
    // Dragged banks keep the place they were dragged to; the ones never dragged (0) come first,
    // alphabetically, as the accounts and the groups do.
    var dragged = s
    dragged.sort = 1
    var second = a
    second.sort = 2
    #expect(
      BankRules.ordered([second, v, dragged], locale: english).map(\.name) == [
        "ВТБ", "Сбер", "Альфа",
      ])
  }

  @Test func aNewBankIsPlacedAfterTheDraggedOnesOrAlphabetically() {
    #expect(BankRules.sortForNewBank(among: []) == 0)
    #expect(BankRules.sortForNewBank(among: [Bank(name: "A"), Bank(name: "B")]) == 0)
    #expect(BankRules.sortForNewBank(among: [Bank(name: "A", sort: 3), Bank(name: "B")]) == 4)
  }

  // MARK: What is under a bank

  private func account(_ name: String, in bank: Bank?, archived: Bool = false) -> PaymentMethod {
    PaymentMethod(name: name, archived: archived, bankId: bank?.id)
  }

  @Test func theAccountsUnderABankAreThoseThatNameIt() {
    let sber = Bank(name: "Сбер")
    let vtb = Bank(name: "ВТБ")
    let one = account("Сбер", in: sber)
    let two = account("Накопительный", in: sber, archived: true)
    let other = account("ВТБ", in: vtb)
    let loose = account("Наличные", in: nil)
    let found = BankRules.accounts(under: sber.id, among: [one, two, other, loose])
    #expect(Set(found.map(\.id)) == [one.id, two.id])
  }

  @Test func aBankGoesToTheArchiveOnceEveryAccountUnderItHas() {
    let sber = Bank(name: "Сбер")
    let live = account("Сбер", in: sber)
    let old = account("Старый", in: sber, archived: true)
    #expect(!BankRules.canBeArchived(sber.id, among: [live, old]))
    #expect(BankRules.canBeArchived(sber.id, among: [old]))
    #expect(BankRules.canBeArchived(sber.id, among: []))
  }

  @Test func aBankIsDeletedOnlyWithNoAccountUnderItArchivedOnesIncluded() {
    let sber = Bank(name: "Сбер")
    #expect(BankRules.canBeDeleted(sber.id, among: []))
    #expect(!BankRules.canBeDeleted(sber.id, among: [account("Сбер", in: sber, archived: true)]))
    #expect(!BankRules.canBeDeleted(sber.id, among: [account("Сбер", in: sber)]))
    #expect(BankRules.canBeDeleted(sber.id, among: [account("ВТБ", in: Bank(name: "ВТБ"))]))
  }

  // MARK: A new bank

  @Test func aNewBankStartsWithAnAccountAndACardOfItsName() {
    let live = [PaymentMethod(name: "Cash", isDefault: true, bankId: UUID())]
    let kit = BankRules.startingKit(
      named: "  Т-Банк ", currency: .usd, accounts: live, banks: [])
    #expect(kit.bank.name == "Т-Банк")
    #expect(kit.account.name == "Т-Банк")
    #expect(kit.account.kind == .card)
    #expect(kit.account.currency == .usd)
    #expect(kit.account.bankId == kit.bank.id)
    #expect(!kit.account.isDefault)
    let card = kit.card
    #expect(card?.name == "Т-Банк")
    #expect(card?.accountId == kit.account.id)
    #expect(card?.archived == false)
  }

  /// The first account of a book is the main one: the entry line puts it on every operation
  /// that names none.
  @Test func theFirstAccountOfABookIsTheMainOne() {
    let kit = BankRules.startingKit(named: "Сбер", currency: .rub, accounts: [], banks: [])
    #expect(kit.account.isDefault)
  }

  @Test func theNewAccountAndBankGoAfterTheDraggedOnes() {
    let accounts = [PaymentMethod(name: "A", isDefault: true, sort: 2, bankId: UUID())]
    let banks = [Bank(name: "A", sort: 5)]
    let kit = BankRules.startingKit(named: "B", currency: .rub, accounts: accounts, banks: banks)
    #expect(kit.account.sort == 3)
    #expect(kit.bank.sort == 6)
  }

  @Test func aNewAccountNamedLikeALiveBankJoinsIt() {
    let sber = Bank(name: "Сбер")
    let joined = BankRules.bank(forNewAccountNamed: " сбер", among: [sber])
    #expect(joined.bank == sber)
    #expect(!joined.isNew)
  }

  @Test func aNewAccountNamedLikeNoBankMakesOne() {
    let sber = Bank(name: "Сбер", archived: true)
    let made = BankRules.bank(forNewAccountNamed: "Сбер", among: [sber, Bank(name: "ВТБ")])
    #expect(made.isNew)
    #expect(made.bank.name == "Сбер")
    #expect(made.bank.id != sber.id)
    #expect(!made.bank.archived)
  }
}
