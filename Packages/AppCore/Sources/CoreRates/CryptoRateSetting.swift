import CoreKit
import Foundation

/// The one switch for where the rates of the owner's coins come from (`crypto.rateSource` in the
/// settings table, so it travels in the archive): `coingecko` asks the network for the currencies
/// that name a coin, `manual` never does. A key that is missing, or holds anything else, reads as
/// the default, the network.
public enum CryptoRateSetting {
  public static let key = "crypto.rateSource"
  public static let `default`: CustomRateSource = .coingecko

  public static func source(from stored: String?) -> CustomRateSource {
    stored.flatMap(CustomRateSource.init(rawValue:)) ?? `default`
  }
}
