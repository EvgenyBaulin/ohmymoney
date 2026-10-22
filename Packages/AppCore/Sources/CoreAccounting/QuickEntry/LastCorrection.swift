import CoreKit
import Foundation

/// Which operation «ой, 350» corrects: the last one the owner wrote,
/// by the time it was written, not by its date.
public enum CorrectionTarget: Hashable, Sendable {
  /// Written less than an hour ago: «Кофе: 250 → 350. Исправить?».
  case recent(TransactionEntry)
  /// Written longer ago: the owner is asked first — «Последняя записана вчера — исправить её?»
  case stale(TransactionEntry)
  /// Nothing the owner wrote is there to correct.
  case none

  /// A correction right after the slip is meant; later it may be about another operation.
  public static let freshness: TimeInterval = 3_600

  /// Operations of the owner's own hand only: what a plan, a reconciliation, an import or a
  /// distribution of income wrote is not what «ой» means. Deleted ones are not there.
  public static func isTyped(_ entry: TransactionEntry) -> Bool {
    let transaction = entry.transaction
    guard !transaction.isDeleted, transaction.importBatchId == nil else { return false }
    if let key = transaction.externalId, !key.isEmpty { return false }
    return true
  }

  public static func find(in entries: [TransactionEntry], now: Date) -> CorrectionTarget {
    let last = entries.filter(isTyped).max { left, right in
      if left.transaction.createdAt != right.transaction.createdAt {
        return left.transaction.createdAt < right.transaction.createdAt
      }
      return left.id.uuidString < right.id.uuidString
    }
    guard let last else { return .none }
    let age = now.timeIntervalSince(last.transaction.createdAt)
    return age < freshness ? .recent(last) : .stale(last)
  }
}

/// An operation written again with another amount.
public enum CorrectedAmount {
  public enum Refusal: Error, Hashable, Sendable {
    /// The new amount is not above zero or does not fit.
    case notAnAmount
    /// The correction names another currency: that is a different operation, for the panel.
    case otherCurrency
    /// The operation is in a foreign currency and has no rate to price the new amount by.
    case noRate
    /// The account moved another currency than the purchase, and the bank's figure for the
    /// new amount is not known — it is never estimated.
    case accountAmountUnknown
    /// A payment on a debt or a purchase on credit: its amount moves a debt, which the debt's
    /// own screen changes.
    case debtOperation
    /// Money back from a person: its amount settled parts, which only deleting it undoes.
    case moneyBack
    /// A part is a refund, or was paid for somebody else and is already returned or written
    /// off: the links to it were worked out from its amount.
    case settledParts
    /// Something leans on a part — a refund or money back — so its amount cannot move quietly.
    /// The caller names such parts in `leaned`.
    case partsLeanedOn
  }

  /// The entry with the amount `amount` in place of the old one. A split operation keeps the
  /// proportions of its parts; the parts always add up to the total. The rubles follow the
  /// rate the operation has (a rate typed by hand stays as typed), and so does a charge in
  /// rubles on its account. Nothing else is touched.
  ///
  /// Only plain operations are corrected this way. A debt payment, a purchase on credit, money
  /// back, a refund, and a part settled or leaned on by a refund or a reimbursement are refused;
  /// the owner changes those in the panel, where the full checks of an edit run. `leaned` holds
  /// the parts something leans on, as the refund index and the reimbursement links know them.
  public static func apply(
    _ entry: TransactionEntry, amount: Decimal, currency: CurrencyCode? = nil,
    expression: String? = nil, leaned: Set<UUID> = [], now: Date
  ) -> Result<TransactionEntry, Refusal> {
    guard let new = try? AmountE4(decimal: amount), new > .zero, new <= AmountE4.inputLimit else {
      return .failure(.notAnAmount)
    }
    var result = entry
    let old = entry.transaction
    if old.debtId != nil || old.creditDebtId != nil { return .failure(.debtOperation) }
    if old.kind == .reimbursement { return .failure(.moneyBack) }
    if entry.parts.contains(where: {
      $0.refundOfPartId != nil
        || ($0.reimbursable && ($0.reimbursementStatus ?? .expected) != .expected)
    }) {
      return .failure(.settledParts)
    }
    if entry.parts.contains(where: { leaned.contains($0.id) }) {
      return .failure(.partsLeanedOn)
    }
    if let currency, currency != old.currency { return .failure(.otherCurrency) }
    let oldWeights = entry.parts.map(\.amountE4)
    let shares = new.allocated(proportionallyTo: oldWeights, outOf: old.amountE4)
    guard !shares.isEmpty, shares.allSatisfy({ $0 > .zero }) else { return .failure(.notAnAmount) }

    let rubles: AmountE4
    if old.currency == .rub {
      rubles = new
    } else {
      guard let rate = old.rate ?? PurchaseRate.costRate(of: old),
        let priced = try? AmountE4(decimal: new.decimal * rate)
      else { return .failure(.noRate) }
      rubles = priced
    }
    result.transaction.amountE4 = new
    result.transaction.amountExpr = expression
    result.transaction.amountRubE4 = rubles
    let rubleShares = rubles.allocated(proportionallyTo: shares, outOf: new)
    for index in result.parts.indices {
      result.parts[index].amountE4 = shares[index]
      result.parts[index].amountRubE4 = rubleShares[index]
    }
    if let accountCurrency = old.accountCurrency {
      if accountCurrency == old.currency {
        result.transaction.accountAmountE4 = new
      } else if accountCurrency == .rub {
        result.transaction.accountAmountE4 = rubles
      } else {
        return .failure(.accountAmountUnknown)
      }
    }
    result.transaction.updatedAt = now
    return .success(result)
  }
}
