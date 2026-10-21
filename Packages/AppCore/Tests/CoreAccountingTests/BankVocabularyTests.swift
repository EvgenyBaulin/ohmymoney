import CoreKit
import Foundation
import Testing

@testable import CoreAccounting

/// The entry line knows a bank by its name too: «кофе 300 сбер» is the first account of the bank
/// «Сбер» whatever that account is called — unless the word already means something else.
@Suite("The name of a bank in the entry line")
struct BankVocabularyTests {
  private func account(
    _ name: String, in bank: Bank?, main: Bool = false, sort: Int = 0, archived: Bool = false,
    aliases: [String] = []
  ) -> PaymentMethod {
    PaymentMethod(
      name: name, aliases: aliases, isDefault: main, archived: archived, sort: sort,
      bankId: bank?.id)
  }

  @Test func aBankIsAnotherNameOfItsOnlyAccount() {
    let sber = Bank(name: "Сбер")
    let main = account("Основной", in: sber, main: true)
    #expect(
      BankVocabulary.spellings(banks: [sber], accounts: [main], cards: []) == [main.id: "Сбер"])
  }

  /// An account called like its bank answers to it already.
  @Test func anAccountCalledLikeItsBankNeedsNoSecondName() {
    let sber = Bank(name: "Сбер")
    let same = account("сбер", in: sber)
    #expect(BankVocabulary.spellings(banks: [sber], accounts: [same], cards: []).isEmpty)
    let aliased = account("Основной", in: sber, aliases: ["СБЕР"])
    #expect(BankVocabulary.spellings(banks: [sber], accounts: [aliased], cards: []).isEmpty)
  }

  /// With several accounts the word means the first one of the lists: the main account, then the
  /// order the owner dragged them to, then the name.
  @Test func aBankWithSeveralAccountsIsItsFirstAccount() {
    let tBank = Bank(name: "Т-Банк")
    let savings = account("Накопительный", in: tBank)
    let black = account("Black", in: tBank, sort: 1)
    let main = account("Зарплатный", in: tBank, main: true, sort: 2)
    #expect(
      BankVocabulary.spellings(banks: [tBank], accounts: [savings, black, main], cards: [])
        == [main.id: "Т-Банк"])
    // Without the main one: the places the owner dragged them to, then by name; one never
    // dragged (0) comes before the ones numbered, as it does in every list.
    #expect(
      BankVocabulary.spellings(banks: [tBank], accounts: [savings, black], cards: [])
        == [savings.id: "Т-Банк"])
  }

  @Test func theArchiveHasNoVoice() {
    let old = Bank(name: "Старый", archived: true)
    let archivedBank = account("Основной", in: old)
    #expect(BankVocabulary.spellings(banks: [old], accounts: [archivedBank], cards: []).isEmpty)
    let live = Bank(name: "Сбер")
    let gone = account("Основной", in: live, archived: true)
    #expect(
      BankVocabulary.spellings(banks: [live], accounts: [gone], cards: []).isEmpty,
      "a bank with no live account has nothing to name")
  }

  /// A word another account or a card answers to is theirs.
  @Test func aWordSomethingElseAnswersToIsNotTaken() {
    let sber = Bank(name: "Сбер")
    let main = account("Основной", in: sber)
    let other = account("Кошелёк", in: Bank(name: "Кошелёк"), aliases: ["сбер"])
    #expect(
      BankVocabulary.spellings(banks: [sber], accounts: [main, other], cards: []).isEmpty)
    let card = PaymentCard(accountId: other.id, name: "Сбер")
    let second = account("Запас", in: Bank(name: "Запас"))
    #expect(
      BankVocabulary.spellings(banks: [sber], accounts: [main, second, other], cards: [card])
        .isEmpty)
  }

  @Test func aCardOfAnArchivedAccountOrAnArchivedCardClaimsNothing() {
    let sber = Bank(name: "Сбер")
    let main = account("Основной", in: sber)
    let quiet = PaymentCard(accountId: main.id, name: "Сбер", archived: true)
    #expect(
      BankVocabulary.spellings(banks: [sber], accounts: [main], cards: [quiet])
        == [main.id: "Сбер"])
  }

  @Test func anAccountWithoutABankClaimsNothingAndTwoBanksNeverShareAWord() {
    let loose = account("Наличные", in: nil)
    let sber = Bank(name: "Сбер")
    let main = account("Основной", in: sber)
    #expect(
      BankVocabulary.spellings(banks: [sber], accounts: [loose, main], cards: [])
        == [main.id: "Сбер"])
    // Two banks of one folded name cannot be live together; if a hand edit made them, the first
    // keeps the word.
    let twin = Bank(name: "сбер")
    let other = account("Запас", in: twin)
    let spellings = BankVocabulary.spellings(
      banks: [sber, twin], accounts: [main, other], cards: [])
    #expect(spellings.count == 1)
  }
}
