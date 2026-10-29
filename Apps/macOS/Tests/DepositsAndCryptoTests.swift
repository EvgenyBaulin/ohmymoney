import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// The showcase of deposits, the line when a deposit ends, the rates of coins from the network,
/// and the dividends and coupons: what the app does with the core's rules, in both languages.
@MainActor
final class DepositsAndCryptoTests: XCTestCase {
  private let today = DateOnly(year: 2026, month: 10, day: 28)

  private func environment(_ choice: AppLanguage.Choice) -> AppEnvironment {
    let environment = AppEnvironment()
    environment.language.choice = choice
    return environment
  }

  private func stack() throws -> DatabaseStack {
    try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
  }

  // MARK: - Words

  func testEveryKeyIsInBothLanguages() {
    for choice in [AppLanguage.Choice.russian, .english] {
      let environment = environment(choice)
      for key in DepositText.keys {
        XCTAssertNotEqual(DepositText.t(key, environment), key, "\(choice) \(key)")
      }
      XCTAssertNotEqual(
        environment.language(WorthALookNoteText.Action.openDeposits.key, table: "Overview"),
        WorthALookNoteText.Action.openDeposits.key)
    }
  }

  func testAnEntryWithoutARateSaysToAskTheBank() {
    let entry = DepositShowcaseEntry(id: "x", bankName: "ПСБ", rateOn: today)
    XCTAssertEqual(DepositText.rate(entry, environment(.russian)), "Уточните на сайте банка")
    XCTAssertEqual(DepositText.rate(entry, environment(.english)), "Check the bank's website")
    XCTAssertEqual(DepositText.rateDate(entry, today: today, environment(.russian)), "")
  }

  func testAMaximumRateAndAnOldRateAreSaidInWords() {
    let old = DepositShowcaseEntry(
      id: "x", bankName: "Т-Банк", ratePercent: Decimal(string: "12.3"), rateIsMaximum: true,
      rateOn: DateOnly(year: 2026, month: 9, day: 1))
    XCTAssertEqual(DepositText.rate(old, environment(.russian)), "до 12.3 %")
    XCTAssertEqual(DepositText.rate(old, environment(.english)), "up to 12.3%")
    XCTAssertTrue(
      DepositText.rateDate(old, today: today, environment(.russian)).contains("могла измениться"))
    XCTAssertTrue(
      DepositText.rateDate(old, today: today, environment(.english)).contains("may have changed"))
    let fresh = DepositShowcaseEntry(
      id: "y", bankName: "ВТБ", ratePercent: 14, rateOn: DateOnly(year: 2026, month: 10, day: 20))
    XCTAssertFalse(
      DepositText.rateDate(fresh, today: today, environment(.english)).contains("changed"))
  }

  func testTheLineWhenADepositEndsHasThreeConditionsAndTheDisclaimer() {
    let account = PaymentMethod(
      name: "Вклад", kind: .account,
      interest: DepositTerms(
        rate: 15, period: .atEnd, openedOn: DateOnly(year: 2026, month: 5, day: 3),
        endsOn: DateOnly(year: 2026, month: 11, day: 3)))
    let advice = DepositEndAdvisor.advice(
      accounts: [account], balanceE4: { _ in AmountE4(whole: 500_000) },
      entries: DepositShowcase.entries(filter: .none), today: today)
    XCTAssertEqual(advice.count, 1)
    for choice in [AppLanguage.Choice.russian, .english] {
      let text = DepositText.endsLine(
        advice[0], accounts: [account.id: "Вклад"], environment(choice))
      XCTAssertEqual(text.split(separator: "\n").count, 4, text)
      XCTAssertFalse(text.contains("%1$"), text)
      XCTAssertTrue(
        text.contains(choice == .russian ? "не финансовая консультация" : "not financial advice"),
        text)
    }
  }

  func testPayoutTagsAndCalendarTitles() {
    let plan = CalendarPlan(
      kind: .income, sourceId: UUID(), day: today, name: "Акции", amount: AmountE4(whole: 100),
      currency: .rub, payoutKind: .dividend)
    XCTAssertEqual(CalendarText.title(of: plan, environment(.russian)), "Акции · дивиденды")
    XCTAssertEqual(CalendarText.title(of: plan, environment(.english)), "Акции · dividends")
    var coupon = plan
    coupon.payoutKind = .coupon
    XCTAssertEqual(CalendarText.title(of: coupon, environment(.russian)), "Акции · купон")
    var plain = plan
    plain.payoutKind = nil
    XCTAssertEqual(CalendarText.title(of: plain, environment(.russian)), "Акции")
  }

