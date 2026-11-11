import CoreKit
import Foundation

/// A service instalment schedule: its price is spent at purchase, its commission at payments.
public enum SplitPurchase {
  public enum Interval: String, CaseIterable, Sendable { case twoWeeks, month }
  public enum Issue: Error, Equatable {
    case invalidCount, invalidPayment, invalidDates, belowPrice
  }

  public static func schedule(
    payment: AmountE4, count: Int, first: DateOnly, every: Interval
  ) throws -> [SplitPayment] {
    guard (2...120).contains(count) else { throw Issue.invalidCount }
    guard payment.raw > 0 else { throw Issue.invalidPayment }
    return (0..<count).map { index in
      let day =
        every == .twoWeeks
        ? first.adding(days: index * 14)
        : first.adding(months: index)
      return SplitPayment(day: day, amountE4: payment)
    }
  }

  /// The schedule must cover the purchase. No fee or principal is invented to fill a shortfall.
  public static func markup(price: AmountE4, payments: [SplitPayment]) throws -> AmountE4 {
    guard (2...120).contains(payments.count) else { throw Issue.invalidCount }
    guard price.raw > 0, payments.allSatisfy({ $0.amountE4.raw > 0 }) else {
      throw Issue.invalidPayment
    }
    guard zip(payments, payments.dropFirst()).allSatisfy({ $0.day < $1.day }) else {
      throw Issue.invalidDates
    }
    let total = payments.reduce(Decimal.zero) { $0 + $1.amountE4.decimal }
    guard total >= price.decimal else { throw Issue.belowPrice }
    let totalAmount = try AmountE4(decimal: total)
    return totalAmount - price
  }
}
