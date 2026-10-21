import CoreKit
import Foundation
import Testing

@testable import CoreAccounting

@Suite("Merging accounts within a bank, and banks into one another")
struct BankMergeTests {
  private let english = Locale(identifier: "en")

  // MARK: Accounts merge only within one bank

  @Test func accountsOfOneBankMerge() {
    let sber = Bank(name: "Сбер")
    let card = PaymentMethod(name: "Сбер карта", kind: .card, bankId: sber.id)
    let deposit = PaymentMethod(name: "Сбер вклад", kind: .account, bankId: sber.id)
    #expect(AccountMerge.canMerge(card, into: deposit))
    #expect(AccountMerge.canMerge(deposit, into: card))
  }

  /// Money of one bank does not land on an account of another by a merge.
  @Test func accountsOfTwoBanksDoNotMerge() {
    let card = PaymentMethod(name: "Сбер", kind: .card, bankId: UUID())
    let other = PaymentMethod(name: "Т-Банк", kind: .card, bankId: UUID())
    #expect(!AccountMerge.canMerge(card, into: other))
  }

  /// An account under no bank is a bank of its own: nothing merges with it.
  @Test func anAccountWithoutABankIsItsOwnBank() {
    let lone = PaymentMethod(name: "Наличные", kind: .cash)
    let other = PaymentMethod(name: "Кошелёк", kind: .cash)
    let banked = PaymentMethod(name: "Сбер", kind: .card, bankId: UUID())
    #expect(AccountMerge.bank(of: lone) == lone.id)
    #expect(!AccountMerge.canMerge(lone, into: other))
    #expect(!AccountMerge.canMerge(lone, into: banked))
    #expect(!AccountMerge.canMerge(banked, into: lone))
  }

  @Test func anAccountIsNotMergedIntoItself() {
    let account = PaymentMethod(name: "Сбер", kind: .card, bankId: UUID())
    #expect(!AccountMerge.canMerge(account, into: account))
  }

  // MARK: Banks merge

  @Test func aBankMergeMovesEveryAccountArchivedOnesTooUnderTheKeptBank() throws {
    let tinkoff = Bank(name: "Тинькофф")
    let tBank = Bank(name: "Т-Банк")
    let card = PaymentMethod(name: "Тинькофф", kind: .card, bankId: tinkoff.id)
    let old = PaymentMethod(
      name: "Тинькофф старый", kind: .card, archived: true, bankId: tinkoff.id)
    let kept = PaymentMethod(name: "Т-Банк", kind: .card, bankId: tBank.id)
    let plan = try BankMerge.plan(
      merging: tinkoff.id, into: tBank.id, banks: [tinkoff, tBank], accounts: [card, old, kept]
    ).get()
    #expect(plan.merged == tinkoff)
    #expect(plan.kept == tBank, "the kept bank keeps its name")
    #expect(plan.movedAccounts.map(\.id) == [card.id, old.id])
    #expect(plan.movedAccounts.allSatisfy { $0.bankId == tBank.id })
    #expect(plan.movedAccounts.first { $0.id == old.id }?.archived == true)
    #expect(plan.movedAccounts.first?.name == "Тинькофф", "an account keeps its own name")
  }

  @Test func aBankWithNoAccountsStillMerges() throws {
    let empty = Bank(name: "Пустой")
    let kept = Bank(name: "Сбер")
    let plan = try BankMerge.plan(
      merging: empty.id, into: kept.id, banks: [empty, kept], accounts: []
    ).get()
    #expect(plan.movedAccounts.isEmpty)
  }

  @Test func aBankMergeIsRefusedInWords() {
    let sber = Bank(name: "Сбер")
    let tBank = Bank(name: "Т-Банк")
    let old = Bank(name: "Старый", archived: true)
    let banks = [sber, tBank, old]
    #expect(
      BankMerge.plan(merging: sber.id, into: sber.id, banks: banks, accounts: [])
        == .failure(.sameBank))
    #expect(
      BankMerge.plan(merging: sber.id, into: UUID(), banks: banks, accounts: [])
        == .failure(.notFound))
    #expect(
      BankMerge.plan(merging: old.id, into: sber.id, banks: banks, accounts: [])
        == .failure(.archived))
    #expect(
      BankMerge.plan(merging: sber.id, into: old.id, banks: banks, accounts: [])
        == .failure(.archived))
  }

  @Test func theTargetsAreTheOtherLiveBanksInListOrder() {
    let sber = Bank(name: "Сбер")
    let alfa = Bank(name: "Альфа")
    let tBank = Bank(name: "Т-Банк")
    let old = Bank(name: "Старый", archived: true)
    let banks = [sber, tBank, old, alfa]
    #expect(
      BankMerge.targets(for: sber, banks: banks, locale: english).map(\.id) == [alfa.id, tBank.id])
    #expect(BankMerge.offered(for: sber, banks: banks))
    #expect(!BankMerge.offered(for: old, banks: banks), "a bank in the archive is not merged")
    #expect(!BankMerge.offered(for: sber, banks: [sber, old]), "no other live bank")
  }

  /// The labels follow the merge by themselves: a bank with one account is named alone, and once
  /// a second account stands under it, each account is «Банк › Счёт».
  @Test func theLabelsFollowAMerge() throws {
    let tBank = Bank(name: "Т-Банк")
    let tinkoff = Bank(name: "Тинькофф")
    let kept = PaymentMethod(name: "Т-Банк", kind: .card, bankId: tBank.id)
    let card = PaymentCard(accountId: kept.id, name: "Т-Банк")
    let moved = PaymentMethod(name: "Вклад", kind: .account, bankId: tinkoff.id)
    let plan = try BankMerge.plan(
      merging: tinkoff.id, into: tBank.id, banks: [tBank, tinkoff], accounts: [kept, moved]
    ).get()
    let before = AccountLabels(accounts: [kept, moved], cards: [card], banks: [tBank, tinkoff])
    #expect(before.label(account: kept.id) == "Т-Банк")
    #expect(before.label(account: moved.id) == "Тинькофф")
    let after = AccountLabels(
      accounts: [kept] + plan.movedAccounts, cards: [card], banks: [tBank])
    #expect(after.label(account: kept.id) == "Т-Банк")
    #expect(after.label(account: moved.id) == "Т-Банк › Вклад")
  }
}
