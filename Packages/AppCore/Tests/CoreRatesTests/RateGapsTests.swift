import CoreKit
import Foundation
import Testing

@testable import CoreRates

/// Holes in the cache. The table is filled day by day, as operations need it, so a day with
/// no rate of its own can be either a weekend the bank never published into or a stretch
/// nobody has asked about yet — and the two must not be treated alike.
@Suite("Days without a published rate")
struct RateGapsTests {
  private let usd = CurrencyCode("USD")

  private func rate(_ iso: String, _ value: String, _ source: RateSource = .cbr) throws -> Rate {
    Rate(
      date: try #require(DateOnly(iso: iso)), currency: usd,
      rubPerUnit: try #require(Decimal(string: value, locale: Locale(identifier: "en_US_POSIX"))),
      nominal: 1, source: source)
  }

  private func day(_ iso: String) throws -> DateOnly {
    try #require(DateOnly(iso: iso))
  }

  @Test func aStretchNobodyAskedAboutIsStillRequested() throws {
    // Two operations years apart leave everything between them without a rate, although
    // the bank published on every business day of those years.
    let table = RateTable(rates: [
      try rate("2020-01-15", "61.7000"),
      try rate("2026-09-18", "83.5600"),
    ])
    let midway = try day("2023-05-05")
    #expect(table.needsFetch(currency: usd, on: midway) == true)
    // Until it arrives the old rate is used, and it is a guess, not a final answer.
    let resolution = try #require(table.resolve(usd, on: midway))
    #expect(resolution.rate.date == (try day("2020-01-15")))
    #expect(resolution.isProvisional == true)
  }

  /// The bank publishes Saturday's rate and nothing on Sunday or Monday: asked for either, it
  /// answers with Saturday. Until it has been asked, the table cannot tell.
  @Test func aWeekendIsAskedAboutOnceAndThenTakesTheRateBeforeIt() throws {
    let rates = [try rate("2026-09-19", "83.5600"), try rate("2026-09-22", "84.1000")]
    let unasked = RateTable(rates: rates)
    for iso in ["2026-09-20", "2026-09-21"] {
      #expect(unasked.needsFetch(currency: usd, on: try day(iso)) == true, "\(iso)")
      #expect(unasked.resolve(usd, on: try day(iso))?.isProvisional == true, "\(iso)")
    }

    let saturday = try day("2026-09-19")
    let answered = RateTable(
      rates: rates,
      unpublishedDays: [try day("2026-09-20"): saturday, try day("2026-09-21"): saturday])
    for iso in ["2026-09-20", "2026-09-21"] {
      #expect(answered.needsFetch(currency: usd, on: try day(iso)) == false, "\(iso)")
      let resolution = try #require(answered.resolve(usd, on: try day(iso)))
      #expect(resolution.rate.date == saturday, "\(iso)")
      #expect(resolution.isProvisional == false, "\(iso)")
    }
  }

  /// A Sunday the bank answered for is final even while the cache ends on Saturday: there is
  /// no need to wait for Tuesday.
  @Test func anAnsweredDayPastTheEndOfTheCacheIsFinal() throws {
    let saturday = try day("2026-09-19")
    let table = RateTable(
      rates: [try rate("2026-09-19", "83.5600")],
      unpublishedDays: [try day("2026-09-20"): saturday])
    #expect(table.needsFetch(currency: usd, on: try day("2026-09-20")) == false)
    #expect(table.resolve(usd, on: try day("2026-09-20"))?.isProvisional == false)
    // Monday was not asked about.
    #expect(table.needsFetch(currency: usd, on: try day("2026-09-21")) == true)
    #expect(table.resolve(usd, on: try day("2026-09-21"))?.isProvisional == true)
  }

  @Test func theNewYearBreakIsAskedAboutDayByDay() throws {
    // The bank stops after the 31st and comes back in the second week of January; the days
    // operations fell on were asked about and answered with the 31st.
    let lastOfTheYear = try day("2025-12-31")
    let table = RateTable(
      rates: [try rate("2025-12-31", "80.0000"), try rate("2026-01-13", "81.5000")],
      unpublishedDays: [
        try day("2026-01-01"): lastOfTheYear, try day("2026-01-05"): lastOfTheYear,
        try day("2026-01-08"): lastOfTheYear,
      ])
    for iso in ["2026-01-01", "2026-01-05", "2026-01-08"] {
      #expect(table.needsFetch(currency: usd, on: try day(iso)) == false, "\(iso)")
      #expect(table.resolve(usd, on: try day(iso))?.isProvisional == false, "\(iso)")
    }
    #expect(table.needsFetch(currency: usd, on: try day("2026-01-06")) == true)
  }

