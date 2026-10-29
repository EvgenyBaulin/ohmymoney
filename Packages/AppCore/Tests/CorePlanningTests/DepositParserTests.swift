import CoreKit
import Foundation
import Testing

@testable import CorePlanning

@Suite("The banki.ru switch, the merge with the built-in list and the daily cache")
struct DepositParserTests {
  let today = DateOnly(year: 2026, month: 10, day: 29)

  @Test func theParserIsOffByDefault() {
    #expect(DepositParserSetting.key == "deposits.parserEnabled")
    #expect(!DepositParserSetting.isEnabled(from: nil))
    #expect(!DepositParserSetting.isEnabled(from: "0"))
    #expect(!DepositParserSetting.isEnabled(from: "bogus"))
    #expect(DepositParserSetting.isEnabled(from: DepositParserSetting.stored(true)))
  }

  @Test func aPageThatIsNotTheListGivesNothing() {
    let parser = BankiRuDepositParser()
    #expect(parser.parse(Data(), on: today).isEmpty)
    #expect(parser.parse(Data("<html><script>challenge()</script></html>".utf8), on: today).isEmpty)
  }

  @Test func aReadLineBecomesAnEntryAndABadOneIsSkipped() throws {
    let entry = try #require(
      BankiRuDepositParser.entry(bank: " Банк А ", rateText: "14,25", on: today))
    #expect(entry.ratePercent == Decimal(string: "14.25"))
    #expect(entry.origin == .bankiRu)
    #expect(entry.rateOn == today)
    #expect(BankiRuDepositParser.entry(bank: "", rateText: "14", on: today) == nil)
    #expect(BankiRuDepositParser.entry(bank: "А", rateText: "abc", on: today) == nil)
    #expect(BankiRuDepositParser.entry(bank: "А", rateText: "0", on: today) == nil)
    #expect(BankiRuDepositParser.entry(bank: "А", rateText: "140", on: today) == nil)
  }

  @Test func fetchedEntriesReplaceTheirBankAndKeepTheOthers() throws {
    let fetched = [try #require(BankiRuDepositParser.entry(bank: "ВТБ", rateText: "15", on: today))]
    let list = DepositShowcase.entries(fetched: fetched)
    #expect(list.filter { $0.bankName == "ВТБ" }.map(\.origin) == [.bankiRu])
    #expect(list.contains { $0.bankName == "Сбербанк" && $0.origin == .builtIn })
  }

  @Test func withoutFetchedEntriesTheBuiltInListIsUnchanged() {
    #expect(
      DepositShowcase.entries().count
        == DepositShowcase.entries(fetched: []).count)
    #expect(DepositShowcase.entries().count == DepositShowcaseData.entries.count)
  }

  @Test func ownOffersStayBesideFetchedOnes() throws {
    let fetched = [try #require(BankiRuDepositParser.entry(bank: "ВТБ", rateText: "15", on: today))]
    let own = DepositOffer(bankName: "Мой банк", ratePercent: Decimal(12), rateOn: today)
    let list = DepositShowcase.entries(fetched: fetched, own: [own])
    #expect(list.contains { $0.bankName == "Мой банк" })
    #expect(list.contains { $0.origin == .bankiRu })
  }

  @Test func theCacheAsksOncePerDay() {
    #expect(DepositFetchCache.isDue(nil, today: today))
    let cache = DepositFetchCache(day: today, entries: [])
    #expect(!DepositFetchCache.isDue(cache, today: today))
    #expect(DepositFetchCache.isDue(cache, today: today.adding(days: 1)))
  }

  @Test func raiffeisenHasNoDepositsInTheBuiltInList() {
    #expect(!DepositShowcaseData.entries.contains { $0.bankName.contains("Райффайзен") })
    #expect(DepositShowcaseData.entries.contains { $0.id == "psb" && $0.ratePercent == nil })
  }

  @Test func aCacheSurvivesStorage() throws {
    let entry = try #require(BankiRuDepositParser.entry(bank: "ВТБ", rateText: "15", on: today))
    let cache = DepositFetchCache(day: today, entries: [entry])
    let back = try JSONDecoder().decode(
      DepositFetchCache.self, from: try JSONEncoder().encode(cache))
    #expect(back == cache)
  }
}
