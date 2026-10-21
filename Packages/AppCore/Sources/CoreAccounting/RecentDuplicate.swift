import CoreKit
import Foundation

/// «Такая же операция уже записана»: a new expense or income that repeats what the owner wrote
/// down moments ago — a double press, or the same receipt entered twice — is shown to them
/// before it is added, and added only when they say so.
public enum RecentDuplicate {
  /// How long ago an operation was written for a new one to repeat it, in seconds.
  public static let window: TimeInterval = 5 * 60

  /// The operation a new `draft` repeats among `recent`: of the same kind — an expense or an
  /// income, nothing else is asked —, with the same amount in the same currency, written (by
  /// `created_at`, whatever date it carries) within `window` before `now`, and by the owner's own
  /// hand: what the app writes by itself — the fee of a transfer, the difference of a count —
  /// carries an external id and is never a repeat. «Провести» of a planned payment carries one
  /// too, but it is the owner's record of money paid, and a repeat like any other. The latest
  /// one when there are several. Nil for a zero amount.
  public static func match(
    of draft: TransactionDraft, among recent: [TransactionEntry], now: Date
  ) -> TransactionEntry? {
    guard draft.kind == .expense || draft.kind == .income, !draft.amount.isZero else { return nil }
    let earliest = now.addingTimeInterval(-window)
    return recent.filter { entry in
      let written = entry.transaction
      return written.deletedAt == nil && isTheOwnersOwn(written) && written.kind == draft.kind
        && written.amountE4 == draft.amount && written.currency == draft.currency
        && written.createdAt >= earliest
    }.max { $0.transaction.createdAt < $1.transaction.createdAt }
  }

  /// Written by the owner: no external id, or the link of a planned payment marked as paid.
  private static func isTheOwnersOwn(_ transaction: Transaction) -> Bool {
    guard let externalId = transaction.externalId else { return true }
    if case .scheduled = OperationLink(externalId: externalId) { return true }
    return false
  }
}
