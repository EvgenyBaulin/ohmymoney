import CoreKit
import Foundation
import Testing

@testable import CoreAccounting

@Suite("The banks the update makes")
struct BanksMigrationTests {
  private func account(
    _ name: String, archived: Bool = false, hasBank: Bool = false, id: UUID = UUID()
  ) -> MigratingBankAccount {
    MigratingBankAccount(id: id, name: name, archived: archived, hasBank: hasBank)
  }

  @Test func everyAccountGetsABankOfItsOwnName() {
    let sber = account("Сбер")
    let cash = account("Наличные")
    let plan = BanksMigration.plan(accounts: [sber, cash])
    #expect(plan.banks.map(\.name) == ["Сбер", "Наличные"])
    #expect(plan.skipped == 0)
    let byAccount = Dictionary(uniqueKeysWithValues: plan.assignments.map { ($0.account, $0.bank) })
    #expect(byAccount[sber.id] == plan.banks[0].id)
    #expect(byAccount[cash.id] == plan.banks[1].id)
    #expect(plan.banks.allSatisfy { !$0.archived && $0.sort == 0 })
  }

  /// The same on every run and every retry, and never the account's own id.
  @Test func theIdOfABankIsTheAccountsIdMasked() {
    let sber = account("Сбер")
    let first = BanksMigration.plan(accounts: [sber])
    let again = BanksMigration.plan(accounts: [sber])
    #expect(first == again)
    #expect(first.banks[0].id == BanksMigration.bankId(forAccount: sber.id))
    #expect(first.banks[0].id != sber.id)
    // XOR with the same mask twice is the account's id again: the mask is what makes the id.
    #expect(
      BanksMigration.bankId(forAccount: BanksMigration.bankId(forAccount: sber.id)) == sber.id)
  }

  @Test func theNameIsTrimmed() {
    let plan = BanksMigration.plan(accounts: [account("  Т-Банк \n")])
    #expect(plan.banks.map(\.name) == ["Т-Банк"])
  }

  /// Accounts called alike — by the rule the entry line reads names — are one bank.
  @Test func accountsOfTheSameNameShareOneBank() {
    let live = account("Сбер")
    let old = account("сбер", archived: true)
    let elka = account("Ёлка")
    let spruce = account("елка", archived: true)
    let plan = BanksMigration.plan(accounts: [live, old, elka, spruce])
    #expect(plan.banks.map(\.name) == ["Сбер", "Ёлка"])
    let byAccount = Dictionary(uniqueKeysWithValues: plan.assignments.map { ($0.account, $0.bank) })
    #expect(byAccount[live.id] == byAccount[old.id])
    #expect(byAccount[elka.id] == byAccount[spruce.id])
    #expect(byAccount[live.id] != byAccount[elka.id])
  }

  /// The live account names the bank, whatever order the accounts were written in.
  @Test func aLiveAccountDecidesTheBankItSharesWithAnArchivedOne() {
    let old = account("сбер", archived: true)
    let live = account("Сбер")
    let plan = BanksMigration.plan(accounts: [old, live])
    #expect(plan.banks.count == 1)
    #expect(plan.banks[0].name == "Сбер")
    #expect(plan.banks[0].id == BanksMigration.bankId(forAccount: live.id))
    #expect(plan.assignments.count == 2)
  }

  @Test func anArchivedAccountGetsALiveBank() {
    let plan = BanksMigration.plan(accounts: [account("Наличные", archived: true)])
    #expect(plan.banks.count == 1)
    #expect(!plan.banks[0].archived)
  }

  @Test func anAccountWithABlankNameGetsNoBank() {
    let blank = account("  ")
    let sber = account("Сбер")
    let plan = BanksMigration.plan(accounts: [blank, sber])
    #expect(plan.banks.map(\.name) == ["Сбер"])
    #expect(plan.assignments.map(\.account) == [sber.id])
    #expect(plan.skipped == 1)
  }

  @Test func anAccountThatHasABankIsLeftAlone() {
    let filed = account("Сбер", hasBank: true)
    let loose = account("ВТБ")
    let plan = BanksMigration.plan(accounts: [filed, loose])
    #expect(plan.banks.map(\.name) == ["ВТБ"])
    #expect(plan.assignments.map(\.account) == [loose.id])
    #expect(plan.skipped == 0)
  }

  @Test func nothingIsPlannedWhenEveryAccountHasABank() {
    let plan = BanksMigration.plan(accounts: [account("Сбер", hasBank: true)])
    #expect(plan.banks.isEmpty)
    #expect(plan.assignments.isEmpty)
    #expect(BanksMigration.plan(accounts: []) == plan)
  }

  /// An account filed later — a hand edit left it without a bank — joins the live bank of its
  /// name that is there already, instead of making a second bank of the same name.
  @Test func anAccountJoinsALiveBankOfItsNameThatIsThereAlready() {
    let sber = Bank(name: "Сбер")
    let loose = account("сбер")
    let plan = BanksMigration.plan(accounts: [loose], among: [sber])
    #expect(plan.banks.isEmpty)
    #expect(plan.assignments == [.init(account: loose.id, bank: sber.id)])
  }

  /// A bank in the archive keeps its name for itself: a new account of that name makes a bank.
  @Test func anArchivedBankIsNotJoined() {
    let old = Bank(name: "Сбер", archived: true)
    let loose = account("Сбер")
    let plan = BanksMigration.plan(accounts: [loose], among: [old])
    #expect(plan.banks.count == 1)
    #expect(plan.banks[0].id != old.id)
    #expect(plan.assignments == [.init(account: loose.id, bank: plan.banks[0].id)])
  }

  /// The bank an earlier filing made for the account is there under another name, archived or
  /// not: the new bank does not take its id.
  @Test func aTakenIdIsNotGivenAgain() {
    let loose = account("Сбер")
    for archived in [false, true] {
      let renamed = Bank(
        id: BanksMigration.bankId(forAccount: loose.id), name: "Сбербанк", archived: archived)
      let plan = BanksMigration.plan(accounts: [loose], among: [renamed])
      #expect(plan.banks.count == 1)
      #expect(plan.banks[0].id != renamed.id)
      #expect(plan.banks[0].name == "Сбер")
      #expect(plan.assignments == [.init(account: loose.id, bank: plan.banks[0].id)])
    }
  }

  @Test func anIdGivenTwiceGetsOneBank() {
    let id = UUID()
    let plan = BanksMigration.plan(accounts: [account("Сбер", id: id), account("Сбер", id: id)])
    #expect(plan.banks.count == 1)
    #expect(plan.assignments.count == 1)
  }
}
