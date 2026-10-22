import CoreKit
import Foundation

/// «Spotify стал дороже на 180 ₽: 120 ₽ — курс, 60 ₽ — цена»: a rise in the rubles a foreign
/// subscription costs, told apart into what the service did and what the exchange rate did.
///
/// With price `p` and rate `r` (rubles per unit) before and after: the service's part is
/// `(p₁ − p₀) · r₀` — the new price at the old rate —, the rate's part is `p₁ · (r₁ − r₀)`.
/// The two add up to the whole change exactly: the rate's part is what is left of the rounded
/// whole after the service's part is rounded.
public struct PriceChangeSplit: Hashable, Sendable {
  public var oldRub: AmountE4
  public var newRub: AmountE4
  /// `newRub − oldRub`; negative when the subscription got cheaper.
  public var totalRub: AmountE4
  public var servicePartRub: AmountE4
  public var ratePartRub: AmountE4
  /// «Сервис +10 %»: change of the price in its own currency, percent with one decimal;
  /// `nil` when the old price was zero.
  public var servicePercent: Decimal?
  /// «Курс +7 %»: change of the rate, percent with one decimal.
  public var ratePercent: Decimal?
}

public enum PriceChangeSplits {

  public static func split(
    oldPrice: AmountE4, newPrice: AmountE4, oldRate: Decimal, newRate: Decimal
  ) -> PriceChangeSplit? {
    guard oldRate > 0, newRate > 0 else { return nil }
    let old = SubscriptionMath.rounded(oldPrice.decimal * oldRate)
    let new = SubscriptionMath.rounded(newPrice.decimal * newRate)
    let total = new - old
    let service = SubscriptionMath.rounded((newPrice.decimal - oldPrice.decimal) * oldRate)
    return PriceChangeSplit(
      oldRub: old, newRub: new, totalRub: total, servicePartRub: service,
      ratePartRub: total - service,
      servicePercent: oldPrice.raw > 0
        ? BillingComparisons.rounded(
          (newPrice.decimal - oldPrice.decimal) / oldPrice.decimal * 100, scale: 1) : nil,
      ratePercent: BillingComparisons.rounded((newRate - oldRate) / oldRate * 100, scale: 1))
  }

  /// The split for a payment between two days: its price on each (`SubscriptionMath.price`) at
  /// the rate of each (`DayRates`). `nil` for a payment in rubles, without a rate on either
  /// day, or when `from` is not before `to`.
  public static func split(
    payment: ScheduledPayment, prices: [SubscriptionPrice], rates: DayRates, from: DateOnly,
    to: DateOnly
  ) -> PriceChangeSplit? {
    guard payment.currency != .rub, from < to,
      let oldRate = rates.perUnit(payment.currency, on: from),
      let newRate = rates.perUnit(payment.currency, on: to)
    else { return nil }
    return split(
      oldPrice: SubscriptionMath.price(of: payment, on: from, prices: prices),
      newPrice: SubscriptionMath.price(of: payment, on: to, prices: prices),
      oldRate: oldRate, newRate: newRate)
  }
}
