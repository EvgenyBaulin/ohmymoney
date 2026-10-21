import CoreKit
import Foundation

extension AccountMerge {
  /// The bank an account stands under for a merge: its bank, or — for an account under none —
  /// the account itself, so nothing merges with it.
  public static func bank(of account: PaymentMethod) -> UUID {
    account.bankId ?? account.id
  }

  /// Whether `source` may be merged into `target`: two accounts of one bank. Money of one bank
  /// never lands on an account of another by a merge; to bring two banks together, the banks
  /// are merged first (`BankMerge`).
  public static func canMerge(_ source: PaymentMethod, into target: PaymentMethod) -> Bool {
    source.id != target.id && bank(of: source) == bank(of: target)
  }
}

/// Why one bank cannot be merged into another.
public enum BankMergeIssue: Error, Hashable, Sendable {
  case notFound
  case sameBank
  /// Either bank is in the archive.
  case archived
}

/// A merge of one bank into another, worked out before it is written.
public struct BankMergePlan: Hashable, Sendable {
  /// The bank that goes away.
  public var merged: Bank
  /// The bank that stays, as it is: its name does not change.
  public var kept: Bank
  /// Every account of the merged bank, archived ones too, filed under the kept bank.
  public var movedAccounts: [PaymentMethod]

  public init(merged: Bank, kept: Bank, movedAccounts: [PaymentMethod]) {
    self.merged = merged
    self.kept = kept
    self.movedAccounts = movedAccounts
  }
}

/// «Объединить с…» of a bank. A bank owns no money, so a merge moves none: every account of the
/// merged bank, archived ones too, is filed under the kept bank, and the merged bank is deleted.
/// An account keeps its own name — names of accounts are unique among all of them, so nothing
/// clashes — and the entry line reads what it read before; the lists name the accounts anew by
/// how many stand under the kept bank (`AccountLabels`).
public enum BankMerge {
  /// Whether «Объединить с…» is offered for `bank`: a live bank while another live bank exists.
  public static func offered(for bank: Bank, banks: [Bank]) -> Bool {
    !bank.archived && banks.contains { $0.id != bank.id && !$0.archived }
  }

  /// The banks `bank` can be merged into: the other live banks, in list order.
  public static func targets(
    for bank: Bank, banks: [Bank], locale: Locale = .current
  ) -> [Bank] {
    BankRules.ordered(banks, locale: locale).filter { $0.id != bank.id }
  }

  /// The merge of `mergedId` into `keptId`; `banks` and `accounts` are all of them, archived
  /// ones too.
  public static func plan(
    merging mergedId: UUID, into keptId: UUID, banks: [Bank], accounts: [PaymentMethod]
  ) -> Result<BankMergePlan, BankMergeIssue> {
    guard let merged = banks.first(where: { $0.id == mergedId }),
      let kept = banks.first(where: { $0.id == keptId })
    else { return .failure(.notFound) }
    guard merged.id != kept.id else { return .failure(.sameBank) }
    guard !merged.archived, !kept.archived else { return .failure(.archived) }
    let moved = BankRules.accounts(under: merged.id, among: accounts).map { account in
      var account = account
      account.bankId = kept.id
      return account
    }
    return .success(BankMergePlan(merged: merged, kept: kept, movedAccounts: moved))
  }
}
