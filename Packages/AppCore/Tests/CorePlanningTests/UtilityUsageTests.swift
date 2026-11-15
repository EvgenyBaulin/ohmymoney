import CoreKit
import Foundation
import Testing

@testable import CorePlanning

// Synthetic data only.

/// What a meter used in a month, at what cost, against the month before and the same month of
/// the year before; when its readings are due; how a bill compares.
@Suite("Utilities: usage, comparison and reminders")
struct UtilityUsageTests {
  static let water = UtilityMeter(
    name: "Cold water", kind: .coldWater, tariffE4: AmountE4(raw: 50_0000), submitFrom: 20,
    submitTo: 25)
  static let at = Date(timeIntervalSince1970: 1_790_000_000)

  static func reading(
    _ year: Int, _ month: Int, _ day: Int, _ value: Int64, restart: Bool = false,
    tariff: Int64? = nil, meter: UtilityMeter = water
  ) -> UtilityReading {
    UtilityReading(
      meterId: meter.id, day: DateOnly(year: year, month: month, day: day),
      valueE4: AmountE4(whole: value), restart: restart,
      tariffE4: tariff.map { AmountE4(whole: $0) },
      recordedAt: at)
  }

  @Test func aValueBelowTheLastGoodOneIsFlaggedAndTheNextUseCountsFromTheGoodOne() {
    let typo = Self.reading(2026, 10, 21, 100)
    let readings = [Self.reading(2026, 9, 22, 1000), typo, Self.reading(2026, 11, 20, 1010)]
    let months = UtilityUsage.months(of: Self.water, readings: readings)
    #expect(months[MonthKey(year: 2026, month: 10)]?.quantityE4 == .zero)
    #expect(months[MonthKey(year: 2026, month: 11)]?.quantityE4 == AmountE4(whole: 10))
    #expect(UtilityUsage.decreases(of: Self.water, readings: readings) == [typo.id])
  }

  @Test func aMonthUsesTheDifferenceToTheReadingBefore() {
    let months = UtilityUsage.months(
      of: Self.water,
      readings: [
        Self.reading(2026, 9, 22, 100), Self.reading(2026, 10, 21, 108),
        Self.reading(2026, 11, 20, 118),
      ])
    #expect(months[MonthKey(year: 2026, month: 9)] == nil, "the first reading is the start")
    #expect(months[MonthKey(year: 2026, month: 10)]?.quantityE4 == AmountE4(whole: 8))
    #expect(months[MonthKey(year: 2026, month: 11)]?.quantityE4 == AmountE4(whole: 10))
    #expect(months[MonthKey(year: 2026, month: 11)]?.costE4 == AmountE4(whole: 500))
  }

