import CoreKit
import Foundation

/// The rate a purchase in another currency cost me, and the purchase written again at a rate
/// typed from the statement.
///
/// Money back for a part in dollars is weighed against what the part cost in rubles, so the
/// rate the money-back sheet lets the owner correct is the purchase's own: typing it rewrites
/// the purchase — its rubles, its parts' rubles and a ruble charge on its account — in the same
/// write as the money back. A rate that only converted the money back would either change
/// nothing or lose money: 20 $ bought at 90 (1,800 ₽) and 2,000 ₽ back leave 200 ₽ of income
/// whatever that rate said; at the purchase's corrected 88 the part is 1,760 ₽, the card was
/// charged 40 ₽ less, and 240 ₽ are income.
public enum PurchaseRate {
  /// Rubles per unit of the purchase's currency: its rubles over its amount — what a unit
  /// actually cost, whatever rate is stored. `nil` for a purchase in rubles or of nothing.
  public static func costRate(of transaction: Transaction) -> Decimal? {
    guard transaction.currency != .rub, transaction.amountE4.raw > 0,
      transaction.amountRubE4.raw > 0
    else { return nil }
    return transaction.amountRubE4.decimal / transaction.amountE4.decimal
  }

  /// The purchase at a rate typed by hand: the rate is manual and no longer provisional, dated
  /// `day`; its rubles are the amount times the rate, rounded half away from zero; each part
  /// takes its proportional share and the last the rest (`AmountE4.allocated`, the one rule of
  /// part rubles); a charge in rubles on the account follows the rubles, a charge in any other
  /// currency stays what the account was charged. A purchase in rubles comes back as it is.
  public static func repriced(
    _ entry: TransactionEntry, rate: Decimal, day: DateOnly
  ) throws -> TransactionEntry {
    let transaction = entry.transaction
    guard transaction.currency != .rub else { return entry }
    guard rate > 0 else { throw CoreError.amountOutOfRange }
    let rubles = try AmountE4(decimal: transaction.amountE4.decimal * rate)
    var repriced = entry
    repriced.transaction.rate = rate
    repriced.transaction.rateDate = day
    repriced.transaction.rateSource = .manual
    repriced.transaction.rateProvisional = false
    repriced.transaction.amountRubE4 = rubles
    if transaction.accountCurrency == .rub {
      repriced.transaction.accountAmountE4 = rubles
    }
    let shares = rubles.allocated(
      proportionallyTo: entry.parts.map(\.amountE4), outOf: transaction.amountE4)
    for index in repriced.parts.indices {
      repriced.parts[index].amountRubE4 = shares[index]
    }
    return repriced
  }

  /// The owed parts of the repriced purchase as it has them now: their rubles, and no longer
  /// provisional. Parts of other operations are as they were.
  public static func repriced(_ parts: [OwedPart], of repriced: TransactionEntry) -> [OwedPart] {
    let rubles = Dictionary(
      repriced.parts.map { ($0.id, $0.amountRubE4) }, uniquingKeysWith: { first, _ in first })
    return parts.map { part in
      guard part.transactionId == repriced.id, let now = rubles[part.partId] else { return part }
      var part = part
      part.amountRubE4 = now
      part.rateProvisional = repriced.transaction.rateProvisional
      return part
    }
  }
}
