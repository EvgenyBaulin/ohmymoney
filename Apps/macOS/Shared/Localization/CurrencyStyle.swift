import AppCore
import Foundation

/// How an amount names its currency (Settings → Appearance → «Валюта»): «1,250 ₽», «1,250 RUB»
/// or «1,250 руб.».
///
/// A habit of this Mac, like the size of the text: kept in `UserDefaults` (`app.currencyStyle`),
/// never in the archive. It changes only what the interface writes through `MoneyFormatter`;
/// CSV, reports on disk and the fields where an amount is typed stay as they are.
public enum CurrencyStyle: String, CaseIterable, Sendable {
  /// «1,250 ₽» — the default, as the app always wrote it.
  case symbol
  /// «1,250 RUB».
  case code
  /// «1,250 руб.»: the short Russian name. Only Russian has these words; in English the name
  /// is the code.
  case name

  /// The key of `UserDefaults`; this Mac only.
  public static let key = "app.currencyStyle"

  public var settingsKey: String { "settings.appearance.currencyStyle.\(rawValue)" }

  /// What stands after the number of an amount in `currency`.
  public func unit(for currency: CurrencyCode, russian: Bool) -> String {
    switch self {
    case .symbol: Self.symbol(for: currency)
    case .code: currency.code
    case .name: russian ? Self.russianNames[currency.code] ?? currency.code : currency.code
    }
  }

  /// The sign a currency is known by; its code where it has none the app knows.
  public static func symbol(for currency: CurrencyCode) -> String {
    switch currency.code {
    case "RUB": "₽"
    case "USD": "$"
    case "EUR": "€"
    case "KZT": "₸"
    case "CNY": "¥"
    case "TRY": "₺"
    case "GEL": "₾"
    case "AMD": "֏"
    case "THB": "฿"
    default: currency.code
    }
  }

  /// The short Russian names, as a receipt or a bank statement writes them. A currency missing
  /// here is written by its code.
  public static let russianNames: [String: String] = [
    "RUB": "руб.",
    "USD": "долл.",
    "EUR": "евро",
    "GBP": "ф.\u{00A0}ст.",
    "JPY": "иен",
    "CHF": "шв.\u{00A0}фр.",
    "CNY": "юан.",
    "KZT": "тенге",
    "TRY": "лир",
    "GEL": "лари",
    "AMD": "драм",
    "THB": "бат",
    "AED": "дирх.",
    "PLN": "зл.",
    "UAH": "грн.",
    "BYN": "бел.\u{00A0}руб.",
    "KGS": "сом",
    "UZS": "сум",
    "AZN": "ман.",
    "RSD": "дин.",
  ]

  /// The style kept in `defaults`; the default for nothing or a word this build does not know.
  public static func stored(in defaults: UserDefaults?) -> CurrencyStyle {
    defaults?.string(forKey: key).flatMap(CurrencyStyle.init(rawValue:)) ?? .symbol
  }
}
