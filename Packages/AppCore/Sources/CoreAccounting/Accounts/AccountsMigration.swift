import CoreKit
import Foundation

/// What the update of an older database does to its accounts, worked out before anything is
/// written. These are the only values of the older build the update changes: the flag of the
/// main account, and the account of an operation that had none.
public struct AccountsMigrationPlan: Hashable, Sendable {
  /// A new main account, when one is needed: operations without an account and no live main
  /// account to take them, or no live account at all.
  public var created: PaymentMethod?
  /// The main account afterwards; `nil` only for a database with no account and no operation.
  public var mainId: UUID?
  /// Every other account flagged main, archived ones included, in the order they were written.
  public var clearDefault: [UUID]
  /// Where the operations without an account go; `nil` when there are none.
  public var assignUnassignedTo: UUID?

  public init(
    created: PaymentMethod? = nil, mainId: UUID? = nil, clearDefault: [UUID] = [],
    assignUnassignedTo: UUID? = nil
  ) {
    self.created = created
    self.mainId = mainId
    self.clearDefault = clearDefault
    self.assignUnassignedTo = assignUnassignedTo
  }
}

/// One account as the database holds it, before the update: what the choice of the main
/// account needs, and `rowid` — the order the rows were written in, which settles a tie.
public struct MigratingAccount: Hashable, Sendable {
  public var id: UUID
  public var name: String
  public var archived: Bool
  public var isDefault: Bool
  public var rowid: Int64
  /// Its money counts in the summary: it is in no group, or in one kept in the summary. The
  /// main account's money always counts, so it is never chosen out of the summary while an
  /// account in it can be. An older database has no groups: every account is in the summary.
  public var inSummary: Bool

  public init(
    id: UUID, name: String, archived: Bool, isDefault: Bool, rowid: Int64,
    inSummary: Bool = true
  ) {
    self.id = id
    self.name = name
    self.archived = archived
    self.isDefault = isDefault
    self.rowid = rowid
    self.inSummary = inSummary
  }
}

/// Exactly one live account is main («Основной счёт»), and every operation has an account.
/// An older build kept neither for sure: it could leave two accounts flagged main, an archived
/// one flagged, or none, and an operation could have no account at all.
///
/// The main account is the first rule that holds:
/// 1. the one live account flagged main;
/// 2. of several live accounts flagged main, the most used (live operations), and of equally
///    used ones the one written first;
/// 3. with none flagged, when every operation has an account: the most used live account, the
///    one written first on a tie — no operation moves, so the setup of the accounts can still
///    make another one main freely;
/// 4. with none flagged and operations without an account, or with no live account while
///    accounts or operations exist: a new account «Основной счёт» in rubles. The operations
///    that had no account then sit on an account of their own, which the setup lists like any
///    other: the owner keeps it, renames it or merges it into the one he picks, and nothing is
///    mixed into a card by guess;
/// 5. otherwise — no account and no operation — none: the setup of the accounts makes it.
public enum AccountsMigration {
  public static func plan(
    accounts: [MigratingAccount], liveOperations: [UUID: Int], unassigned: Int,
    operations: Int, mainAccountName: String, makeId: () -> UUID
  ) -> AccountsMigrationPlan {
    let live = accounts.filter { !$0.archived }
    let flagged = live.filter(\.isDefault)
    var result = AccountsMigrationPlan()
    if let chosen = mostUsed(flagged, liveOperations) {
      result.mainId = chosen.id
    } else if unassigned == 0, let chosen = mostUsed(live, liveOperations) {
      result.mainId = chosen.id
    } else if unassigned > 0 || operations > 0 || !accounts.isEmpty {
      let created = PaymentMethod(
        id: makeId(), name: mainAccountName, kind: .account, currency: .rub, isDefault: true)
      result.created = created
      result.mainId = created.id
    }
    result.clearDefault = inWrittenOrder(accounts)
      .filter { $0.isDefault && $0.id != result.mainId }
      .map(\.id)
    if unassigned > 0 { result.assignUnassignedTo = result.mainId }
    return result
  }

  /// The same choice on every open, without making an account: two accounts flagged main
  /// after a crash, an archived one still flagged, or none. `nil` when the flag is where it
  /// belongs, or when no live account exists — the setup of the accounts makes the first one.
  ///
  /// The choice is made among the live accounts in the summary when there are any: the money
  /// of the main account always counts in «Всего», so a main account left in a group kept out
  /// of the summary hands the flag on to the most used account in it. With every live account
  /// out of the summary there is no better place, and the flag stays.
  public static func repair(
    accounts: [MigratingAccount], liveOperations: [UUID: Int]
  ) -> (mainId: UUID, clear: [UUID])? {
    let live = accounts.filter { !$0.archived }
    let counted = live.filter(\.inSummary)
    let candidates = counted.isEmpty ? live : counted
    guard
      let chosen = mostUsed(candidates.filter(\.isDefault), liveOperations)
        ?? mostUsed(candidates, liveOperations)
    else { return nil }
    let clear = inWrittenOrder(accounts).filter { $0.isDefault && $0.id != chosen.id }.map(\.id)
    guard !chosen.isDefault || !clear.isEmpty else { return nil }
    return (chosen.id, clear)
  }

  /// The account with the most live operations; of equals, the one written first.
  private static func mostUsed(
    _ accounts: [MigratingAccount], _ liveOperations: [UUID: Int]
  ) -> MigratingAccount? {
    inWrittenOrder(accounts).max { lhs, rhs in
      let left = liveOperations[lhs.id] ?? 0
      let right = liveOperations[rhs.id] ?? 0
      // Of equal counts the row written later ranks lower, so the one written first wins.
      return left != right ? left < right : lhs.rowid > rhs.rowid
    }
  }

  private static func inWrittenOrder(_ accounts: [MigratingAccount]) -> [MigratingAccount] {
    accounts.sorted { $0.rowid < $1.rowid }
  }
}
