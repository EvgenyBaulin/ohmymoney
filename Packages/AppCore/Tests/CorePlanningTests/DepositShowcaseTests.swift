import CoreKit
import Foundation
import Testing

@testable import CorePlanning

@Suite("The showcase of deposits is sorted by rate and says when a rate is old")
struct DepositShowcaseTests {
  let today = DateOnly(year: 2026, month: 10, day: 28)

  func rub(_ whole: Int64) -> AmountE4 { AmountE4(raw: whole * 10_000) }

  func entry(
    _ id: String, _ rate: String?, term: ClosedRange<Int>? = nil, min: Int64? = nil,
    max: Int64? = nil, topup: Bool? = nil, on: DateOnly? = nil
  ) -> DepositShowcaseEntry {
    DepositShowcaseEntry(
      id: id, bankName: id, ratePercent: rate.flatMap { Decimal(string: $0) },
      termMinMonths: term?.lowerBound, termMaxMonths: term?.upperBound,
      minAmountE4: min.map(rub), maxAmountE4: max.map(rub), topup: topup, rateOn: on ?? today)
  }

  @Test func theHighestRateComesFirstAndAnEntryWithoutOneLast() {
    let list = DepositShowcase.sorted([
      entry("c", nil), entry("a", "12.5"), entry("b", "14"), entry("d", "12.5"),
    ])
    #expect(list.map(\.id) == ["b", "a", "d", "c"])
  }

  @Test func theFilterNarrowsByTermAmountAndTopUp() {
    let all = [
      entry("short", "15", term: 3...3, min: 10_000, topup: false),
      entry("wide", "13", term: 1...36, min: 100_000, topup: true),
      entry("unknown", "12"),
    ]
    func ids(_ filter: DepositFilter) -> [String] {
      DepositShowcase.entries(builtIn: all, filter: filter).map(\.id)
    }
    #expect(ids(.none) == ["short", "wide", "unknown"])
    #expect(ids(DepositFilter(termMonths: 12)) == ["wide", "unknown"])
    #expect(ids(DepositFilter(amountE4: rub(50_000))) == ["short", "unknown"])
    // An entry that does not say whether it can be topped up is not offered as one that can.
    #expect(ids(DepositFilter(requiresTopup: true)) == ["wide"])
    #expect(
      ids(DepositFilter(termMonths: 3, amountE4: rub(200_000))) == ["short", "wide", "unknown"])
  }

  @Test func aRateIsOldAfterThirtyDays() {
    let fresh = entry("f", "10", on: DateOnly(year: 2026, month: 9, day: 28))
    let old = entry("o", "10", on: DateOnly(year: 2026, month: 9, day: 27))
    #expect(!fresh.isStale(on: today))
    #expect(old.isStale(on: today))
  }

  @Test func theOwnersOffersJoinAndArchivedOnesDoNot() {
    let mine = DepositOffer(
      bankName: "Мой банк", ratePercent: 20, termMonths: 6, rateOn: today)
    var gone = DepositOffer(bankName: "Старый", ratePercent: 30, rateOn: today)
    gone.archived = true
    let list = DepositShowcase.entries(builtIn: [entry("a", "15")], own: [mine, gone])
    #expect(list.map(\.bankName) == ["Мой банк", "a"])
    #expect(list.first?.origin == .own(mine.id))
    #expect(DepositShowcase.entries(own: [], filter: DepositFilter(termMonths: 6)).count > 0)
  }

  @Test func theBuiltInListIsHonest() {
    let data = DepositShowcaseData.entries
    #expect((10...20).contains(data.count))
    #expect(Set(data.map(\.id)).count == data.count)
    // No rate is in the future, none is made up for a bank whose page could not be read.
    #expect(data.allSatisfy { $0.rateOn <= DepositShowcaseData.readOn })
    #expect(data.filter { $0.ratePercent == nil }.count >= 1)
    #expect(data.compactMap(\.ratePercent).allSatisfy { $0 > 0 && $0 < 40 })
  }
}

@Suite("A deposit about to end gets the showcase laid against its conditions")
struct DepositEndAdviceTests {
  let today = DateOnly(year: 2026, month: 10, day: 28)

  func deposit(
    ends: DateOnly?, opened: DateOnly? = DateOnly(year: 2026, month: 5, day: 3)
  )
    -> PaymentMethod
  {
    PaymentMethod(
      name: "Вклад", kind: .account,
      interest: DepositTerms(rate: 15, period: .atEnd, openedOn: opened, endsOn: ends))
  }

  func entry(
    _ id: String, _ rate: String, topup: Bool? = nil, term: ClosedRange<Int> = 1...12
  )
    -> DepositShowcaseEntry
  {
    DepositShowcaseEntry(
      id: id, bankName: id, ratePercent: Decimal(string: rate), termMinMonths: term.lowerBound,
      termMaxMonths: term.upperBound, topup: topup, rateOn: today)
  }

  let money = AmountE4(raw: 500_000 * 10_000)

  @Test func threeLinesNotOneBest() {
    let account = deposit(ends: DateOnly(year: 2026, month: 11, day: 3))
    let list = DepositEndAdvisor.advice(
      accounts: [account], balanceE4: { _ in money },
      entries: [
        entry("fast", "16", term: 3...3), entry("year", "14"), entry("top", "13", topup: true),
      ], today: today)
    #expect(list.count == 1)
    let picks = list[0].picks
    #expect(picks.count == 3)
    // Opened 3 May, ends 3 November: six months. The highest for six months is "year", not "fast".
    #expect(picks[0].condition == .term(months: 6))
    #expect(picks[0].entry.id == "year")
    #expect(picks[1].condition == .amount(money))
    #expect(picks[1].entry.id == "fast")
    #expect(picks[2].condition == .topup)
    #expect(picks[2].entry.id == "top")
  }

  @Test func onlyWithinAWeekAndOnlyRubleDepositsThatAreLive() {
    let entries = [entry("a", "14", topup: true)]
    func ids(_ ends: DateOnly?, currency: CurrencyCode? = nil, archived: Bool = false) -> Int {
      var account = deposit(ends: ends)
      account.currency = currency
      account.archived = archived
      return DepositEndAdvisor.advice(
        accounts: [account], balanceE4: { _ in nil }, entries: entries, today: today
      ).count
    }
    #expect(ids(DateOnly(year: 2026, month: 11, day: 4)) == 1)
    #expect(ids(today) == 1)
    #expect(ids(DateOnly(year: 2026, month: 11, day: 5)) == 0)
    #expect(ids(DateOnly(year: 2026, month: 10, day: 27)) == 0)
    #expect(ids(nil) == 0)
    #expect(ids(DateOnly(year: 2026, month: 11, day: 1), currency: .usd) == 0)
    #expect(ids(DateOnly(year: 2026, month: 11, day: 1), archived: true) == 0)
  }

  @Test func nothingIsSaidWhenTheShowcaseHasNothingToPutAgainst() {
    let account = deposit(ends: DateOnly(year: 2026, month: 11, day: 1))
    let none = DepositShowcaseEntry(id: "x", bankName: "x", rateOn: today)
    #expect(
      DepositEndAdvisor.advice(
        accounts: [account], balanceE4: { _ in nil }, entries: [none], today: today
      ).isEmpty)
  }
}
