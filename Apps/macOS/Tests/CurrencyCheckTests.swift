import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// «При первом запуске сверить список с ежедневными курсами ЦБ и сообщить, если какой-то
/// валюты нет», against a fake bank.
@MainActor
final class CurrencyCheckTests: XCTestCase {
  /// Friday 18 September 2026 in Moscow.
  private let today = DateOnly(year: 2026, month: 9, day: 18)
  private var environment: AppEnvironment!
  private var directory: URL!
  private var dataDirectoryBefore: String?

  /// Publishes the given currencies for the day asked, or fails; keeps every day asked.
  private actor FakeBank: RatesFetching {
    private(set) var requests: [String] = []
    var published: [CurrencyCode]
    var reachable: Bool

    init(published: [CurrencyCode], reachable: Bool = true) {
      self.published = published
      self.reachable = reachable
    }

    func open(publishing currencies: [CurrencyCode]) {
      published = currencies
      reachable = true
    }

    func dailyRates(on day: DateOnly) async throws -> RateSnapshot {
      requests.append(day.iso)
      guard reachable else { throw URLError(.notConnectedToInternet) }
      var rates: [CurrencyCode: Rate] = [:]
      for currency in published {
        rates[currency] = Rate(date: day, currency: currency, rubPerUnit: 10)
      }
      return RateSnapshot(date: day, rates: rates, source: .cbr)
    }
  }

  override func setUp() async throws {
    dataDirectoryBefore = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-currencies-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    setenv("OHMYMONEY_DATA_DIR", directory.path, 1)
    environment = AppEnvironment()
    await environment.start(preparing: {
      try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    })
  }

  override func tearDown() async throws {
    if let environment { await environment.close() }
    if let dataDirectoryBefore {
      setenv("OHMYMONEY_DATA_DIR", dataDirectoryBefore, 1)
    } else {
      unsetenv("OHMYMONEY_DATA_DIR")
    }
    if let directory { try? FileManager.default.removeItem(at: directory) }
  }

  private func service(_ bank: FakeBank) throws -> RateService {
    let today = self.today
    return RateService(
      repository: try XCTUnwrap(environment.rates), client: bank, calendar: .utc,
      policy: .init(retryDelay: .milliseconds(1), budget: .seconds(20)), today: { today })
  }

  private var everyDefaultButGEL: [CurrencyCode] {
    CurrencyCode.defaultEnabled.filter { $0 != .rub && $0.code != "GEL" }
  }

  private var checked: String? {
    try? environment.settings?.string(CurrencyCheck.doneKey)
  }

  /// The first launch asks the bank for today once and names the enabled currency its table
  /// lacks; a later launch asks nothing and says nothing.
  func testTheFirstLaunchAsksTheBankOnceAndNamesWhatItsTableLacks() async throws {
    let bank = FakeBank(published: everyDefaultButGEL)
    let service = try service(bank)

    await CurrencyCheck.runOnce(environment, service: service, today: today)

    let asked = await bank.requests
    XCTAssertEqual(asked, ["2026-09-18"], "the daily table of the first launch was not asked for")
    XCTAssertEqual(environment.currenciesMissingAtBank.map(\.code), ["GEL"])
    XCTAssertEqual(checked, "2026-09-18", "the check is not remembered")

    environment.currenciesMissingAtBank = []
    await CurrencyCheck.runOnce(environment, service: service, today: today)
    let again = await bank.requests
    XCTAssertEqual(again.count, 1, "a later launch asked the bank again")
    XCTAssertEqual(environment.currenciesMissingAtBank, [], "a later launch said it again")
  }

  /// A first launch without the network knows nothing: it says nothing, and the next launch
  /// asks again rather than taking the silence for a list that is fine.
  func testABankOutOfReachLeavesTheCheckToTheNextLaunch() async throws {
    let bank = FakeBank(published: everyDefaultButGEL, reachable: false)
    let service = try service(bank)

    await CurrencyCheck.runOnce(environment, service: service, today: today)
    XCTAssertEqual(environment.currenciesMissingAtBank, [])
    XCTAssertNil(checked, "a check that reached nobody counted as done")

    await bank.open(publishing: everyDefaultButGEL)
    await CurrencyCheck.runOnce(environment, service: service, today: today)
    let asked = await bank.requests
    XCTAssertEqual(asked.last, "2026-09-18")
    XCTAssertEqual(environment.currenciesMissingAtBank.map(\.code), ["GEL"])
  }

  /// A table the cache held from a month ago is not the daily one: with the bank out of reach
  /// the check waits for the next launch instead of comparing against it.
  func testATableOfAMonthAgoIsNotTheDailyOne() async throws {
    let old = DateOnly(year: 2026, month: 8, day: 14)
    try XCTUnwrap(environment.rates).save(
      everyDefaultButGEL.map { Rate(date: old, currency: $0, rubPerUnit: 10) })
    let bank = FakeBank(published: [], reachable: false)

    await CurrencyCheck.runOnce(environment, service: try service(bank), today: today)

    XCTAssertEqual(environment.currenciesMissingAtBank, [])
    XCTAssertNil(checked)
  }

  /// Nothing but the ruble enabled: nothing to compare, and nothing asked.
  func testTheRubleAloneAsksNothing() async throws {
    try XCTUnwrap(environment.settings).setEnabledCurrencies([.rub])
    let bank = FakeBank(published: everyDefaultButGEL)

    await CurrencyCheck.runOnce(environment, service: try service(bank), today: today)

    let asked = await bank.requests
    XCTAssertEqual(asked, [])
    XCTAssertEqual(environment.currenciesMissingAtBank, [])
    XCTAssertNotNil(checked)
  }

  /// The mark in Settings → Currencies reads the latest table of the bank, not every code the
  /// cache ever held: a currency the bank carried in August and no longer does is marked.
  func testTheCurrenciesTabMarksWhatTheLatestTableLacks() {
    let august = DateOnly(year: 2026, month: 8, day: 14)
    let gel = CurrencyCode("GEL")
    let rates = [
      Rate(date: august, currency: .usd, rubPerUnit: 80),
      Rate(date: august, currency: gel, rubPerUnit: 30),
      Rate(date: today, currency: .usd, rubPerUnit: 81),
    ]
    XCTAssertEqual(CurrencyCheck.notPublished([.rub, .usd, gel], in: rates), [gel])
    XCTAssertEqual(CurrencyCheck.notPublished([.rub, .usd, gel], in: []), [], "nothing known")
  }
}
