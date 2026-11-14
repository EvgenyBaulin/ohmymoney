import AppCore
import Foundation

/// Reads the table of the key rate of the Bank of Russia, and only when the owner switched the
/// open sources on (`deposits.parserEnabled`). The same rules as every client here: one GET of a
/// public address, an ephemeral session without cookies, ten seconds, nothing of the owner in the
/// request. At most one request a day; the result of the last attempt, failed or not, is kept
/// with its day.
public struct KeyRateClient: Sendable {
  public static let pageURL = URL(string: "https://www.cbr.ru/hd_base/KeyRate/")!

  typealias Fetch = @Sendable (_ url: URL) async throws -> Data

  private let fetch: Fetch
  private let parser: KeyRatePageParser

  public init(session: URLSession = BankiRuClient.makeSession()) {
    self.init(
      fetch: { url in try await BankiRuClient.download(url, session: session) },
      parser: KeyRatePageParser())
  }

  /// With the network replaced, for tests.
  init(fetch: @escaping Fetch, parser: KeyRatePageParser = KeyRatePageParser()) {
    self.fetch = fetch
    self.parser = parser
  }

  /// The days the rate changed that the page lists; empty when it could not be reached or read.
  public func changes() async -> [KeyRateChange] {
    guard let data = try? await fetch(Self.pageURL) else { return [] }
    return parser.parse(data)
  }
}

public struct KeyRateService: Sendable {
  public static let cacheKey = "deposits.keyRateCache"

  private let client: KeyRateClient
  private let defaults: DepositRateService.UserDefaultsBox

  public init(client: KeyRateClient = KeyRateClient(), defaults: UserDefaults = .standard) {
    self.client = client
    self.defaults = DepositRateService.UserDefaultsBox(value: defaults)
  }

  /// The cache as stored, if any.
  public func cached() -> KeyRateCache? {
    defaults.value.data(forKey: Self.cacheKey)
      .flatMap { try? JSONDecoder().decode(KeyRateCache.self, from: $0) }
  }

  /// The table the app carries with the rows of the last read laid over it; with the sources off
  /// there is no read, and it is the built-in table.
  public func table() -> KeyRateTable {
    KeyRateTable.builtIn.merged(with: cached()?.changes ?? [])
  }

  /// Asks the page when the cache is not of `today`, and gives the table.
  public func load(today: DateOnly) async -> KeyRateTable {
    if KeyRateCache.isDue(cached(), today: today) {
      let fresh = KeyRateCache(day: today, changes: await client.changes())
      if let data = try? JSONEncoder().encode(fresh) {
        defaults.value.set(data, forKey: Self.cacheKey)
      }
      AppLog.info(
        "keyrate.cbr", .rates, "the key rate of the Bank of Russia was asked",
        [LogPair("rows", .count(fresh.changes.count))])
    }
    return table()
  }

  /// The sources are off: what was read is forgotten, the built-in table stays.
  public func forget() {
    defaults.value.removeObject(forKey: Self.cacheKey)
  }
}
