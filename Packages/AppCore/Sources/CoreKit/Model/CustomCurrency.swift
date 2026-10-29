import Foundation

/// A currency outside the Bank of Russia list (`custom_currencies`): three capital Latin letters
/// that are not an ISO 4217 code. Its rates are typed by hand and live in `rates` with the source
/// `manual`, one per day.
public struct CustomCurrency: Identifiable, Hashable, Sendable, Codable {
  public var id: CurrencyCode { code }
  public var code: CurrencyCode
  public var name: String
  public var symbol: String?
  /// Digits after the point, 0…4.
  public var fractionDigits: Int
  public var archived: Bool
  public var sort: Int
  /// Where its rate comes from; `nil` reads as `manual`.
  public var rateSource: CustomRateSource?
  /// The id the network source knows the coin by; `nil` for a currency typed by hand.
  public var coinId: String?

  public init(
    code: CurrencyCode, name: String, symbol: String? = nil, fractionDigits: Int = 2,
    archived: Bool = false, sort: Int = 0, rateSource: CustomRateSource? = nil,
    coinId: String? = nil
  ) {
    self.rateSource = rateSource
    self.coinId = coinId
    self.code = code
    self.name = name
    self.symbol = symbol
    self.fractionDigits = fractionDigits
    self.archived = archived
    self.sort = sort
  }

  /// The digits after the point a currency may have.
  public static let fractionDigitsRange = 0...4
}

/// Where the rate of an own currency comes from (`custom_currencies.rate_source`).
public enum CustomRateSource: String, Codable, Sendable, CaseIterable {
  case manual
  case coingecko
}
