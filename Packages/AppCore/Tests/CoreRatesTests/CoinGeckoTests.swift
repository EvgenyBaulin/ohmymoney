import CoreKit
import Foundation
import Testing

@testable import CoreRates

@Suite("CoinGecko prices become rates of the owner's own currencies")
struct CoinGeckoTests {
  let day = DateOnly(year: 2026, month: 10, day: 28)
  let now = Date(timeIntervalSince1970: 1_800_000_000)

  func coin(
    _ code: String, id: String?, source: CustomRateSource? = .coingecko, archived: Bool = false
  )
    -> CustomCurrency
  {
    CustomCurrency(
      code: CurrencyCode(code), name: code, fractionDigits: 4, archived: archived,
      rateSource: source, coinId: id)
  }

  @Test func theDocumentIsReadExactlyAndOddCoinsAreLeftOut() throws {
    let data = try Fixture.data("coingecko_simple_price", "json")
    let prices = try CoinGeckoParser.parse(data)
    #expect(prices["bitcoin"] == Decimal(string: "6512345.12"))
    #expect(prices["ethereum"] == 310000)
    #expect(prices["dogecoin"] == Decimal(string: "0.0123"))
    #expect(prices["broken"] == nil)
    #expect(prices["zero"] == nil)
  }

  @Test func aDocumentThatIsNotAnObjectFails() {
    #expect(throws: (any Error).self) { try CoinGeckoParser.parse(Data("[1,2]".utf8)) }
    #expect(throws: (any Error).self) { try CoinGeckoParser.parse(Data("not json".utf8)) }
  }

  @Test func coinIdsAreChecked() {
    #expect(CoinGeckoParser.isValidCoinId("bitcoin"))
    #expect(CoinGeckoParser.isValidCoinId("usd-coin"))
    #expect(!CoinGeckoParser.isValidCoinId(""))
    #expect(!CoinGeckoParser.isValidCoinId("Bitcoin"))
    #expect(!CoinGeckoParser.isValidCoinId("btc&vs=usd"))
    #expect(!CoinGeckoParser.isValidCoinId(String(repeating: "a", count: 65)))
  }

  @Test func onlyLiveNetworkCoinsAreAsked() {
    let currencies = [
      coin("BTC", id: "bitcoin"), coin("WBT", id: "bitcoin"), coin("ETH", id: "ethereum"),
      coin("OLD", id: "old-coin", archived: true), coin("HND", id: "hand", source: .manual),
      coin("NIL", id: nil), coin("BAD", id: "Bad Id"),
    ]
    #expect(CryptoRates.coinIds(for: currencies, networkEnabled: true) == ["bitcoin", "ethereum"])
    #expect(CryptoRates.coinIds(for: currencies, networkEnabled: false).isEmpty)
  }

  @Test func ratesAreStoredAsNetworkOnesAndAHandTypedRateOfTheDayStays() {
    let currencies = [coin("BTC", id: "bitcoin"), coin("ETH", id: "ethereum")]
    let prices: [String: Decimal] = ["bitcoin": 6_500_000, "ethereum": 300_000]
    let all = CryptoRates.rates(
      prices: prices, currencies: currencies, day: day, fetchedAt: now)
    #expect(all.map(\.currency.code) == ["BTC", "ETH"])
    #expect(all.allSatisfy { !$0.source.isProtected && $0.nominal == 1 && $0.date == day })
    let kept = CryptoRates.rates(
      prices: prices, currencies: currencies, day: day, protectedToday: [CurrencyCode("BTC")],
      fetchedAt: now)
    #expect(kept.map(\.currency.code) == ["ETH"])
  }

  @Test func aNetworkRateIsReplacedByTheNextOneButNeverAHandTypedOne() {
    let btc = CurrencyCode("BTC")
    let first = Rate(
      date: day, currency: btc, rubPerUnit: 6_500_000, source: CryptoRates.networkMark)
    let second = Rate(
      date: day, currency: btc, rubPerUnit: 6_600_000, source: CryptoRates.networkMark)
    let typed = Rate(date: day, currency: btc, rubPerUnit: 1, source: .manual)
    #expect(RateTable(rates: [first, second]).rate(for: btc, on: day)?.perUnit == 6_600_000)
    #expect(RateTable(rates: [typed, second]).rate(for: btc, on: day)?.perUnit == 1)
    // No network: the last rate known stays, from an earlier day, and it is never provisional.
    let later = DateOnly(year: 2026, month: 11, day: 5)
    let resolved = RateTable(rates: [first]).resolve(btc, on: later)
    #expect(resolved?.rate.date == day)
    #expect(resolved?.isProvisional == false)
  }
}

@Suite("The source of coin rates defaults to the network")
struct CryptoRateSettingTests {
  @Test func missingOrUnknownReadsAsTheDefault() {
    #expect(CryptoRateSetting.source(from: nil) == .coingecko)
    #expect(CryptoRateSetting.source(from: "bogus") == .coingecko)
    #expect(CryptoRateSetting.source(from: "manual") == .manual)
    #expect(CryptoRateSetting.source(from: "coingecko") == .coingecko)
    #expect(CryptoRateSetting.key == "crypto.rateSource")
  }
}