  // MARK: - Stored

  func testTheOwnersOffersAndPayoutsComeBackFromTheDatabase() async throws {
    let stack = try stack()
    let offers = DepositOfferRepository(writer: stack.writer)
    let offer = DepositOffer(
      bankName: "Мой банк", ratePercent: Decimal(string: "15.5")!, termMonths: 6,
      minAmountE4: AmountE4(whole: 10_000), topup: true, rateOn: today)
    try offers.save(offer)
    let loaded = try await DatasetRepository(writer: stack.writer).load(version: 0)
    XCTAssertEqual(loaded.depositOffers, [offer])
    XCTAssertEqual(loaded.depositOffers.first?.ratePercent, Decimal(string: "15.5"))

    let planning = PlanningRepository(writer: stack.writer)
    let shares = Asset(name: "Акции", kind: .investment)
    _ = try planning.apply(PlanningChange(upsert: PlanningRows(assets: [shares])))
    let income = ExpectedIncome(
      name: "Дивиденды", totalE4: AmountE4(whole: 5_000), dueDate: today,
      payoutKind: .dividend, assetId: shares.id)
    _ = try planning.apply(PlanningChange(upsert: PlanningRows(expected: [income])))
    let after = try await DatasetRepository(writer: stack.writer).load(version: 1)
    let stored = try XCTUnwrap(after.planning.expected.first { $0.id == income.id })
    XCTAssertEqual(stored.payoutKind, .dividend)
    XCTAssertEqual(stored.assetId, shares.id)
  }

  // MARK: - Coins from the network

  private final class Bank: @unchecked Sendable, CryptoRatesFetching {
    private let lock = NSLock()
    private var asked: [[String]] = []
    var answer: Result<[String: Decimal], any Error>
    init(_ answer: Result<[String: Decimal], any Error>) { self.answer = answer }
    var requests: [[String]] { lock.withLock { asked } }
    func rubPrices(coinIds: [String]) async throws -> [String: Decimal] {
      lock.withLock { asked.append(coinIds) }
      return try answer.get()
    }
  }

  private func service(
    _ stack: DatabaseStack, bank: Bank, now: @escaping @Sendable () -> Date = { Date() }
  ) -> CryptoRateService {
    struct Ticking: CoreKit.Clock {
      let read: @Sendable () -> Date
      var now: Date { read() }
    }
    let today = self.today
    return CryptoRateService(
      rates: RateRepository(writer: stack.writer),
      currencies: CurrencyRepository(writer: stack.writer),
      settings: SettingsRepository(writer: stack.writer), client: bank, today: { today },
      clock: Ticking(read: now))
  }

  private func coin(_ stack: DatabaseStack, source: CustomRateSource? = .coingecko) throws {
    let planning = PlanningRepository(writer: stack.writer)
    _ = try planning.apply(
      PlanningChange(
        upsert: PlanningRows(customCurrencies: [
          CustomCurrency(
            code: CurrencyCode("BTC"), name: "Bitcoin", fractionDigits: 4, rateSource: source,
            coinId: "bitcoin")
        ])))
  }

  func testThePriceBecomesTodaysRateOfTheCoinByDefault() async throws {
    let stack = try stack()
    try coin(stack)
    let bank = Bank(.success(["bitcoin": 6_500_000]))
    let stored = await service(stack, bank: bank).refresh()
    XCTAssertEqual(stored, 1)
    XCTAssertEqual(bank.requests, [["bitcoin"]])
    let rate = try RateRepository(writer: stack.writer).rate(for: CurrencyCode("BTC"), on: today)
    XCTAssertEqual(rate?.perUnit, 6_500_000)
    XCTAssertEqual(rate?.date, today)
  }

  func testAManualSourceNeverAsksTheNetwork() async throws {
    let stack = try stack()
    try coin(stack)
    try SettingsRepository(writer: stack.writer).set(CryptoRateSetting.key, to: "manual")
    let bank = Bank(.success(["bitcoin": 1]))
    let stored = await service(stack, bank: bank).refresh()
    XCTAssertEqual(stored, 0)
    XCTAssertTrue(bank.requests.isEmpty)
  }

