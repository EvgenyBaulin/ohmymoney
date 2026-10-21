import CoreKit
import Foundation
import Testing

@testable import CoreRates

@Suite("Rate lookup, fetching and merging follow the rules of the spec")
struct RateTableTests {
  private let usd = CurrencyCode("USD")
  private let wednesday = DateOnly(year: 2026, month: 9, day: 16)
  private let thursday = DateOnly(year: 2026, month: 9, day: 17)
  private let friday = DateOnly(year: 2026, month: 9, day: 18)
  private let saturday = DateOnly(year: 2026, month: 9, day: 19)
  private let sunday = DateOnly(year: 2026, month: 9, day: 20)
  private let monday = DateOnly(year: 2026, month: 9, day: 21)

  /// Wednesday and Friday were published; Thursday, Saturday and Sunday were not.
  private func publishedWeek() throws -> RateTable {
    let midweek = try CBRDocumentParser.parse(Fixture.cbrWednesday())
    let endOfWeek = try CBRDocumentParser.parse(Fixture.cbrFriday())
    return RateTable().merging(midweek).merging(endOfWeek)
  }

  private func rate(
    _ code: String, _ day: DateOnly, _ value: String, _ source: RateSource = .cbr
  ) throws -> Rate {
    Rate(
      date: day, currency: CurrencyCode(code),
      rubPerUnit: try #require(Decimal(string: value, locale: Locale(identifier: "en_US_POSIX"))),
      nominal: 1, source: source)
  }

  // MARK: - Lookup

  @Test func aPublishedDayReturnsItsOwnRate() throws {
    let table = try publishedWeek()
    #expect(table.rate(for: usd, on: wednesday)?.date == wednesday)
    #expect(table.rate(for: usd, on: friday)?.date == friday)
  }

  @Test func aWeekendTakesTheLastPublishedRate() throws {
    let table = try publishedWeek()
    let onSaturday = try #require(table.rate(for: usd, on: saturday))
    let onFriday = try #require(table.rate(for: usd, on: friday))
    #expect(onSaturday == onFriday)
    #expect(onSaturday.date == friday)
    #expect(table.rate(for: usd, on: sunday)?.date == friday)
    #expect(table.publishedRate(for: usd, on: saturday) == nil)
    // The same holds for a mid-week gap: Thursday falls back to Wednesday.
    #expect(table.rate(for: usd, on: thursday)?.date == wednesday)
  }

  /// Nothing published before the day is known, so no rate applies to it as the right one.
  @Test func aDayBeforeAnyPublicationHasNoRate() throws {
    let table = try publishedWeek()
    #expect(table.rate(for: usd, on: DateOnly(year: 2026, month: 9, day: 15)) == nil)
  }

  /// Offline, the last rate known is used, marked `rate_provisional`.
  /// A backdated operation before everything the cache holds still gets a rate to be saved
  /// with — the nearest one known, provisional — and its day is still asked for; once the
  /// day's own rate arrives, the refinement replaces the guess.
  @Test func aDayBeforeAnyPublicationTakesTheNearestKnownRateProvisionally() throws {
    let table = try publishedWeek()
    let tuesday = DateOnly(year: 2026, month: 9, day: 15)

    let resolution = try #require(table.resolve(usd, on: tuesday))
    #expect(resolution.rate.date == wednesday)
    #expect(resolution.isProvisional)
    #expect(table.needsFetch(currency: usd, on: tuesday))

    let usage = RateTable.RateUsage(
      currency: usd, day: tuesday, source: .cbr, isProvisional: true, appliedRateDate: wednesday)
    #expect(RateTable.refinement(for: [usage], with: table).isEmpty)
    let arrived = table.merging([try rate("USD", tuesday, "80.90")])
    let refined = try #require(RateTable.refinement(for: [usage], with: arrived).first)
    #expect(refined.rate.date == tuesday)
    #expect(!refined.isProvisional)
  }

  @Test func theRubleConvertsToItself() throws {
    let table = try publishedWeek()
    let rate = try #require(table.rate(for: .rub, on: saturday))
    #expect(rate.perUnit == Decimal(1))
    #expect(try rate.toRubles(AmountE4(whole: 500)) == AmountE4(whole: 500))
    #expect(table.needsFetch(currency: .rub, on: saturday) == false)
  }

