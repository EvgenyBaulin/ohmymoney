import CoreKit
import Foundation

/// The one rule of «not counted yet».
///
/// The setup of the accounts used to write a starting balance of 0 for every field left empty,
/// and a 0 the owner typed looks exactly the same in the file: a row of an `opening` that
/// counted zero and says nothing of where it came from (`Reconciliation.origin` is `nil`, since
/// such rows were written before the origin was kept). Such a row is no count in the owner's
/// sense — nobody looked at the money —, so a pair of an account and a currency that has only
/// such rows before a count has not been counted before it: that count is its first real one,
/// the starting point, never a difference. A zero written with an origin — typed in the setup,
/// given to a new account, left by a merge — is a real count.
public enum ZeroOpenings {
  /// Whether this counted balance is no count: a row of an `opening` without an origin that
  /// counted 0.
  public static func isPreOneTwoZero(
    _ balance: ReconciledBalance, of reconciliation: Reconciliation
  ) -> Bool {
    reconciliation.kind == .opening && reconciliation.origin == nil
      && balance.actualE4 == .zero
  }

  /// Whether every anchor of `key` before the count `countId`, in the order of the book, is
  /// such a row — and there is at least one. With `countId` `nil`, every anchor of the key: a
  /// new count about to be made. `false` when the key has no count `countId`.
  public static func rests(
    _ key: BalanceKey, before countId: UUID?, balances: AccountBalances,
    reconciliations: [UUID: Reconciliation]
  ) -> Bool {
    let anchors = balances.anchors(key).map(\.balance)
    let earlier: ArraySlice<ReconciledBalance>
    if let countId {
      guard let index = anchors.firstIndex(where: { $0.id == countId }) else { return false }
      earlier = anchors[..<index]
    } else {
      earlier = anchors[...]
    }
    guard !earlier.isEmpty else { return false }
    return earlier.allSatisfy { balance in
      guard let reconciliation = reconciliations[balance.reconciliationId] else { return false }
      return isPreOneTwoZero(balance, of: reconciliation)
    }
  }

  /// The compared counts of a sheet of accounts whose key rests only on such rows, less those
  /// the owner already called a real difference (`kept`): the first counts that may have
  /// recorded their whole balance as a difference. They are left exactly as they are until the
  /// owner decides.
  public static func frozenCounts(
    balances: AccountBalances, reconciliations: [Reconciliation], kept: Set<UUID>
  ) -> Set<UUID> {
    let byId = Dictionary(
      reconciliations.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    var frozen: Set<UUID> = []
    for key in balances.keys {
      for anchor in balances.anchors(key) {
        let balance = anchor.balance
        guard balance.expectedE4 != nil, !kept.contains(balance.id),
          byId[balance.reconciliationId]?.kind == .accounts,
          rests(key, before: balance.id, balances: balances, reconciliations: byId)
        else { continue }
        frozen.insert(balance.id)
      }
    }
    return frozen
  }
}
