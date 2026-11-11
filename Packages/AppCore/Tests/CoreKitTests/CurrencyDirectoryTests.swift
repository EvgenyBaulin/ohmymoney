import Foundation
import Testing

@testable import CoreKit

@Suite("The directory of currencies")
struct CurrencyDirectoryTests {
  let tether = CustomCurrency(
    code: CurrencyCode("UST"), name: "Tether", symbol: "₮", fractionDigits: 4, sort: 0)
  let bonus = CustomCurrency(code: CurrencyCode("BON"), name: "Бонусы", sort: 1)
  var catalog: CurrencyCatalog { CurrencyCatalog(custom: [tether, bonus]) }

  @Test func aFlagIsTwoRegionalIndicators() {
    #expect(CurrencyDirectory.flag(forRegion: "KZ") == "🇰🇿")
    #expect(CurrencyDirectory.flag(forRegion: "us") == "🇺🇸")
    #expect(CurrencyDirectory.flag(forRegion: "USA") == nil)
    #expect(CurrencyDirectory.flag(forRegion: "1Z") == nil)
  }

  @Test func theRegionIsReadFromTheCodeWithItsExceptions() {
    #expect(CurrencyDirectory.region(of: CurrencyCode("KZT")) == "KZ")
    #expect(CurrencyDirectory.region(of: .usd) == "US")
    #expect(CurrencyDirectory.region(of: .eur) == "EU")
    #expect(CurrencyDirectory.region(of: CurrencyCode("XDR")) == nil)
    #expect(CurrencyDirectory.region(of: CurrencyCode("XOF")) == nil)
    // BTC is no ISO currency: «BT» (Bhutan) is not its country.
    #expect(CurrencyDirectory.region(of: CurrencyCode("BTC")) == nil)
  }

  @Test func aBankCurrencyHasFlagCountryAndFullNameInTheLanguage() {
    let tenge = CurrencyDirectory.entry(for: CurrencyCode("KZT"), language: "ru")
    #expect(tenge.flag == "🇰🇿")
    #expect(tenge.country == "Казахстан")
    #expect(tenge.name == "Казахстанский тенге")
    let dollar = CurrencyDirectory.entry(for: .usd, language: "ru")
    #expect(dollar.name == "Доллар США")
    #expect(dollar.country == "США")
    let euro = CurrencyDirectory.entry(for: .eur, language: "ru")
    #expect(euro.flag == "🇪🇺")
    #expect(euro.country == "Еврозона")
    #expect(euro.name == "Евро")
    let english = CurrencyDirectory.entry(for: CurrencyCode("KZT"), language: "en")
    #expect(english.name == "Kazakhstani Tenge")
    #expect(english.country == "Kazakhstan")
  }

  @Test func aCustomCurrencyKeepsTheOwnersWordsAndHasNoFlag() {
    let coin = CurrencyDirectory.entry(for: tether.code, catalog: catalog, language: "ru")
    #expect(coin.flag == nil)
    #expect(coin.country == nil)
    #expect(coin.isCustom)
    #expect(coin.name == "Tether")
    #expect(coin.badge == "₮")
    let points = CurrencyDirectory.entry(for: bonus.code, catalog: catalog, language: "en")
    #expect(points.name == "Бонусы")
    #expect(points.badge == "Б")
  }

  @Test func theSearchFindsByCountryCodeAndNameInEitherLanguage() {
    let codes = [CurrencyCode("KZT"), .usd, .eur, tether.code, bonus.code]
    func found(_ query: String, _ language: String = "ru") -> [String] {
      CurrencyDirectory.filter(codes, query: query, catalog: catalog, language: language)
        .map(\.code)
    }
    #expect(found("Казахстан") == ["KZT"])
    #expect(found("казах") == ["KZT"])
    #expect(found("dollar") == ["USD"])
    #expect(found("сша") == ["USD"])
    #expect(found("eur") == ["EUR"])
    #expect(found("tether") == ["UST"])
    #expect(found("₮") == ["UST"])
    #expect(found("бонус") == ["BON"])
    #expect(found("тенге", "en") == ["KZT"])
    #expect(found("  ") == codes.map(\.code))
    #expect(found("нет такой").isEmpty)
  }

  @Test func theLatestRateIsOfTheLatestDayAndAHandRateWinsADay() throws {
    let day1 = try #require(DateOnly(iso: "2026-11-01"))
    let day3 = try #require(DateOnly(iso: "2026-11-03"))
    let rates = [
      Rate(date: day1, currency: .usd, rubPerUnit: 90, source: .cbr),
      Rate(date: day3, currency: .usd, rubPerUnit: 94, source: .cbr),
      Rate(date: day3, currency: .usd, rubPerUnit: 95, source: .manual),
      Rate(date: day3, currency: .eur, rubPerUnit: 100, source: .cbr),
    ]
    let latest = CurrencyRateInfo.latest(for: .usd, in: rates)
    #expect(latest?.rubPerUnit == 95)
    #expect(latest?.source == .manual)
    #expect(CurrencyRateInfo.latest(for: CurrencyCode("KZT"), in: rates) == nil)
    #expect(CurrencyRateInfo.origin(of: .cbrMirror) == .bank)
    #expect(CurrencyRateInfo.origin(of: .coingecko) == .network)
  }

  @Test func theListIsTheEnabledOnesUntilAskedForMore() {
    let kzt = CurrencyCode("KZT")
    let gel = CurrencyCode("GEL")
    let offered: [CurrencyCode] = [.usd, .eur, kzt, gel]
    func list(_ query: String = "", all: Bool = false) -> [String] {
      CurrencyDirectory.listed(
        enabled: [.rub, .usd, kzt], offered: offered, catalog: catalog, query: query,
        showsAll: all, language: "ru"
      ).map(\.code)
    }
    #expect(list() == ["USD", "KZT", "UST", "BON"])
    #expect(list(all: true) == ["RUB", "USD", "EUR", "KZT", "GEL", "UST", "BON"])
    // A search reaches the currencies that are off, and the ruble.
    #expect(list("грузия") == ["GEL"])
    #expect(list("россия") == ["RUB"])
    #expect(list("тенге") == ["KZT"])
  }
}
