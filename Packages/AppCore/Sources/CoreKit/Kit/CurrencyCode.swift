import Foundation

/// ISO 4217 code. Stored uppercase; comparisons are case-insensitive by construction.
public struct CurrencyCode: Hashable, Sendable, Codable, CustomStringConvertible {
  public let code: String

  public init(_ code: String) {
    self.code = code.uppercased()
  }

  public var description: String { code }

  public static let rub = CurrencyCode("RUB")
  public static let usd = CurrencyCode("USD")
  public static let eur = CurrencyCode("EUR")

  /// The ten currencies enabled on a fresh install.
  public static let defaultEnabled: [CurrencyCode] = [
    .rub, .usd, .eur,
    CurrencyCode("KZT"), CurrencyCode("CNY"), CurrencyCode("TRY"),
    CurrencyCode("AED"), CurrencyCode("GEL"), CurrencyCode("AMD"), CurrencyCode("THB"),
  ]

  /// The old limit of the enabled currencies. The storage no longer holds anyone to it — any
  /// number may be on —; it stays only until the screens that still count against it let go.
  public static let maxEnabled = 10

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    self.init(try container.decode(String.self))
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(code)
  }
}

/// Amount together with its currency. Conversion to rubles always goes through a `Rate`.
public struct Money: Hashable, Sendable, Codable {
  public var amount: AmountE4
  public var currency: CurrencyCode

  public init(amount: AmountE4, currency: CurrencyCode) {
    self.amount = amount
    self.currency = currency
  }

  public init(decimal: Decimal, currency: CurrencyCode) throws {
    self.amount = try AmountE4(decimal: decimal)
    self.currency = currency
  }

  public static func rubles(_ decimal: Decimal) throws -> Money {
    try Money(decimal: decimal, currency: .rub)
  }

  public var isZero: Bool { amount.isZero }
}
