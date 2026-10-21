import Foundation

/// What a list shows beside an amount in another currency than the default one: grey «≈ 1,240 ₽»
/// at the bank's rate of the operation's day — with «курс от 05.10» when the rate is of an
/// earlier day or provisional —, or the exact amount once the rate was typed or the account was
/// charged in the default currency. Display only: nothing stored changes.
public enum ApproximateAmount: Hashable, Sendable {
  /// At the bank's rate; `rateDay` when it is not the operation's own day's.
  case approximate(AmountE4, CurrencyCode, rateDay: DateOnly?)
  /// The rate is the owner's, or the account was charged in the default currency.
  case exact(AmountE4, CurrencyCode)

  /// `day` — the operation's day; `rubPerUnitOfDefault` — rubles for one unit of the default
  /// currency, needed only when it is not the ruble.
  public static func of(
    _ transaction: Transaction, day: DateOnly, defaultCurrency: CurrencyCode,
    rubPerUnitOfDefault: Decimal? = nil
  ) -> ApproximateAmount? {
    guard transaction.currency != defaultCurrency, !transaction.isDeleted else { return nil }
    if transaction.accountCurrency == defaultCurrency, let charged = transaction.accountAmountE4 {
      return .exact(charged, defaultCurrency)
    }
    guard transaction.rate != nil, transaction.amountRubE4.raw != 0 else { return nil }
    let amount: AmountE4
    if defaultCurrency == .rub {
      amount = transaction.amountRubE4
    } else {
      guard let perUnit = rubPerUnitOfDefault, perUnit > 0,
        let converted = try? AmountE4(
          decimal: DecimalMath.round(transaction.amountRubE4.decimal / perUnit, scale: 4))
      else { return nil }
      amount = converted
    }
    if transaction.rateSource?.isProtected == true { return .exact(amount, defaultCurrency) }
    let stale = transaction.rateProvisional || (transaction.rateDate.map { $0 != day } ?? false)
    return .approximate(amount, defaultCurrency, rateDay: stale ? transaction.rateDate : nil)
  }
}
