import Foundation

/// One SQL migration read from `Schema/`. The file name is the migration identifier,
/// so the same files drive the macOS app, the tests and the future Windows port.
public struct SchemaMigration: Hashable, Sendable {
  public let name: String
  public let sql: String

  public init(name: String, sql: String) {
    self.name = name
    self.sql = sql
  }
}

/// Where migrations come from: the application bundle in the app, the checked-out
/// `Schema/` directory in tests.
public protocol SchemaSource: Sendable {
  func migrations() throws -> [SchemaMigration]
}

/// AES-256-GCM for the optional archive password. The core owns the format, the platform
/// owns the primitive, so `AppCore` stays free of Apple frameworks.
public protocol ArchiveCipher: Sendable {
  /// Returns ciphertext followed by the 16-byte authentication tag.
  func seal(plaintext: Data, key: Data, nonce: Data) throws -> Data
  /// Takes ciphertext followed by the tag and returns the plaintext.
  func open(sealed: Data, key: Data, nonce: Data) throws -> Data
}

/// Rates for one day, as published by the Bank of Russia.
public struct RateSnapshot: Hashable, Sendable {
  public let date: DateOnly
  public let rates: [CurrencyCode: Rate]
  public let source: RateSource

  public init(date: DateOnly, rates: [CurrencyCode: Rate], source: RateSource) {
    self.date = date
    self.rates = rates
    self.source = source
  }
}

/// Network access for rates lives in the app layer; the core only parses and applies.
public protocol RatesFetching: Sendable {
  func dailyRates(on day: DateOnly) async throws -> RateSnapshot
}

/// Deterministic randomness for the synthetic data generator and for tests.
public protocol RandomSource {
  mutating func nextUInt64() -> UInt64
}