  @Test func theOrderOfTheReadingsDoesNotMatter() {
    let readings = [
      Self.reading(2026, 11, 20, 118), Self.reading(2026, 9, 22, 100),
      Self.reading(2026, 10, 21, 108),
    ]
    #expect(
      UtilityUsage.months(of: Self.water, readings: readings)
        == UtilityUsage.months(of: Self.water, readings: readings.reversed()))
  }

  @Test func aRestartCountsNothingAcrossTheChangeAndNeverGoesBelowZero() {
    let readings = [
      Self.reading(2026, 9, 22, 99_990), Self.reading(2026, 10, 21, 3, restart: true),
      Self.reading(2026, 11, 20, 12), Self.reading(2026, 12, 20, 10),
    ]
    let months = UtilityUsage.months(of: Self.water, readings: readings)
    #expect(months[MonthKey(year: 2026, month: 10)]?.quantityE4 == .zero)
    #expect(months[MonthKey(year: 2026, month: 11)]?.quantityE4 == AmountE4(whole: 9))
    #expect(months[MonthKey(year: 2026, month: 12)]?.quantityE4 == .zero)
    #expect(months.values.allSatisfy { !$0.quantityE4.isNegative })
    #expect(UtilityUsage.decreases(of: Self.water, readings: readings) == [readings[3].id])
  }

  @Test func theTariffOfTheReadingWinsOverTheMeters() {
    let months = UtilityUsage.months(
      of: Self.water,
      readings: [Self.reading(2026, 6, 20, 10), Self.reading(2026, 7, 20, 14, tariff: 60)])
    #expect(months[MonthKey(year: 2026, month: 7)]?.costE4 == AmountE4(whole: 240))
    var unpriced = Self.water
    unpriced.tariffE4 = nil
    let bare = UtilityUsage.months(
      of: unpriced, readings: [Self.reading(2026, 6, 20, 10), Self.reading(2026, 7, 20, 14)])
    #expect(bare[MonthKey(year: 2026, month: 7)]?.costE4 == nil)
    #expect(bare[MonthKey(year: 2026, month: 7)]?.quantityE4 == AmountE4(whole: 4))
  }

  @Test func theCostRoundsHalfAwayFromZeroToTheFourthDigit() {
    var meter = Self.water
    meter.tariffE4 = AmountE4(raw: 7_3333)  // 7.3333 per unit
    let months = UtilityUsage.months(
      of: meter,
      readings: [
        UtilityReading(
          meterId: meter.id, day: DateOnly(year: 2026, month: 1, day: 1),
          valueE4: AmountE4(raw: 0), recordedAt: Self.at),
        UtilityReading(
          meterId: meter.id, day: DateOnly(year: 2026, month: 2, day: 1),
          valueE4: AmountE4(raw: 1_5000), recordedAt: Self.at),
      ])
    // 1.5 × 7.3333 = 10.99995 → 11.0000
    #expect(months[MonthKey(year: 2026, month: 2)]?.costE4 == AmountE4(raw: 11_0000))
  }

  @Test func aMonthComparesWithTheMonthBeforeAndTheYearBefore() {
    let readings = [
      Self.reading(2025, 10, 20, 0), Self.reading(2025, 11, 20, 12),
      Self.reading(2026, 10, 20, 200), Self.reading(2026, 11, 20, 209),
      Self.reading(2026, 9, 20, 192),
    ]
    let comparison = UtilityUsage.compare(
      Self.water, readings: readings, month: MonthKey(year: 2026, month: 11))
    #expect(comparison.current?.quantityE4 == AmountE4(whole: 9))
    #expect(comparison.previousMonth?.quantityE4 == AmountE4(whole: 8))
    #expect(comparison.previousYear?.quantityE4 == AmountE4(whole: 12))
    let lonely = UtilityUsage.compare(
      Self.water, readings: [Self.reading(2026, 11, 20, 5)],
      month: MonthKey(year: 2026, month: 11))
    #expect(lonely.current == nil && lonely.previousMonth == nil && lonely.previousYear == nil)
  }

  @Test func readingsAreDueInTheWindowUntilOneIsWritten() {
    let book = UtilityBook(meters: [Self.water], readings: [Self.reading(2026, 10, 21, 108)])
    #expect(UtilityReminder.due(book, today: DateOnly(year: 2026, month: 11, day: 19)).isEmpty)
    #expect(
      UtilityReminder.due(book, today: DateOnly(year: 2026, month: 11, day: 20)).map(\.id)
        == [Self.water.id])
    #expect(
      UtilityReminder.due(book, today: DateOnly(year: 2026, month: 11, day: 25)).map(\.id)
        == [Self.water.id])
    #expect(UtilityReminder.due(book, today: DateOnly(year: 2026, month: 11, day: 26)).isEmpty)
    var written = book
    written.readings.append(Self.reading(2026, 11, 21, 118))
    #expect(UtilityReminder.due(written, today: DateOnly(year: 2026, month: 11, day: 23)).isEmpty)
  }

  @Test func aWindowAcrossTheEndOfAMonthAndAShortMonth() {
    var meter = Self.water
    meter.submitFrom = 25
    meter.submitTo = 5
    let book = UtilityBook(meters: [meter], readings: [])
    #expect(UtilityReminder.due(book, today: DateOnly(year: 2026, month: 11, day: 28)).count == 1)
    #expect(UtilityReminder.due(book, today: DateOnly(year: 2026, month: 12, day: 3)).count == 1)
    #expect(UtilityReminder.due(book, today: DateOnly(year: 2026, month: 12, day: 10)).isEmpty)
    // Written on 27 November: the window that ends on 5 December is done.
    var written = book
    written.readings = [Self.reading(2026, 11, 27, 5, meter: meter)]
    #expect(UtilityReminder.due(written, today: DateOnly(year: 2026, month: 12, day: 2)).isEmpty)
    // «до 31» in February ends on its last day.
    meter.submitFrom = 28
    meter.submitTo = 31
    let february = UtilityBook(meters: [meter], readings: [])
    #expect(
      UtilityReminder.due(february, today: DateOnly(year: 2026, month: 2, day: 28)).count == 1)
    #expect(UtilityReminder.due(february, today: DateOnly(year: 2026, month: 3, day: 1)).isEmpty)
  }

  @Test func anArchivedMeterOrOneWithoutAWindowIsNeverDue() {
    var archived = Self.water
    archived.archived = true
    var silent = Self.water
    silent.id = UUID()
    silent.submitFrom = nil
    let book = UtilityBook(meters: [archived, silent])
    #expect(UtilityReminder.due(book, today: DateOnly(year: 2026, month: 11, day: 22)).isEmpty)
  }

  @Test func billsOfAProviderCompareByMonth() {
    func bill(
      _ year: Int, _ month: Int, _ total: Int64, _ provider: String = "Water Co"
    )
      -> UtilityBill
    {
      UtilityBill(
        provider: provider, period: MonthKey(year: year, month: month),
        totalE4: AmountE4(whole: total), recordedAt: Self.at)
    }
    let bills = [
      bill(2025, 11, 3_800), bill(2026, 10, 4_100), bill(2026, 11, 4_400),
      bill(2026, 11, 900, "Power Co"), bill(2026, 11, 100),
    ]
    let comparison = UtilityBills.compare(
      bills, provider: "water co", month: MonthKey(year: 2026, month: 11))
    #expect(comparison.current == AmountE4(whole: 4_500), "two bills of one month add up")
    #expect(comparison.previousMonth == AmountE4(whole: 4_100))
    #expect(comparison.previousYear == AmountE4(whole: 3_800))
    #expect(UtilityBills.providers(bills) == ["Power Co", "Water Co"])
  }
}
