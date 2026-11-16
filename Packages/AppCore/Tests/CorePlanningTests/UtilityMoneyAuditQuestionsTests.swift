import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CorePlanning

@Suite("Utilities: money audit regressions")
struct UtilityMoneyAuditQuestionsTests {
  private let month = MonthKey(year: 2026, month: 11)
  private let at = Date(timeIntervalSince1970: 1_790_000_000)

  @Test func billsInDifferentCurrenciesCannotBeAddedAsOneAmount() {
    let bills = [
      UtilityBill(
        provider: "Synthetic provider", period: month, totalE4: AmountE4(whole: 100),
        currency: .rub, recordedAt: at),
      UtilityBill(
        provider: "Synthetic provider", period: month, totalE4: AmountE4(whole: 10),
        currency: .usd, recordedAt: at),
    ]
    let result = UtilityBills.compare(bills, provider: "Synthetic provider", month: month)
    #expect(result.current == nil)
    let rates = DayRates(series: [
      .usd: [DayRate(day: CalendarContext.utc.day(of: at), perUnit: 90)]
    ])
    let converted = UtilityBills.compare(
      bills, provider: "Synthetic provider", month: month,
      ledger: Ledger(dataset: Dataset(), calendar: .utc),
      dayRates: rates)
    #expect(converted.current == AmountE4(whole: 1_000))
  }

  @Test func anUnrepresentableUsageCostIsNotFree() throws {
    let meter = UtilityMeter(
      name: "Synthetic meter", kind: .electricity, tariffE4: AmountE4(whole: 1_000))
    let readings = [
      UtilityReading(
        meterId: meter.id, day: month.firstDay, valueE4: .zero, recordedAt: at),
      UtilityReading(
        meterId: meter.id, day: month.lastDay, valueE4: .inputLimit, recordedAt: at),
    ]
    let result = try #require(UtilityUsage.months(of: meter, readings: readings)[month])
    #expect(result.quantityE4 == .inputLimit)
    #expect(result.costE4 == nil)
    #expect(result.costState == .cannotCompute)
  }

  @Test func paymentUsesItsSavedRateRatherThanTodaysOrTheBillsRate() {
    let day = DateOnly(year: 2026, month: 11, day: 8)
    let id = UUID()
    let payment = TransactionEntry(
      transaction: Transaction(
        id: id, kind: .expense, occurredAt: CalendarContext.utc.noon(of: day), currency: .usd,
        amountE4: AmountE4(whole: 20), rate: 95, amountRubE4: AmountE4(whole: 1_900)),
      parts: [
        TransactionPart(
          transactionId: id, amountE4: AmountE4(whole: 20), amountRubE4: AmountE4(whole: 1_900))
      ])
    let bill = UtilityBill(
      provider: "Synthetic", period: month, totalE4: AmountE4(whole: 10), currency: .usd,
      transactionId: id, recordedAt: at)
    let rates = DayRates(series: [.usd: [DayRate(day: month.firstDay, perUnit: 100)]])
    let result = UtilityBills.compare(
      [bill], provider: bill.provider, month: month,
      ledger: Ledger(dataset: Dataset(entries: [payment]), calendar: .utc), dayRates: rates)
    #expect(result.current == AmountE4(whole: 950))
  }

  @Test func paymentInAnotherCurrencyUsesItsRecordedDayForTheBillCurrency() throws {
    let zone = try #require(TimeZone(identifier: "Asia/Makassar"))
    let day = month.firstDay
    let id = UUID()
    let payment = TransactionEntry(
      transaction: Transaction(
        id: id, kind: .expense,
        occurredAt: CalendarContext(timeZone: zone).moment(day, hour: 1, minute: 0),
        amountE4: AmountE4(whole: 900), timeZoneId: zone.identifier),
      parts: [TransactionPart(transactionId: id, amountE4: AmountE4(whole: 900))])
    let bill = UtilityBill(
      provider: "Synthetic", period: month, totalE4: AmountE4(whole: 10), currency: .usd,
      transactionId: id, recordedAt: at)
    let rates = DayRates(series: [
      .usd: [
        DayRate(day: day.adding(days: -1), perUnit: 80), DayRate(day: day, perUnit: 90),
      ]
    ])
    let result = UtilityBills.compare(
      [bill], provider: bill.provider, month: month,
      ledger: Ledger(dataset: Dataset(entries: [payment]), calendar: .utc), dayRates: rates)
    #expect(result.current == AmountE4(whole: 900))
  }

