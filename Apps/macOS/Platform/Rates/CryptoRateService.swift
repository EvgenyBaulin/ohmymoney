import AppCore
import AppDatabase
import Foundation

/// Keeps the rates of the owner's coins up to date: once in a while (not more often than
/// `Policy.every`) it asks the network source for the price of every coin the owner's own
/// currencies name, and stores each as that currency's rate for today.
///
/// What it never does: ask when the source is switched to manual, or when no currency names a
/// coin; overwrite a rate the owner typed for today; show an error. Without a network the last
/// rate stays, with its own date, and the journal records the failure by kind.
public actor CryptoRateService {
  public struct Policy: Sendable {
    /// The least time between two requests.
    public var every: Duration = .seconds(900)

    public init(every: Duration = .seconds(900)) {
      self.every = every
    }
  }

  private let rates: RateRepository
  private let currencies: CurrencyRepository
  private let settings: SettingsRepository
  private let client: any CryptoRatesFetching
  private let policy: Policy
  private let today: @Sendable () -> DateOnly
  private let clock: any CoreKit.Clock
  private var lastAsked: Date?

  public init(
    rates: RateRepository, currencies: CurrencyRepository, settings: SettingsRepository,
    client: any CryptoRatesFetching = CoinGeckoClient(), policy: Policy = Policy(),
    today: @escaping @Sendable () -> DateOnly = { CalendarContext.moscow.day(of: Date()) },
    clock: any CoreKit.Clock = SystemClock()
  ) {
    self.rates = rates
    self.currencies = currencies
    self.settings = settings
    self.client = client
    self.policy = policy
    self.today = today
    self.clock = clock
  }

  /// Asks for the prices when the owner's settings allow it and the last request is old enough.
  /// Returns how many rates were stored. It never throws.
  @discardableResult
  public func refresh() async -> Int {
    do {
      let source = CryptoRateSetting.source(from: try settings.string(CryptoRateSetting.key))
      let owned = try currencies.customCurrencies()
      let ids = CryptoRates.coinIds(for: owned, networkEnabled: source == .coingecko)
      guard !ids.isEmpty else { return 0 }
      let now = clock.now
      if let lastAsked, Duration.seconds(now.timeIntervalSince(lastAsked)) < policy.every {
        return 0
      }
      lastAsked = now
      let prices = try await client.rubPrices(coinIds: ids)
      let day = today()
      let known = try rates.allRates()
      let typedToday = Set(
        known.filter { $0.date == day && $0.source.isProtected }.map(\.currency))
      let fresh = CryptoRates.rates(
        prices: prices, currencies: owned, day: day, protectedToday: typedToday, fetchedAt: now)
      try rates.save(fresh)
      AppLog.info(
        "rates.crypto", .rates, "prices of coins arrived",
        [LogPair("coins", .count(ids.count)), LogPair("stored", .count(fresh.count))])
      return fresh.count
    } catch {
      if error is CancellationError || Task.isCancelled { return 0 }
      AppLog.warning(
        "rates.crypto.failed", .rates, "the prices of coins were not reached",
        RateFetchError.logPairs(of: error))
      return 0
    }
  }
}
