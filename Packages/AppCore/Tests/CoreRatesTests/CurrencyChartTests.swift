import CoreKit
import Foundation
import Testing

@testable import CoreRates

@Suite("График валюты")
struct CurrencyChartTests {
  private let today = DateOnly(year: 2026, month: 10, day: 7)

  @Test func theDaysOfEachPeriod() {
    let week = CurrencyChart.days(.week, today: today, calendar: .utc)
    #expect(
      week.count == 7 && week.last == today && week.first == DateOnly(year: 2026, month: 10, day: 1)
    )
    #expect(CurrencyChart.days(.month, today: today, calendar: .utc).count == 11)
    let year = CurrencyChart.days(.year, today: today, calendar: .utc)
    #expect(year.count == 13 && year.first! < DateOnly(year: 2025, month: 10, day: 20))
  }

  @Test func theRateOfAPair() {
    let usd = CurrencyPair(base: .usd, quote: .rub)
    #expect(CurrencyChart.rateE4(of: usd, basePerRub: 92.5, quotePerRub: nil) == 925_000)
    let usdEur = CurrencyPair(base: .usd, quote: .eur)
    #expect(CurrencyChart.rateE4(of: usdEur, basePerRub: 90, quotePerRub: 100) == 9_000)
    #expect(CurrencyChart.rateE4(of: usdEur, basePerRub: 90, quotePerRub: nil) == nil)
  }

  @Test func theChangeOverThePeriod() {
    let points = [
      CurrencyChartPoint(day: today, rateE4: 900_000),
      CurrencyChartPoint(day: today, rateE4: 945_000),
    ]
    let summary = CurrencyChart.summary(points)
    #expect(summary?.current == 945_000 && summary?.change == 45_000 && summary?.changeBp == 500)
    #expect(CurrencyChart.summary(Array(points.prefix(1))) == nil)
  }

  @Test func thePairsOffered() {
    let pairs = CurrencyChart.pairs(
      accountCurrencies: [.rub, .usd, CurrencyCode("KZT")], defaultCurrency: .rub)
    #expect(pairs.map(\.description) == ["USD/RUB", "EUR/RUB", "KZT/RUB"])
  }

  @Test func theChoiceIsKept() {
    let (pair, period) = CurrencyChart.decode(
      CurrencyChart.encode(CurrencyPair(base: .eur, quote: .rub), .year))
    #expect(pair.description == "EUR/RUB" && period == .year)
    #expect(CurrencyChart.decode(nil).0.description == "USD/RUB")
    #expect(CurrencyChart.decode("junk").1 == .month)
  }

  /// The accounts' currencies come against the default currency and the ruble, each pair once,
  /// after USD/RUB and EUR/RUB; a pair of one currency is never offered.
  @Test func thePairsOfAnotherDefaultCurrency() {
    let pairs = CurrencyChart.pairs(
      accountCurrencies: [.eur, CurrencyCode("KZT"), .eur], defaultCurrency: .eur)
    #expect(pairs.map(\.description) == ["USD/RUB", "EUR/RUB", "KZT/EUR", "KZT/RUB"])
    #expect(pairs.allSatisfy { $0.base != $0.quote })
  }

  /// The points are read from the rates the app keeps, day by day: a day a side has no rate of
  /// has no point, the ruble is never asked, and a pair of two foreign currencies is their ratio.
  @Test func thePointsOfThePeriod() async {
    let days = CurrencyChart.days(.week, today: today, calendar: .utc)
    let asked = Asked()
    let usdRub = await CurrencyChart.points(
      of: CurrencyPair(base: .usd, quote: .rub), on: days
    ) { currency, day in
      await asked.add(currency)
      return day == days[2] ? nil : 90 + Decimal(day.day)
    }
    #expect(usdRub?.count == days.count - 1)
    #expect(usdRub?.map(\.day) == days.filter { $0 != days[2] })
    #expect(usdRub?.last == CurrencyChartPoint(day: today, rateE4: 970_000))
    #expect(await asked.currencies == [.usd])

    let usdEur = await CurrencyChart.points(
      of: CurrencyPair(base: .usd, quote: .eur), on: [today]
    ) { currency, _ in currency == .usd ? 90 : 100 }
    #expect(usdEur == [CurrencyChartPoint(day: today, rateE4: 9_000)])
  }

  @Test func aStoredChoiceOfAPairOfOneCurrencyFallsBack() {
    #expect(CurrencyPair("USD/USD") == nil)
    #expect(CurrencyChart.decode("USD/USD|week").0.description == "USD/RUB")
    #expect(CurrencyChart.decode("kzt/rub|week").0.description == "KZT/RUB")
    #expect(CurrencyChart.decode("kzt/rub|week").1 == .week)
  }
}

/// The currencies a fake bank was asked about.
private actor Asked {
  private(set) var currencies: Set<CurrencyCode> = []
  func add(_ currency: CurrencyCode) { currencies.insert(currency) }
}
