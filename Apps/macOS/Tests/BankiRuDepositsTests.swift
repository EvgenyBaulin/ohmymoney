import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// Rates of deposits from the open sources (banki.ru and the Bank of Russia): off by default, one
/// request a day per source, a failure leaves the built-in list alone.
@MainActor
final class BankiRuDepositsTests: XCTestCase {
  private let today = DateOnly(year: 2026, month: 10, day: 29)

  private struct FixedParser: DepositPageParsing {
    let entries: [DepositShowcaseEntry]
    func parse(_ data: Data, on day: DateOnly) -> [DepositShowcaseEntry] {
      data.isEmpty ? [] : entries
    }
  }

  private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func bump() { lock.withLock { value += 1 } }
  }

  private func defaults() -> UserDefaults {
    let suite = "tests.banki.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
  }

  private func service(
    body: Data, counter: Counter, defaults: UserDefaults, fail: Bool = false,
    bank: Data = Data(), bankCounter: Counter = Counter()
  ) -> DepositRateService {
    let entry = BankiRuDepositParser.entry(bank: "ВТБ", rateText: "15", on: today)!
    let client = BankiRuClient(
      fetch: { url in
        counter.bump()
        XCTAssertEqual(url, BankiRuClient.pageURL)
        if fail { throw RateFetchError.unavailable(status: 403) }
        return body
      }, parser: FixedParser(entries: [entry]))
    let central = CentralBankDepositsClient(fetch: { url in
      bankCounter.bump()
      XCTAssertEqual(url, CentralBankDepositsClient.pageURL)
      if fail { throw RateFetchError.unavailable(status: 500) }
      return bank
    })
    return DepositRateService(client: client, centralBank: central, defaults: defaults)
  }

  private let cbrPage = Data(
    "<table class=\"data\"><tr><td>II.10.2026</td><td>13,0550</td></tr></table>".utf8)

  func testTheBankOfRussiaIndicatorIsReadAndKeptForTheDay() async throws {
    let counter = Counter()
    let bankCounter = Counter()
    let store = defaults()
    let first = await service(
      body: Data(), counter: counter, defaults: store, bank: cbrPage, bankCounter: bankCounter
    ).load(today: today)
    XCTAssertEqual(first.indicator?.ratePercent, Decimal(string: "13.055"))
    XCTAssertTrue(first.entries.isEmpty)
    XCTAssertFalse(first.failed, "the indicator alone is not a failure")
    let again = await service(
      body: Data(), counter: counter, defaults: store, bank: cbrPage, bankCounter: bankCounter
    ).load(today: today)
    XCTAssertEqual(again.indicator, first.indicator)
    XCTAssertEqual(bankCounter.count, 1)
    _ = await service(
      body: Data(), counter: counter, defaults: store, bank: cbrPage, bankCounter: bankCounter
    ).load(today: today.adding(days: 1))
    XCTAssertEqual(bankCounter.count, 2)
  }

  func testTheBankOfRussiaAddressIsOnePublicPage() {
    XCTAssertEqual(CentralBankDepositsClient.pageURL.host, "www.cbr.ru")
    XCTAssertNil(CentralBankDepositsClient.pageURL.query)
  }

  func testAnUnreadablePageOfTheBankOfRussiaIsAFailureNotRetriedTheSameDay() async {
    let bankCounter = Counter()
    let store = defaults()
    for _ in 0..<2 {
      let result = await service(
        body: Data(), counter: Counter(), defaults: store, bank: Data("<html/>".utf8),
        bankCounter: bankCounter
      ).load(today: today)
      XCTAssertNil(result.indicator)
      XCTAssertTrue(result.failed)
    }
    XCTAssertEqual(bankCounter.count, 1)
  }

  func testTheSwitchIsOffUntilTheOwnerTurnsItOn() throws {
    let stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    let settings = SettingsRepository(writer: stack.writer)
    XCTAssertFalse(
      DepositParserSetting.isEnabled(from: try settings.string(DepositParserSetting.key)))
    try settings.set(DepositParserSetting.key, to: DepositParserSetting.stored(true))
    XCTAssertTrue(
      DepositParserSetting.isEnabled(from: try settings.string(DepositParserSetting.key)))
  }

  func testTheAddressIsOnePublicPageWithNothingOfTheOwner() {
    XCTAssertEqual(BankiRuClient.pageURL.host, "www.banki.ru")
    XCTAssertNil(BankiRuClient.pageURL.query)
    let configuration = BankiRuClient.makeSession().configuration
    XCTAssertEqual(configuration.timeoutIntervalForRequest, 10)
    XCTAssertFalse(configuration.httpShouldSetCookies)
  }

  func testOneRequestADayAndTheResultIsKept() async {
    let counter = Counter()
    let store = defaults()
    let first = await service(body: Data("x".utf8), counter: counter, defaults: store)
      .load(today: today)
    XCTAssertEqual(first.entries.count, 1)
    XCTAssertFalse(first.failed)
    let second = await service(body: Data("x".utf8), counter: counter, defaults: store)
      .load(today: today)
    XCTAssertEqual(second.entries, first.entries)
    XCTAssertEqual(counter.count, 1)
    _ = await service(body: Data("x".utf8), counter: counter, defaults: store)
      .load(today: today.adding(days: 1))
    XCTAssertEqual(counter.count, 2)
  }

  func testAFailureGivesNothingAndIsNotRetriedTheSameDay() async {
    let counter = Counter()
    let store = defaults()
    let result = await service(body: Data(), counter: counter, defaults: store, fail: true)
      .load(today: today)
    XCTAssertTrue(result.entries.isEmpty)
    XCTAssertTrue(result.failed)
    _ = await service(body: Data(), counter: counter, defaults: store, fail: true)
      .load(today: today)
    XCTAssertEqual(counter.count, 1)
    XCTAssertEqual(
      DepositShowcase.entries(fetched: result.entries).count, DepositShowcaseData.entries.count)
  }

  func testAnEmptyBodyIsAFailureToo() async {
    let result = await service(body: Data(), counter: Counter(), defaults: defaults())
      .load(today: today)
    XCTAssertTrue(result.failed)
  }
}
