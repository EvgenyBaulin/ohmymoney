import AppCore
import Foundation

/// Reads the public page of deposits of banki.ru, and only when the owner switched it on. The page
/// answers a program with a script challenge instead of rates and getting round that is not done,
/// so this source honestly returns nothing and the other sources carry the showcase.
///
/// One GET of a public address. No cookies, no identifier of the owner, no amount, no account goes
/// with it; an ephemeral session keeps nothing on disk; ten seconds per request. At most one
/// request a day: the result of the last attempt, failed or not, is kept with its day.
public struct BankiRuClient: Sendable {
  public static let pageURL = URL(string: "https://www.banki.ru/products/deposits/")!

  /// One request: the body of the page.
  typealias Fetch = @Sendable (_ url: URL) async throws -> Data

  private let fetch: Fetch
  private let parser: any DepositPageParsing

  public init(
    session: URLSession = BankiRuClient.makeSession(),
    parser: any DepositPageParsing = BankiRuDepositParser()
  ) {
    self.init(fetch: { url in try await Self.download(url, session: session) }, parser: parser)
  }

  /// With the network replaced, for tests.
  init(fetch: @escaping Fetch, parser: any DepositPageParsing) {
    self.fetch = fetch
    self.parser = parser
  }

  public static func makeSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 10
    configuration.httpCookieAcceptPolicy = .never
    configuration.httpShouldSetCookies = false
    configuration.urlCache = nil
    return URLSession(configuration: configuration)
  }

  /// The entries read on `day`; empty when the page could not be reached or read.
  public func entries(on day: DateOnly) async -> [DepositShowcaseEntry] {
    guard let data = try? await fetch(Self.pageURL) else { return [] }
    return parser.parse(data, on: day)
  }

  static func download(_ url: URL, session: URLSession) async throws -> Data {
    let (data, response) = try await session.data(from: url)
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
      throw RateFetchError.unavailable(status: (response as? HTTPURLResponse)?.statusCode)
    }
    return data
  }
}

/// Reads the table of the Bank of Russia with the average highest rate of the ten biggest banks,
/// and only when the owner switched the open sources on. The same rules as every client here: one
/// GET of a public address, an ephemeral session without cookies, ten seconds, nothing of the
/// owner in the request.
public struct CentralBankDepositsClient: Sendable {
  public static let pageURL = URL(string: "https://www.cbr.ru/statistics/avgprocstav/")!

  typealias Fetch = @Sendable (_ url: URL) async throws -> Data

  private let fetch: Fetch
  private let parser: CentralBankDepositParser

  public init(session: URLSession = BankiRuClient.makeSession()) {
    self.init(
      fetch: { url in try await BankiRuClient.download(url, session: session) },
      parser: CentralBankDepositParser())
  }

  /// With the network replaced, for tests.
  init(fetch: @escaping Fetch, parser: CentralBankDepositParser = CentralBankDepositParser()) {
    self.fetch = fetch
    self.parser = parser
  }

  /// The newest period of the page; `nil` when it could not be reached or read.
  public func indicator() async -> CentralBankIndicator? {
    guard let data = try? await fetch(Self.pageURL) else { return nil }
    return parser.latest(data)
  }
}

/// What the open sources gave today.
public struct DepositRates: Sendable {
  public var entries: [DepositShowcaseEntry]
  public var indicator: CentralBankIndicator?
  /// Nothing came from any source.
  public var failed: Bool { entries.isEmpty && indicator == nil }
}

/// The daily rhythm around the clients: the cached result of today is used as it is, otherwise
/// one request per source is made and its result kept (an empty one too, so a closed page is not
/// asked again the same day).
public struct DepositRateService: Sendable {
  public static let cacheKey = "deposits.bankiCache"
  public static let centralBankCacheKey = "deposits.centralBankCache"

  private let client: BankiRuClient
  private let centralBank: CentralBankDepositsClient
  private let defaults: UserDefaultsBox

  /// `UserDefaults` is thread-safe; the box only says so to the compiler.
  struct UserDefaultsBox: @unchecked Sendable { let value: UserDefaults }

  public init(
    client: BankiRuClient = BankiRuClient(),
    centralBank: CentralBankDepositsClient = CentralBankDepositsClient(),
    defaults: UserDefaults = .standard
  ) {
    self.client = client
    self.centralBank = centralBank
    self.defaults = UserDefaultsBox(value: defaults)
  }

  /// The cache of banki.ru as stored, if any.
  public func cached() -> DepositFetchCache? {
    defaults.value.data(forKey: Self.cacheKey)
      .flatMap { try? JSONDecoder().decode(DepositFetchCache.self, from: $0) }
  }

  /// The cache of the Bank of Russia as stored, if any.
  public func cachedCentralBank() -> CentralBankCache? {
    defaults.value.data(forKey: Self.centralBankCacheKey)
      .flatMap { try? JSONDecoder().decode(CentralBankCache.self, from: $0) }
  }

  /// What the sources give for `today`.
  public func load(today: DateOnly) async -> DepositRates {
    var cache = cached()
    if DepositFetchCache.isDue(cache, today: today) {
      let fresh = DepositFetchCache(day: today, entries: await client.entries(on: today))
      if let data = try? JSONEncoder().encode(fresh) {
        defaults.value.set(data, forKey: Self.cacheKey)
      }
      AppLog.info(
        "deposits.banki", .rates, "the page of deposits was asked",
        [LogPair("entries", .count(fresh.entries.count))])
      cache = fresh
    }
    var bank = cachedCentralBank()
    if CentralBankCache.isDue(bank, today: today) {
      let fresh = CentralBankCache(day: today, indicator: await centralBank.indicator())
      if let data = try? JSONEncoder().encode(fresh) {
        defaults.value.set(data, forKey: Self.centralBankCacheKey)
      }
      AppLog.info(
        "deposits.cbr", .rates, "the indicator of the Bank of Russia was asked",
        [LogPair("found", .count(fresh.indicator == nil ? 0 : 1))])
      bank = fresh
    }
    return DepositRates(entries: cache?.entries ?? [], indicator: bank?.indicator)
  }
}