  func testACurrencyTypedByHandIsNotAsked() async throws {
    let stack = try stack()
    try coin(stack, source: nil)
    let bank = Bank(.success(["bitcoin": 1]))
    _ = await service(stack, bank: bank).refresh()
    XCTAssertTrue(bank.requests.isEmpty)
  }

  func testARateTypedForTodayIsNeverOverwritten() async throws {
    let stack = try stack()
    try coin(stack)
    let rates = RateRepository(writer: stack.writer)
    try rates.save([
      Rate(date: today, currency: CurrencyCode("BTC"), rubPerUnit: 7_000_000, source: .manual)
    ])
    let bank = Bank(.success(["bitcoin": 6_500_000]))
    let stored = await service(stack, bank: bank).refresh()
    XCTAssertEqual(stored, 0)
    XCTAssertEqual(try rates.rate(for: CurrencyCode("BTC"), on: today)?.perUnit, 7_000_000)
  }

  func testWithoutANetworkTheLastRateStaysAndNothingIsThrown() async throws {
    let stack = try stack()
    try coin(stack)
    let rates = RateRepository(writer: stack.writer)
    let earlier = DateOnly(year: 2026, month: 10, day: 20)
    try rates.save([
      Rate(
        date: earlier, currency: CurrencyCode("BTC"), rubPerUnit: 6_000_000,
        source: CryptoRates.networkMark)
    ])
    let bank = Bank(.failure(RateFetchError.unavailable(status: nil)))
    let stored = await service(stack, bank: bank).refresh()
    XCTAssertEqual(stored, 0)
    let table = try rates.table()
    XCTAssertEqual(table.rate(for: CurrencyCode("BTC"), on: today)?.date, earlier)
    XCTAssertEqual(table.resolve(CurrencyCode("BTC"), on: today)?.isProvisional, false)
  }

  func testTheNetworkIsAskedOnceInAWhile() async throws {
    let stack = try stack()
    try coin(stack)
    let bank = Bank(.success(["bitcoin": 6_500_000]))
    let clock = Locked(Date(timeIntervalSince1970: 1_800_000_000))
    let service = service(stack, bank: bank, now: { clock.value })
    _ = await service.refresh()
    clock.value = clock.value.addingTimeInterval(60)
    _ = await service.refresh()
    XCTAssertEqual(bank.requests.count, 1)
    clock.value = clock.value.addingTimeInterval(1_000)
    _ = await service.refresh()
    XCTAssertEqual(bank.requests.count, 2)
  }

  private final class Locked: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Date
    init(_ date: Date) { stored = date }
    var value: Date {
      get { lock.withLock { stored } }
      set { lock.withLock { stored = newValue } }
    }
  }

  private final class Log: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    func add(_ item: String) { lock.withLock { stored.append(item) } }
    var items: [String] { lock.withLock { stored } }
  }

  func testTheRequestCarriesOnlyCoinIdsAndRubles() async throws {
    let log = Log()
    let client = CoinGeckoClient(fetch: { ids in
      log.add(ids)
      return Data(#"{"bitcoin":{"rub":6500000.5},"ethereum":{"rub":300000}}"#.utf8)
    })
    let prices = try await client.rubPrices(coinIds: ["bitcoin", "ethereum", "BAD ID&x=1"])
    XCTAssertEqual(log.items, ["bitcoin,ethereum"])
    XCTAssertEqual(prices["bitcoin"], Decimal(string: "6500000.5"))
    let url = CoinGeckoClient.url(ids: "bitcoin,ethereum").absoluteString
    XCTAssertEqual(
      url, "https://api.coingecko.com/api/v3/simple/price?ids=bitcoin,ethereum&vs_currencies=rub")
    let empty = try await client.rubPrices(coinIds: ["BAD ID"])
    XCTAssertTrue(empty.isEmpty)
    XCTAssertEqual(log.items.count, 1)
  }

  func testTheEditorRefusesABadCoinIdOnlyForANetworkSource() {
    func refusal(_ source: CustomRateSource, _ coin: String) -> String? {
      CustomCurrencyEditor.refusal(
        code: "BTC", name: "Bitcoin", symbol: "", digits: 4, rateText: "", previous: nil,
        existing: [], source: source, coinId: coin)
    }
    XCTAssertEqual(refusal(.coingecko, "Bit Coin"), "crypto.coin.refusal")
    XCTAssertEqual(refusal(.coingecko, ""), "crypto.coin.refusal")
    XCTAssertNil(refusal(.coingecko, "bitcoin"))
    XCTAssertNil(refusal(.manual, "anything at all"))
  }
}
