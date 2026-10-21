import CoreKit
import Foundation

extension DebtRules {
  /// A tranche of `debt`: a part of the loan drawn on `date` — a day still to come is a planned
  /// one. A tranche is spent the day it is drawn, on tuition: with its expense operation
  /// (`transactionId`, «Образование») it is a `borrowed` line naming that operation, the way a
  /// purchase on credit names its purchase (`creditPurchaseOpening`) — the operation is the
  /// expense, and neither moves money on my accounts. Without one it is an `adjustment` that only
  /// grows the debt.
  public static func tranche(
    on debt: Debt, amount: AmountE4, date: DateOnly?, transactionId: UUID?,
    entryId: UUID = UUID()
  ) throws -> DebtEntry {
    guard amount.raw > 0 else { throw DebtError.negativeAmount }
    var entry = makeEntry(
      id: entryId, debtId: debt.id, kind: transactionId == nil ? .adjustment : .borrowed,
      amountE4: amount, date: date, transactionId: transactionId)
    entry.tranche = true
    return entry
  }
}
