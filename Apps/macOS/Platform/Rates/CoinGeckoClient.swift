import AppCore
import Foundation

/// Reads coin prices in rubles from CoinGecko's public API, which needs no key.
///
/// The request carries nothing but the ids of the coins and the currency asked for:
/// `api.coingecko.com/api/v3/simple/price?ids=bitcoin,ethereum&vs_currencies=rub`. No identifier of
/// the owner, no amount, no account goes with it. Ten seconds per request, nothing kept on disk.
public struct CoinGeckoClient: Sendable, CryptoRatesFetching {
  /// One request: the ids joined, as they go into the address.
  typealias Fetch = @Sendable (_ ids: String) async throws -> Data

  private let fetch: Fetch

  public init(session: URLSession = CoinGeckoClient.makeSession()) {
    self.init(fetch: { ids in try await Self.download(ids, session: session) })
  }

  /// With the network replaced, for tests.
  init(fetch: @escaping Fetch) {
    self.fetch = fetch
  }

  public static func makeSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 10
    return URLSession(configuration: configuration)
  }

  public func rubPrices(coinIds: [String]) async throws -> [String: Decimal] {
    // An id that is not written the way CoinGecko writes them never reaches the address.
    let ids = coinIds.filter(CoinGeckoParser.isValidCoinId)
    guard !ids.isEmpty else { return [:] }
    return try CoinGeckoParser.parse(try await fetch(ids.joined(separator: ",")))
  }

  /// The address of a request for these (already checked) ids.
  static func url(ids: String) -> URL {
    URL(string: "https://api.coingecko.com/api/v3/simple/price?ids=\(ids)&vs_currencies=rub")!
  }

  private static func download(_ ids: String, session: URLSession) async throws -> Data {
    let (data, response) = try await session.data(from: url(ids: ids))
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
      throw RateFetchError.unavailable(status: (response as? HTTPURLResponse)?.statusCode)
    }
    return data
  }
}