  /// The answer names a publication. A currency the table holds only from before it was never
  /// brought in for that publication: its old rate is still a guess, and the day is asked for.
  @Test func anAnsweredDayStillWaitsForACurrencyMissingFromThatPublication() throws {
    let eur = CurrencyCode("EUR")
    let saturday = try day("2026-09-19")
    let table = RateTable(
      rates: [
        try rate("2026-09-19", "83.5600"),
        Rate(date: try day("2026-09-10"), currency: eur, rubPerUnit: 95, source: .cbr),
      ],
      unpublishedDays: [try day("2026-09-20"): saturday])
    #expect(table.needsFetch(currency: eur, on: try day("2026-09-20")) == true)
    #expect(table.resolve(eur, on: try day("2026-09-20"))?.isProvisional == true)
    #expect(table.needsFetch(currency: usd, on: try day("2026-09-20")) == false)
  }

  @Test func onlyTheBanksOwnAnswerForAPastDaySaysTheDayHadNoRate() throws {
    let today = try day("2026-09-24")
    let saturday = try day("2026-09-19")
    func answer(_ date: DateOnly, _ source: RateSource) -> RateSnapshot {
      RateSnapshot(date: date, rates: [:], source: source)
    }
    let sunday = try day("2026-09-20")
    #expect(
      RateTable.publicationHolding(on: sunday, answer: answer(saturday, .cbr), today: today)
        == saturday)
    // The mirror always sends its latest day, whatever day was asked.
    #expect(
      RateTable.publicationHolding(on: sunday, answer: answer(saturday, .cbrMirror), today: today)
        == nil)
    // The day's own rate is no gap.
    #expect(
      RateTable.publicationHolding(on: sunday, answer: answer(sunday, .cbr), today: today) == nil)
    // Tomorrow's rate may still be published today.
    let tomorrow = try day("2026-09-25")
    #expect(
      RateTable.publicationHolding(on: tomorrow, answer: answer(today, .cbr), today: today) == nil)
  }

  @Test func mergingKeepsWhatTheBankSaidAboutDaysOff() throws {
    let saturday = try day("2026-09-19")
    let table = RateTable(
      rates: [try rate("2026-09-19", "83.5600")],
      unpublishedDays: [try day("2026-09-20"): saturday])
    let merged = table.merging([try rate("2026-09-22", "84.1000")])
    #expect(merged.unpublishedDays == table.unpublishedDays)
    #expect(merged.needsFetch(currency: usd, on: try day("2026-09-20")) == false)
  }

  @Test func aBusinessDayInsideAShortHoleIsStillRequested() throws {
    // Two purchases on Tuesday the 1st and Thursday the 10th filled those two days; Friday
    // the 4th had its own rate, nobody asked for it yet.
    let table = RateTable(rates: [
      try rate("2026-09-01", "81.1000"),
      try rate("2026-09-10", "83.2000"),
    ])
    let friday = try day("2026-09-04")
    #expect(table.needsFetch(currency: usd, on: friday) == true)
    let resolution = try #require(table.resolve(usd, on: friday))
    #expect(resolution.rate.date == (try day("2026-09-01")))
    #expect(resolution.isProvisional == true)
  }

  @Test func aSingleDayBetweenTwoStoredDaysIsRequestedToo() throws {
    // Wednesday between Tuesday and Thursday: nothing but the bank can tell it was a holiday.
    let table = RateTable(rates: [
      try rate("2026-09-01", "81.1000"),
      try rate("2026-09-03", "81.9000"),
    ])
    let wednesday = try day("2026-09-02")
    #expect(table.needsFetch(currency: usd, on: wednesday) == true)
    #expect(table.resolve(usd, on: wednesday)?.isProvisional == true)
  }

  @Test func aMonthLongHoleIsRequested() throws {
    let table = RateTable(rates: [
      try rate("2026-02-02", "80.0000"),
      try rate("2026-03-10", "81.5000"),
    ])
    #expect(table.needsFetch(currency: usd, on: try day("2026-02-20")) == true)
  }

  @Test func aStoredDayIsNeverRequestedWhateverItsSource() throws {
    let table = RateTable(rates: [
      try rate("2026-09-16", "83.1250"),
      try rate("2026-09-17", "90.0000", .manual),
      try rate("2026-09-18", "83.5600", .cbrMirror),
    ])
    for iso in ["2026-09-16", "2026-09-17", "2026-09-18"] {
      #expect(table.needsFetch(currency: usd, on: try day(iso)) == false, "\(iso)")
    }
  }
}
