import CoreKit
import Foundation

/// The rate of cash in a foreign currency: what spending it cost in rubles is what the owner
/// paid for the currency, not the rate of the Bank of Russia of the day and not a bank debit
/// (there is none). Several purchases of the currency give the weighted average.
public enum CashRate {
  /// One purchase of the currency: what came in and the rubles that went out for it.
  public struct Purchase: Hashable, Sendable {
    public var foreign: AmountE4
    public var rubles: AmountE4

    public init(foreign: AmountE4, rubles: AmountE4) {
      self.foreign = foreign
      self.rubles = rubles
    }
  }

  /// The purchases of `currency` that came to the cash account `accountId`: transfers into it in
  /// that currency from an account in rubles. An exchange from another foreign currency has no
  /// price in rubles of its own and is left out.
  public static func purchases(
    transfers: [Transfer], accountId: UUID, currency: CurrencyCode
  ) -> [Purchase] {
    transfers.compactMap { transfer in
      guard transfer.toAccountId == accountId, transfer.toCurrency == currency,
        transfer.fromCurrency == .rub, transfer.toAmountE4.raw > 0, transfer.fromAmountE4.raw > 0
      else { return nil }
      return Purchase(foreign: transfer.toAmountE4, rubles: transfer.fromAmountE4)
    }
  }

  /// Rubles per unit: Σ rubles ÷ Σ currency; `nil` with no purchase.
  public static func average(_ purchases: [Purchase]) -> Decimal? {
    let foreign = AmountE4.sum(purchases.map(\.foreign))
    guard foreign.raw > 0 else { return nil }
    return AmountE4.sum(purchases.map(\.rubles)).decimal / foreign.decimal
  }

  /// What spending `amount` of the currency costs at `rate`, one rounding; `nil` when the rate is
  /// not known (no purchase: the rate of the day takes over, as for any other account).
  public static func rubles(for amount: AmountE4, at rate: Decimal?) -> AmountE4? {
    guard let rate else { return nil }
    return try? AmountE4(decimal: amount.decimal * rate)
  }

  /// The rate spending cash of `account` in `currency` is priced at: the weighted average of
  /// what was paid for the currency, or `nil` for an account that is not cash, a currency that
  /// is rubles, and an account with no purchase on record (the rate of the day takes over).
  public static func rate(
    spendingFrom account: PaymentMethod, in currency: CurrencyCode, transfers: [Transfer]
  ) -> Decimal? {
    guard account.kind == .cash, currency != .rub else { return nil }
    return average(purchases(transfers: transfers, accountId: account.id, currency: currency))
  }
}
