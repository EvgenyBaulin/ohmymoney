import CoreAnalytics
import CoreKit
import Foundation

/// «Сэкономлено на скидках»: what the discounts noted on operations took off the price.
public struct DiscountSavings: Hashable, Sendable {
  public var totalRubE4: AmountE4
  /// How many operations carry a discount.
  public var count: Int
  public var byMonth: [MonthKey: AmountE4]
  public var byYear: [Int: AmountE4]
  /// What the same purchases would have cost without the discounts (paid + saved).
  public var fullPriceRubE4: AmountE4

  /// The saved share of the full price, in basis points.
  public var shareBp: Int { PurchaseMath.basisPoints(totalRubE4, of: fullPriceRubE4) }

  /// The months of `byMonth` in order.
  public var months: [MonthKey] { byMonth.keys.sorted() }
  public var years: [Int] { byYear.keys.sorted() }

  /// The discount of one operation in rubles: in the currency of the operation, converted at the
  /// operation's own rate (its rubles over its amount).
  public static func rubles(of transaction: Transaction) -> AmountE4 {
    guard let discount = transaction.discountE4, discount.raw > 0 else { return .zero }
    if transaction.currency == .rub { return discount }
    return PurchaseMath.scaled(
      discount, by: transaction.amountRubE4, over: transaction.amountE4)
  }

  /// The live expenses with a discount, by the day of the operation; `range` limits the days
  /// (`nil`: all).
  public static func summarize(
    entries: [TransactionEntry], range: DayRange? = nil, calendar: CalendarContext
  ) -> DiscountSavings {
    var total = AmountE4.zero
    var paid = AmountE4.zero
    var count = 0
    var byMonth: [MonthKey: AmountE4] = [:]
    var byYear: [Int: AmountE4] = [:]
    for entry in entries {
      let transaction = entry.transaction
      guard !transaction.isDeleted, transaction.kind == .expense else { continue }
      let saved = rubles(of: transaction)
      guard saved.raw > 0 else { continue }
      let day = calendar.day(of: transaction.occurredAt, recordedIn: transaction.timeZoneId)
      if let range, !range.contains(day) { continue }
      total += saved
      paid += transaction.amountRubE4
      count += 1
      byMonth[day.monthKey, default: .zero] += saved
      byYear[day.year, default: .zero] += saved
    }
    return DiscountSavings(
      totalRubE4: total, count: count, byMonth: byMonth, byYear: byYear,
      fullPriceRubE4: paid + total)
  }
}