  // MARK: - Fetching

  @Test func aDayThatIsAlreadyStoredIsNeverRequestedAgain() throws {
    let table = try publishedWeek()
    #expect(table.needsFetch(currency: usd, on: wednesday) == false)
    #expect(table.needsFetch(currency: usd, on: friday) == false)
  }

  @Test func aGapInsideThePublishedHistoryIsRequestedUntilTheBankAnswersForIt() throws {
    let table = try publishedWeek()
    // Thursday may be a holiday or a day nobody asked about yet; only the bank can tell.
    #expect(table.needsFetch(currency: usd, on: thursday) == true)
    // Asked, it answered with Wednesday: Thursday never gets a rate of its own, and asking
    // again would only annoy the bank.
    let answered = RateTable(rates: table.rates, unpublishedDays: [thursday: wednesday])
    #expect(answered.needsFetch(currency: usd, on: thursday) == false)
  }

  @Test func daysOutsideTheHistoryAreRequested() throws {
    let table = try publishedWeek()
    #expect(table.needsFetch(currency: usd, on: saturday) == true)
    #expect(table.needsFetch(currency: usd, on: monday) == true)
    #expect(table.needsFetch(currency: usd, on: DateOnly(year: 2026, month: 9, day: 15)) == true)
    #expect(table.needsFetch(currency: CurrencyCode("NZD"), on: friday) == true)
    #expect(RateTable().needsFetch(currency: usd, on: friday) == true)
  }

  /// A later publication does not say the days before it had none: they may simply not have
  /// been asked about. The bank's answer for the day itself does.
  @Test func theWeekendIsSettledByTheBanksAnswerNotByALaterDay() throws {
    var table = try publishedWeek()
    #expect(table.needsFetch(currency: usd, on: saturday) == true)
    table = table.merging(
      RateSnapshot(
        date: monday, rates: [usd: try rate("USD", monday, "84.10")], source: .cbr))
    #expect(table.needsFetch(currency: usd, on: saturday) == true)
    #expect(table.needsFetch(currency: usd, on: sunday) == true)

    table = RateTable(rates: table.rates, unpublishedDays: [saturday: friday, sunday: friday])
    #expect(table.needsFetch(currency: usd, on: saturday) == false)
    #expect(table.needsFetch(currency: usd, on: sunday) == false)
    #expect(table.rate(for: usd, on: saturday)?.date == friday)
  }

  // MARK: - Provisional

  @Test func aDayPastTheHistoryResolvesToAProvisionalRate() throws {
    let table = try publishedWeek()
    let resolution = try #require(table.resolve(usd, on: monday))
    #expect(resolution.rate.date == friday)
    #expect(resolution.isProvisional == true)
  }

  @Test func aWeekendTheBankAnsweredForIsNotProvisional() throws {
    let spanned = try publishedWeek().merging(
      RateSnapshot(
        date: monday, rates: [usd: try rate("USD", monday, "84.10")], source: .cbr))
    #expect(spanned.resolve(usd, on: saturday)?.isProvisional == true)
    let table = RateTable(rates: spanned.rates, unpublishedDays: [saturday: friday])
    let onSaturday = try #require(table.resolve(usd, on: saturday))
    #expect(onSaturday.rate.date == friday)
    #expect(onSaturday.isProvisional == false)
    let onFriday = try #require(table.resolve(usd, on: friday))
    #expect(onFriday.isProvisional == false)
  }

  // MARK: - Merging

  @Test func aManualRateIsNeverOverwritten() throws {
    let manual = try rate("USD", friday, "90.0000", .manual)
    let table = RateTable(rates: [manual])
    let merged = table.merging(try CBRDocumentParser.parse(Fixture.cbrFriday()))
    #expect(merged.rate(for: usd, on: friday) == manual)
    #expect(merged.rate(for: usd, on: friday)?.source == .manual)
    // Other currencies of the same snapshot are still taken in.
    #expect(merged.rate(for: CurrencyCode("EUR"), on: friday)?.source == .cbr)
  }

