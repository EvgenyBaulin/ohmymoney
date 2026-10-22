import CoreKit
import Foundation

/// «Деньги по валютам»: the money of the accounts in the summary split by currency, each in its
/// own currency and in rubles at the rate of the day. The lines add up to the «Всего» of the
/// accounts exactly — the same balances, counted once each.
public struct OverviewCurrencyBalances: Hashable, Sendable {
  public struct Line: Hashable, Sendable {
    public var currency: CurrencyCode
    /// In the currency itself.
    public var amount: AmountE4
    /// In rubles; the lines of this table are the ones with a rate.
    public var rub: AmountE4
  }

  /// The currency with the most rubles first.
  public var lines: [Line]
  /// Currencies with a counted balance but no rate today: out of the lines and the total.
  public var withoutRate: [CurrencyCode]

  public var totalRub: AmountE4 { AmountE4.sum(lines.map(\.rub)) }

  /// More than one currency holds money: the tile has something to split.
  public var isMultiCurrency: Bool { lines.filter { !$0.amount.isZero }.count > 1 }

  public init(_ accounts: AccountsSnapshot) {
    var amounts: [CurrencyCode: AmountE4] = [:]
    var rubles: [CurrencyCode: AmountE4] = [:]
    for section in accounts.sections where section.inSummary {
      for account in section.accounts {
        for key in account.keys {
          guard let balance = key.balance, let rub = key.rub else { continue }
          amounts[key.key.currency, default: .zero] += balance
          rubles[key.key.currency, default: .zero] += rub
        }
      }
    }
    lines = amounts.keys.map {
      Line(currency: $0, amount: amounts[$0] ?? .zero, rub: rubles[$0] ?? .zero)
    }
    .sorted {
      $0.rub != $1.rub ? $0.rub > $1.rub : $0.currency.code < $1.currency.code
    }
    withoutRate = accounts.inSummaryWithoutRate
  }
}
