import CoreKit
import Foundation

/// Reads the answer of CoinGecko's public `simple/price` request for rubles:
/// `{"bitcoin":{"rub":6512345.12},"ethereum":{"rub":310000}}`.
///
/// Prices are read as the exact text the document carried, never through floating point. A coin
/// without a price, or with one that is not positive, is left out; a document that is not a JSON
/// object is an error.
public enum CoinGeckoParser {
  public static func parse(_ data: Data) throws -> [String: Decimal] {
    guard let root = try RawJSON.parse(data).objectValue else {
      throw CoreError.malformedExpression(position: 0)
    }
    var prices: [String: Decimal] = [:]
    for (coin, entry) in root {
      guard let price = entry.objectValue?["rub"]?.decimalValue, price > 0 else { continue }
      prices[coin] = price
    }
    return prices
  }

  /// A coin id as CoinGecko writes it: lower-case letters, digits and hyphens, up to 64 of them.
  /// Anything else is never put into a request.
  public static func isValidCoinId(_ id: String) -> Bool {
    guard (1...64).contains(id.count) else { return false }
    return id.utf8.allSatisfy {
      ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 45
    }
  }
}

/// What a currency of the owner's own gets from a network source, and when.
public enum CryptoRates {
  /// The coins to ask about: every live currency whose rate comes from the network and that has
  /// a valid coin id, once each, in a stable order. Nothing at all when the source is switched
  /// to manual.
  public static func coinIds(for currencies: [CustomCurrency], networkEnabled: Bool) -> [String] {
    guard networkEnabled else { return [] }
    let ids = currencies.filter {
      !$0.archived && $0.rateSource == .coingecko
    }.compactMap { $0.coinId }.filter(CoinGeckoParser.isValidCoinId)
    return Array(Set(ids)).sorted()
  }

  /// The rates a set of prices gives for `day`. A currency whose coin has no price gets none, and
  /// one that already has a rate typed by hand for `day` (`protectedToday`) is left alone: a rate
  /// the owner typed is never overwritten. The rate is stored as a network one (`coingecko`), not a manual
  /// one, so the next price of the day replaces it.
  public static func rates(
    prices: [String: Decimal], currencies: [CustomCurrency], day: DateOnly,
    protectedToday: Set<CurrencyCode> = [], fetchedAt: Date
  ) -> [Rate] {
    currencies.compactMap { currency in
      guard !currency.archived, currency.rateSource == .coingecko, let id = currency.coinId,
        let price = prices[id], !protectedToday.contains(currency.code)
      else { return nil }
      return Rate(
        date: day, currency: currency.code, rubPerUnit: price, nominal: 1,
        source: networkMark, fetchedAt: fetchedAt)
    }
    .sorted { $0.currency.code < $1.currency.code }
  }

  /// The mark a network price is stored under in the table of rates.
  public static let networkMark: RateSource = .coingecko
}
