import CoreAccounting
import CoreKit
import Foundation

extension SampleDataSet {
  /// The set with every account under a bank, as an update of the books leaves them: a bank of
  /// the account's own name (`BanksMigration`), accounts called alike under one. Derived from the
  /// accounts, never drawn — no id, moment or amount of any row moves, so every digest and known
  /// answer of the set stays as it is. A bank or an account already filed stays; doing it twice
  /// changes nothing more.
  public func assigningBanks() -> SampleDataSet {
    let plan = BanksMigration.plan(
      accounts: paymentMethods.map {
        MigratingBankAccount(
          id: $0.id, name: $0.name, archived: $0.archived, hasBank: $0.bankId != nil)
      })
    guard !plan.assignments.isEmpty else { return self }
    var set = self
    let banks = Dictionary(plan.assignments.map { ($0.account, $0.bank) }) { first, _ in first }
    set.paymentMethods = paymentMethods.map { account in
      guard account.bankId == nil, let bank = banks[account.id] else { return account }
      var account = account
      account.bankId = bank
      return account
    }
    set.banks = self.banks + plan.banks
    return set
  }
}
