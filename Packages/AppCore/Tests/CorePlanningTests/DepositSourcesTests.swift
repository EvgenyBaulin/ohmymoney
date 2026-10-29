import CoreKit
import Foundation
import Testing

@testable import CorePlanning

@Suite("Open sources of deposit rates: the Bank of Russia indicator and the comparison")
struct DepositSourcesTests {
  let today = DateOnly(year: 2026, month: 10, day: 29)

  // MARK: Bank of Russia

  @Test func theTableOfTheBankOfRussiaIsRead() throws {
    let list = CentralBankDepositParser().parse(Data(CentralBankFixture.page.utf8))
    #expect(list.count == 5)
    let latest = try #require(list.first)
    #expect(latest.ratePercent == Decimal(string: "13.055"))
    #expect(latest.decade == 2 && latest.month == 10 && latest.year == 2026)
    #expect(latest.periodStart == DateOnly(year: 2026, month: 10, day: 11))
    #expect(CentralBankDepositParser().latest(Data(CentralBankFixture.page.utf8)) == latest)
    #expect(list.last?.ratePercent == Decimal(string: "22.279"))
  }

  @Test func decadesStartOnTheFirstEleventhAndTwentyFirst() {
    #expect(
      CentralBankIndicator.start(decade: 1, month: 2, year: 2026)
        == DateOnly(year: 2026, month: 2, day: 1))
    #expect(
      CentralBankIndicator.start(decade: 3, month: 2, year: 2026)
        == DateOnly(year: 2026, month: 2, day: 21))
    #expect(CentralBankIndicator.start(decade: 4, month: 2, year: 2026) == nil)
    #expect(CentralBankIndicator.start(decade: 1, month: 13, year: 2026) == nil)
  }

  @Test func aBrokenRowIsSkippedAndNothingReadableIsEmpty() {
    let page = """
      <table class="data"><tr><th>Декада</th><th>Ставка, %</th></tr>
      <tr><td>IV.10.2026</td><td>13,0</td></tr>
      <tr><td>I.10.2026</td><td>abc</td></tr>
      <tr><td>I.10.2026</td><td>0</td></tr>
      <tr><td>I.10.2026</td><td>140</td></tr>
      <tr><td>III.09.2026</td><td>13,5</td></tr>
      <tr><td>II.09.2026</td></tr></table>
      """
    let list = CentralBankDepositParser().parse(Data(page.utf8))
    #expect(list.map(\.ratePercent) == [Decimal(string: "13.5")])
    let parser = CentralBankDepositParser()
    #expect(parser.parse(Data()).isEmpty)
    #expect(parser.parse(Data("<html>not found</html>".utf8)).isEmpty)
    #expect(parser.latest(Data("<table class=\"data\"></table>".utf8)) == nil)
  }

  @Test func theNewestDecadeWinsWhateverTheOrderOfTheRows() {
    let page = """
      <table class="data"><tr><td>I.09.2026</td><td>12,9</td></tr>
      <tr><td>II.10.2026</td><td>13,1</td></tr><tr><td>III.09.2026</td><td>13,0</td></tr></table>
      """
    #expect(
      CentralBankDepositParser().latest(Data(page.utf8))?.ratePercent == Decimal(string: "13.1"))
  }

  @Test func theIndicatorSurvivesTheCache() throws {
    let indicator = try #require(
      CentralBankDepositParser().latest(Data(CentralBankFixture.page.utf8)))
    let cache = CentralBankCache(day: today, indicator: indicator)
    let back = try JSONDecoder().decode(CentralBankCache.self, from: JSONEncoder().encode(cache))
    #expect(back == cache)
    #expect(!CentralBankCache.isDue(cache, today: today))
    #expect(CentralBankCache.isDue(cache, today: today.adding(days: 1)))
    #expect(CentralBankCache.isDue(nil, today: today))
  }

  // MARK: comparison

  private func entry(
    _ bank: String, _ rate: String?, _ origin: DepositShowcaseEntry.Origin,
    term: ClosedRange<Int>? = nil, product: String = ""
  ) -> DepositShowcaseEntry {
    DepositShowcaseEntry(
      id: "\(origin):\(bank):\(product)", origin: origin, bankName: bank, product: product,
      ratePercent: rate.flatMap { Decimal(string: $0) }, termMinMonths: term?.lowerBound,
      termMaxMonths: term?.upperBound, rateOn: today)
  }

  @Test func differentRatesOfOneBankAreFlaggedWithBothSources() throws {
    let list = [
      entry("ВТБ", "14.5", .builtIn, term: 12...12),
      entry("ВТБ", "15.2", .aggregator("example.test"), term: 12...12),
      entry("Сбербанк", "13", .builtIn),
    ]
    let found = DepositShowcase.discrepancies(list)
    let one = try #require(found["втб"])
    #expect(found.count == 1)
    #expect(one.bankName == "ВТБ")
    #expect(one.lower.ratePercent == Decimal(string: "14.5"))
    #expect(one.higher.origin == .aggregator("example.test"))
    #expect(one.difference == Decimal(string: "0.7"))
  }

  @Test func aSmallDifferenceOrTheSameSourceIsNotADiscrepancy() {
    #expect(
      DepositShowcase.discrepancies([
        entry("ВТБ", "14.5", .builtIn), entry("ВТБ", "14.6", .centralBank),
      ]).isEmpty)
    // exactly 0.1 is not "more than 0.1"
    #expect(
      DepositShowcase.discrepancies([
        entry("ВТБ", "14.5", .builtIn), entry("ВТБ", "14.6", .bankiRu),
      ]).isEmpty)
    // two products of one source are two deposits, not a disagreement
    #expect(
      DepositShowcase.discrepancies([
        entry("ВТБ", "14.5", .builtIn, product: "А"), entry("ВТБ", "17", .builtIn, product: "Б"),
      ]).isEmpty)
  }

  @Test func termsThatDoNotMeetAreNotCompared() {
    #expect(
      DepositShowcase.discrepancies([
        entry("ВТБ", "14.5", .builtIn, term: 3...6),
        entry("ВТБ", "17", .aggregator("a"), term: 12...24),
      ]).isEmpty)
    #expect(
      !DepositShowcase.discrepancies([
        entry("ВТБ", "14.5", .builtIn, term: 3...12),
        entry("ВТБ", "17", .aggregator("a"), term: 12...24),
      ]).isEmpty)
    // an unknown term does not rule the comparison out
    #expect(
      !DepositShowcase.discrepancies([
        entry("ВТБ", "14.5", .builtIn), entry("ВТБ", "17", .aggregator("a"), term: 12...24),
      ]).isEmpty)
  }

  @Test func anUnknownRateIsNeverCompared() {
    #expect(
      DepositShowcase.discrepancies([entry("ВТБ", nil, .builtIn), entry("ВТБ", "17", .bankiRu)])
        .isEmpty)
  }

  @Test func ownOffersAreComparedToo() throws {
    let own = entry("ВТБ", "16", .own(UUID()))
    let found = DepositShowcase.discrepancies([entry("ВТБ", "14", .builtIn), own])
    #expect(found["втб"]?.higher.origin == own.origin)
  }

  @Test func theBiggestGapOfABankIsTheOneReported() throws {
    let list = [
      entry("ВТБ", "14", .builtIn), entry("ВТБ", "14.5", .bankiRu),
      entry("ВТБ", "16", .aggregator("a")),
    ]
    #expect(DepositShowcase.discrepancies(list)["втб"]?.difference == Decimal(2))
  }

  @Test func originsHaveStableNamesAndSurviveStorage() throws {
    let all: [DepositShowcaseEntry.Origin] = [
      .builtIn, .bankiRu, .centralBank, .aggregator("example.test"), .own(UUID()),
    ]
    for origin in all {
      let data = try JSONEncoder().encode(origin)
      #expect(try JSONDecoder().decode(DepositShowcaseEntry.Origin.self, from: data) == origin)
    }
  }
}
