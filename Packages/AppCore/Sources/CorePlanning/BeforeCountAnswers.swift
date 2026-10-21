import CoreAccounting
import CoreKit
import Foundation

/// The answers «Больше не спрашивать для этой сверки» keeps, by reconciliation. An operation is
/// asked about every count of its day in turn, so an answer holds while its reconciliation is a
/// count made on the latest counted day of some balance it counted; once every such balance is
/// counted on a later day, the answer has nothing left to answer.
public enum BeforeCountAnswers {
  /// The answers whose reconciliation is a count of the latest counted day of some balance —
  /// the day of that balance's latest count, in the balances' own calendar; the others, and ids
  /// that are no count at all, go.
  public static func pruned(_ answers: [UUID: Bool], balances: AccountBalances) -> [UUID: Bool] {
    guard !answers.isEmpty else { return [:] }
    let kept = keptReconciliations(balances: balances)
    return answers.filter { kept.contains($0.key) }
  }

  /// Whether an answer for `reconciliation` would be kept (`pruned`): only then is «Больше не
  /// спрашивать для этой сверки» offered with its question — a count of an earlier day than
  /// its balances' latest is asked about again whatever is ticked.
  public static func keeps(_ reconciliation: UUID, balances: AccountBalances) -> Bool {
    keptReconciliations(balances: balances).contains(reconciliation)
  }

  /// The reconciliations an answer is kept for: every count made on the latest counted day of
  /// some balance.
  public static func keptReconciliations(balances: AccountBalances) -> Set<UUID> {
    var kept = Set<UUID>()
    for key in balances.keys {
      guard let latest = balances.latestAnchor(key) else { continue }
      let day = balances.day(of: latest.at)
      for anchor in balances.anchors(key) where balances.day(of: anchor.at) == day {
        kept.insert(anchor.balance.reconciliationId)
      }
    }
    return kept
  }
}
