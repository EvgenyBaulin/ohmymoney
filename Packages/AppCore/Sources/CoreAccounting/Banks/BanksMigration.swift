import CoreKit
import Foundation

/// An account as the update reads it, before any bank exists.
public struct MigratingBankAccount: Hashable, Sendable {
  public var id: UUID
  public var name: String
  public var archived: Bool
  /// The account already belongs to a bank: the update leaves it as it is.
  public var hasBank: Bool

  public init(id: UUID, name: String, archived: Bool, hasBank: Bool) {
    self.id = id
    self.name = name
    self.archived = archived
    self.hasBank = hasBank
  }
}

/// The banks the update makes, and which account goes under which, worked out before anything is
/// written.
public struct BanksMigrationPlan: Hashable, Sendable {
  /// One account's bank: what `payment_methods.bank_id` of the account is set to.
  public struct Assignment: Hashable, Sendable {
    public var account: UUID
    public var bank: UUID

    public init(account: UUID, bank: UUID) {
      self.account = account
      self.bank = bank
    }
  }

  public var banks: [Bank]
  public var assignments: [Assignment]
  /// Accounts whose name is empty once trimmed: a bank refuses such a name, so they get none.
  public var skipped: Int

  public init(banks: [Bank], assignments: [Assignment], skipped: Int) {
    self.banks = banks
    self.assignments = assignments
    self.skipped = skipped
  }
}

/// A bank for every account an older build left: the account was all there was — it was called
/// «Сбер» and was the bank, the account and the card at once —, and now it sits under a bank of
/// its own name. Nothing any figure reads changes: the money stays on the account.
///
/// Accounts called alike (by the rule the entry line compares names) are one bank: an archived
/// «Сбер» and the live one are the same bank, and a bank's name is never twice among the banks.
/// The live account names the bank and gives it its id; archived ones join it. A bank is never
/// made archived by the update — the owner's to do, once every account under it is.
public enum BanksMigration {
  /// The bytes the id of a bank made by the update is XOR-ed with: «bank» four times, ASCII.
  public static let idMask: [UInt8] = Array("bankbankbankbank".utf8)

  /// The id of the bank the update makes for `account`: the account's bytes XOR `idMask`. The
  /// same on every run and every retry — so an update stopped and tried again makes what an
  /// untouched one makes —, never the account's own id.
  public static func bankId(forAccount account: UUID) -> UUID {
    MaskedId.xor(account, with: idMask)
  }

  /// A bank for every account that has none: live accounts first, then archived ones, each in the
  /// order given. An id given twice counts once, the first. An account whose name is a live bank's
  /// of `existing` joins that bank; one bank of a name is never made twice.
  public static func plan(
    accounts: [MigratingBankAccount], among existing: [Bank] = []
  ) -> BanksMigrationPlan {
    var banks: [Bank] = []
    var bankByName: [String: UUID] = [:]
    // An id the update would give is taken when the account was filed once and a hand edit left
    // it without a bank since: its bank then gets an id of its own.
    let taken = Set(existing.map(\.id))
    for bank in existing where !bank.archived {
      let key = NameKey.fold(bank.name)
      if !key.isEmpty, bankByName[key] == nil { bankByName[key] = bank.id }
    }
    var assignments: [BanksMigrationPlan.Assignment] = []
    var skipped = 0
    var seen: Set<UUID> = []
    for account in accounts.filter({ !$0.archived }) + accounts.filter(\.archived)
    where !account.hasBank {
      guard seen.insert(account.id).inserted else { continue }
      let name = account.name.trimmingCharacters(in: .whitespacesAndNewlines)
      let key = NameKey.fold(name)
      guard !key.isEmpty else {
        skipped += 1
        continue
      }
      let bankId: UUID
      if let known = bankByName[key] {
        bankId = known
      } else {
        let derived = Self.bankId(forAccount: account.id)
        bankId = taken.contains(derived) ? UUID() : derived
        bankByName[key] = bankId
        banks.append(Bank(id: bankId, name: name))
      }
      assignments.append(.init(account: account.id, bank: bankId))
    }
    return BanksMigrationPlan(banks: banks, assignments: assignments, skipped: skipped)
  }
}
