import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// A custom currency — USDT, points — is written by the owner's symbol, its code or its name, in
/// every style of «Оформление → Валюта», and its rates typed by hand are never asked of the bank.
@MainActor
final class CustomCurrencyAppTests: XCTestCase {
  private let ru = Locale(identifier: "ru")
  private let en = Locale(identifier: "en")
  private let amount = AmountE4(whole: 1_250)
  private let tether = CustomCurrency(
    code: CurrencyCode("UST"), name: "Tether", symbol: "₮", fractionDigits: 4)
  private let points = CustomCurrency(code: CurrencyCode("PTS"), name: "баллы", fractionDigits: 0)
  private var catalog: CurrencyCatalog { CurrencyCatalog(custom: [tether, points]) }

  func testTheSymbolStyleWritesTheOwnersSymbolOrTheCode() {
    for locale in [ru, en] {
      let money = MoneyFormatter(locale: locale, currencyStyle: .symbol, catalog: catalog)
      XCTAssertEqual(money.exact(amount, currency: tether.code), "1,250\u{00A0}₮")
      XCTAssertEqual(money.exact(amount, currency: points.code), "1,250\u{00A0}PTS")
      XCTAssertEqual(money.rounded(amount, currency: tether.code), "1,250\u{00A0}₮")
      XCTAssertEqual(money.symbol(for: tether.code), "₮")
      XCTAssertEqual(money.symbol(for: points.code), "PTS")
      // The bank's currencies are written as before.
      XCTAssertEqual(money.exact(amount, currency: .usd), "1,250\u{00A0}$")
    }
  }

  func testTheCodeStyleWritesTheCode() {
    for locale in [ru, en] {
      let money = MoneyFormatter(locale: locale, currencyStyle: .code, catalog: catalog)
      XCTAssertEqual(money.exact(amount, currency: tether.code), "1,250\u{00A0}UST")
      XCTAssertEqual(money.exact(amount, currency: points.code), "1,250\u{00A0}PTS")
      XCTAssertEqual(money.symbol(for: tether.code), "₮")
    }
  }

  func testTheNameStyleWritesTheOwnersNameInRussianAndTheCodeInEnglish() {
    let russian = MoneyFormatter(locale: ru, currencyStyle: .name, catalog: catalog)
    XCTAssertEqual(russian.exact(amount, currency: points.code), "1,250\u{00A0}баллы")
    XCTAssertEqual(russian.exact(amount, currency: tether.code), "1,250\u{00A0}Tether")
    XCTAssertEqual(russian.exact(amount, currency: .usd), "1,250\u{00A0}долл.")
    let english = MoneyFormatter(locale: en, currencyStyle: .name, catalog: catalog)
    XCTAssertEqual(english.exact(amount, currency: points.code), "1,250\u{00A0}PTS")
  }

  func testWithoutTheCatalogACustomCodeIsWrittenAsItsCodeAndHiddenAmountsStayHidden() {
    XCTAssertEqual(
      MoneyFormatter(locale: ru).exact(amount, currency: tether.code), "1,250\u{00A0}UST")
    let hidden = MoneyFormatter(locale: ru, hidesAmounts: true, catalog: catalog)
    XCTAssertEqual(hidden.exact(amount, currency: tether.code), MoneyFormatter.mask)
  }

  /// Counts every request; answers with the dollar only.
  private actor CountingBank {
    private(set) var requests = 0
    func rates(_ day: DateOnly) -> RateSnapshot {
      requests += 1
      return RateSnapshot(
        date: day, rates: [.usd: Rate(date: day, currency: .usd, rubPerUnit: 80)], source: .cbr)
    }
  }

  func testTheBankIsNeverAskedForACustomCurrency() async throws {
    let stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    let currencies = CurrencyRepository(writer: stack.writer)
    let planning = PlanningRepository(writer: stack.writer)
    let first = DateOnly(year: 2026, month: 9, day: 10)
    _ = try planning.apply(try currencies.saving(tether, firstRate: (first, 95)))
    let bank = CountingBank()
    let today = DateOnly(year: 2026, month: 9, day: 25)
    let client = CBRClient(fetch: { _, day in await bank.rates(day) }, today: { today })
    let service = RateService(
      repository: RateRepository(writer: stack.writer), client: client, calendar: .utc,
      today: { today })
    let later = DateOnly(year: 2026, month: 9, day: 20)
    await service.refresh(day: later, currency: tether.code)
    let rate = await service.rate(for: tether.code, on: later)
    XCTAssertEqual(rate?.perUnit, 95)
    let before = await service.rate(for: tether.code, on: DateOnly(year: 2026, month: 9, day: 1))
    XCTAssertNil(before)
    let asked = await bank.requests
    XCTAssertEqual(asked, 0)
    // The dollar is asked about as always.
    _ = await service.rate(for: .usd, on: later)
    let askedForTheDollar = await bank.requests
    XCTAssertEqual(askedForTheDollar, 1)
  }
}