  @Test func anUnpaidBillUsesItsRecordedDayAndTheLastPublishedRate() {
    let bill = UtilityBill(
      provider: "Synthetic", period: month, totalE4: AmountE4(whole: 10), currency: .usd,
      recordedAt: CalendarContext.utc.noon(of: month.firstDay.adding(days: 7)))
    let rates = DayRates(series: [
      .usd: [
        DayRate(day: month.firstDay, perUnit: 90),
        DayRate(day: month.firstDay.adding(days: 10), perUnit: 100),
      ]
    ])
    let result = UtilityBills.compare(
      [bill], provider: bill.provider, month: month,
      ledger: Ledger(dataset: Dataset(), calendar: .utc),
      dayRates: rates)
    #expect(result.current == AmountE4(whole: 900))
  }

  @Test func aMissingTariffIsDifferentFromAnUncomputableCost() throws {
    let meter = UtilityMeter(name: "Synthetic", kind: .electricity)
    let readings = [
      UtilityReading(meterId: meter.id, day: month.firstDay, valueE4: .zero, recordedAt: at),
      UtilityReading(
        meterId: meter.id, day: month.lastDay, valueE4: AmountE4(whole: 1), recordedAt: at),
    ]
    let result = try #require(UtilityUsage.months(of: meter, readings: readings)[month])
    #expect(result.costState == .noTariff)
    #expect(result.costE4 == nil)
  }

  @Test func anOverflowRemainsVisibleAfterALaterValidReadingInTheSameMonth() throws {
    let meter = UtilityMeter(
      name: "Synthetic", kind: .electricity, tariffE4: AmountE4(whole: 1_000))
    let readings = [
      UtilityReading(meterId: meter.id, day: month.firstDay, valueE4: .zero, recordedAt: at),
      UtilityReading(
        meterId: meter.id, day: month.firstDay.adding(days: 1), valueE4: .inputLimit, recordedAt: at
      ),
      UtilityReading(meterId: meter.id, day: month.lastDay, valueE4: .inputLimit, recordedAt: at),
    ]
    let result = try #require(UtilityUsage.months(of: meter, readings: readings)[month])
    #expect(result.costState == .cannotCompute)
    #expect(result.costE4 == nil)
  }

  @Test func monthlyCostOverflowAlsoNeedsTheReadingsChecked() throws {
    let meter = UtilityMeter(name: "Synthetic", kind: .electricity, tariffE4: AmountE4(whole: 500))
    let readings = [0, 1, 2].map { index in
      UtilityReading(
        meterId: meter.id, day: month.firstDay.adding(days: index),
        valueE4: AmountE4(raw: AmountE4.inputLimit.raw * Int64(index)), recordedAt: at)
    }
    let result = try #require(UtilityUsage.months(of: meter, readings: readings)[month])
    #expect(result.costE4 == nil)
    #expect(result.costState == .cannotCompute)
  }

  @Test func aDeletedPaymentFallsBackToTheBillsDay() {
    let day = month.firstDay
    let id = UUID()
    let payment = TransactionEntry(
      transaction: Transaction(
        id: id, kind: .expense, occurredAt: CalendarContext.utc.noon(of: day.adding(days: 8)),
        currency: .usd, amountE4: AmountE4(whole: 10), amountRubE4: AmountE4(whole: 950),
        deletedAt: at),
      parts: [
        TransactionPart(
          transactionId: id, amountE4: AmountE4(whole: 10), amountRubE4: AmountE4(whole: 950))
      ])
    let bill = UtilityBill(
      provider: "Synthetic", period: month, totalE4: AmountE4(whole: 10), currency: .usd,
      transactionId: id, recordedAt: CalendarContext.utc.noon(of: day))
    let rates = DayRates(series: [
      .usd: [
        DayRate(day: day, perUnit: 90), DayRate(day: day.adding(days: 8), perUnit: 100),
      ]
    ])
    let result = UtilityBills.compare(
      [bill], provider: bill.provider, month: month,
      ledger: Ledger(dataset: Dataset(entries: [payment]), calendar: .utc), dayRates: rates)
    #expect(result.current == AmountE4(whole: 900))
  }
}