  @Test func aRateFromAnImportIsNeverOverwritten() throws {
    let imported = try rate("USD", friday, "88.0000", .imported)
    let merged = RateTable(rates: [imported]).merging(
      try CBRDocumentParser.parse(Fixture.cbrFriday()))
    #expect(merged.rate(for: usd, on: friday) == imported)
  }

  @Test func theBankOutranksItsMirrorForTheSameDay() throws {
    let mirror = try CBRMirrorParser.parse(Fixture.mirror())
    let bank = try CBRDocumentParser.parse(Fixture.cbrFriday())
    let mirrorFirst = RateTable().merging(mirror).merging(bank)
    #expect(mirrorFirst.rate(for: usd, on: friday)?.source == .cbr)
    let bankFirst = RateTable().merging(bank).merging(mirror)
    #expect(bankFirst.rate(for: usd, on: friday)?.source == .cbr)
  }

  @Test func theMirrorFillsDaysTheBankHasNotGiven() throws {
    let mirror = try CBRMirrorParser.parse(Fixture.mirror())
    let table = RateTable().merging(mirror)
    #expect(table.rate(for: usd, on: friday)?.source == .cbrMirror)
    #expect(table.needsFetch(currency: usd, on: friday) == false)
  }

  @Test func mergingIsOrderIndependentAndKeepsOneRatePerDay() throws {
    let midweek = try CBRDocumentParser.parse(Fixture.cbrWednesday())
    let endOfWeek = try CBRDocumentParser.parse(Fixture.cbrFriday())
    let forwards = RateTable().merging(midweek).merging(endOfWeek)
    let backwards = RateTable().merging(endOfWeek).merging(midweek)
    #expect(forwards == backwards)
    #expect(forwards.rates.filter { $0.currency == usd }.count == 2)
    #expect(forwards.merging(endOfWeek) == forwards)
  }

  @Test func theInitialiserAppliesTheSamePrecedence() throws {
    let manual = try rate("USD", friday, "90.0000", .manual)
    let fetched = try rate("USD", friday, "83.5600", .cbr)
    #expect(RateTable(rates: [manual, fetched]).rate(for: usd, on: friday) == manual)
    #expect(RateTable(rates: [fetched, manual]).rate(for: usd, on: friday) == manual)
  }

  // MARK: - Refining provisional rates

  @Test func aProvisionalOperationIsRefinedOnceTheRealRateArrives() throws {
    // Entered on Friday while offline, so Wednesday's rate was used.
    let usage = RateTable.RateUsage(
      currency: usd, day: friday, source: .cbr, isProvisional: true,
      appliedRateDate: wednesday)
    let offline = RateTable().merging(try CBRDocumentParser.parse(Fixture.cbrWednesday()))
    #expect(RateTable.refinement(for: [usage], with: offline).isEmpty)

    let online = offline.merging(try CBRDocumentParser.parse(Fixture.cbrFriday()))
    let refinements = RateTable.refinement(for: [usage], with: online)
    #expect(refinements.count == 1)
    #expect(refinements.first?.usageId == usage.id)
    #expect(refinements.first?.rate.date == friday)
    #expect(refinements.first?.isProvisional == false)
  }

  /// Writing the answer back — the rate's day and the flag — leaves nothing for the next
  /// run: neither for Friday, settled on its own rate, nor for Saturday, which took Friday's
  /// and waits for a later day to be published.
  @Test func refiningTwiceChangesNothingTheSecondTime() throws {
    let table = try publishedWeek()
    for day in [friday, saturday] {
      var usage = RateTable.RateUsage(
        currency: usd, day: day, isProvisional: true, appliedRateDate: wednesday)
      let first = try #require(RateTable.refinement(for: [usage], with: table).first)
      usage.appliedRateDate = first.rate.date
      usage.isProvisional = first.isProvisional
      #expect(RateTable.refinement(for: [usage], with: table).isEmpty, "\(day.iso)")
    }
  }

  @Test func settledManualAndRubleOperationsAreLeftAlone() throws {
    let table = try publishedWeek()
    let settled = RateTable.RateUsage(
      currency: usd, day: friday, source: .cbr, isProvisional: false, appliedRateDate: wednesday)
    let manual = RateTable.RateUsage(
      currency: usd, day: friday, source: .manual, isProvisional: true,
      appliedRateDate: wednesday)
    let imported = RateTable.RateUsage(
      currency: usd, day: friday, source: .imported, isProvisional: true,
      appliedRateDate: wednesday)
    let rubles = RateTable.RateUsage(
      currency: .rub, day: friday, isProvisional: true, appliedRateDate: nil)
    #expect(RateTable.refinement(for: [settled, manual, imported, rubles], with: table).isEmpty)
  }

  @Test func anUnknownCurrencyStaysProvisional() throws {
    let table = try publishedWeek()
    let usage = RateTable.RateUsage(
      currency: CurrencyCode("NZD"), day: friday, isProvisional: true, appliedRateDate: nil)
    #expect(RateTable.refinement(for: [usage], with: table).isEmpty)
  }

  @Test func aWeekendOperationIsRefinedToTheFridayRate() throws {
    let table = try publishedWeek()
    let usage = RateTable.RateUsage(
      currency: usd, day: saturday, isProvisional: true, appliedRateDate: wednesday)
    let refinements = RateTable.refinement(for: [usage], with: table)
    #expect(refinements.count == 1)
    #expect(refinements.first?.rate.date == friday)
    // Nothing is published after Friday yet, so Saturday may still have a rate of its own.
    #expect(refinements.first?.isProvisional == true)
  }

  /// A Sunday entered while the cache ended on Friday already carries the right rate, but
  /// nothing says so until the bank, asked for Sunday, answers with Friday — a later
  /// publication alone does not. Then the rate stays and the operation is settled with it: a
  /// rate date that never moves must not keep the flag forever.
  @Test func aDayOffIsSettledWithTheRateItCarriesOnceTheBankAnswersForIt() throws {
    let usage = RateTable.RateUsage(
      currency: usd, day: sunday, source: .cbr, isProvisional: true, appliedRateDate: friday)
    let untilFriday = try publishedWeek()
    #expect(RateTable.refinement(for: [usage], with: untilFriday).isEmpty)

    let tuesday = DateOnly(year: 2026, month: 9, day: 22)
    let withTuesday = untilFriday.merging([try rate("USD", tuesday, "84.1000")])
    #expect(RateTable.refinement(for: [usage], with: withTuesday).isEmpty)

    let answered = RateTable(rates: withTuesday.rates, unpublishedDays: [sunday: friday])
    let refinements = RateTable.refinement(for: [usage], with: answered)
    #expect(refinements.count == 1)
    #expect(refinements.first?.usageId == usage.id)
    #expect(refinements.first?.rate == untilFriday.rate(for: usd, on: friday))
    #expect(refinements.first?.isProvisional == false)
  }

  /// A weekday refined to the day before stays provisional, since its own rate may still come
  /// — even once the next business day is published, which only says nobody asked. When the
  /// bank, asked for the day, answers with the day before, the day was a holiday: the rate
  /// it carries is final and the operation is settled with it.
  @Test func aWeekdayThatTurnsOutAHolidayIsSettledWithTheRateBeforeIt() throws {
    let usage = RateTable.RateUsage(
      currency: usd, day: thursday, source: .cbr, isProvisional: true,
      appliedRateDate: wednesday)
    let untilWednesday = RateTable().merging(try CBRDocumentParser.parse(Fixture.cbrWednesday()))
    #expect(RateTable.refinement(for: [usage], with: untilWednesday).isEmpty)
    #expect(RateTable.refinement(for: [usage], with: try publishedWeek()).isEmpty)

    let answered = RateTable(
      rates: try publishedWeek().rates, unpublishedDays: [thursday: wednesday])
    let refinements = RateTable.refinement(for: [usage], with: answered)
    #expect(refinements.count == 1)
    #expect(refinements.first?.rate.date == wednesday)
    #expect(refinements.first?.isProvisional == false)
  }
}
