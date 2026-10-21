import Foundation
import Testing

@testable import CoreKit

/// The settings of the capital and the cushion as the `settings` table keeps them: absent keys
/// are the defaults, a damaged value keeps its default, and what is written reads back.
@Suite("The settings of the capital and the cushion")
struct CapitalSettingsTests {
  @Test func theKeys() {
    #expect(
      CapitalSettings.storageKeys == [
        "cushion.targetMonths", "cushion.targetMonth", "cushion.outOfFreeMoney",
        "cushion.historyMonths",
      ])
  }

  @Test func nothingStoredIsTheDefaults() {
    let settings = CapitalSettings(storedValues: [:])
    #expect(settings == .standard)
    #expect(settings.targetMonths == nil)
    #expect(settings.targetMonth == nil)
    #expect(!settings.outOfFreeMoney)
    #expect(settings.historyMonths == 6)
  }

  @Test func writtenValuesReadBack() {
    let settings = CapitalSettings(
      targetMonths: 6, targetMonth: MonthKey(year: 2027, month: 3), outOfFreeMoney: true,
      historyMonths: 12)
    let rows = settings.storedValues.compactMapValues { $0 }
    #expect(rows[CapitalSettings.targetMonthKey] == "2027-03")
    #expect(rows[CapitalSettings.outOfFreeMoneyKey] == "1")
    #expect(CapitalSettings(storedValues: rows) == settings)
  }

  @Test func noGoalDeletesItsKeys() {
    let stored = CapitalSettings.standard.storedValues
    #expect(stored[CapitalSettings.targetMonthsKey] == .some(nil))
    #expect(stored[CapitalSettings.targetMonthKey] == .some(nil))
    #expect(stored[CapitalSettings.historyMonthsKey] == "6")
  }

  /// A value that does not read, or lies outside its range, keeps its default.
  @Test func damagedValuesKeepTheirDefaults() {
    let settings = CapitalSettings(storedValues: [
      CapitalSettings.targetMonthsKey: "25",
      CapitalSettings.targetMonthKey: "2027-03-01",
      CapitalSettings.outOfFreeMoneyKey: "maybe",
      CapitalSettings.historyMonthsKey: "2",
    ])
    #expect(settings == .standard)
    let zero = CapitalSettings(storedValues: [
      CapitalSettings.targetMonthsKey: "0", CapitalSettings.targetMonthKey: "2027-13",
      CapitalSettings.historyMonthsKey: "thirteen",
    ])
    #expect(zero == .standard)
  }

  @Test func theEdgesOfTheRangesRead() {
    let low = CapitalSettings(storedValues: [
      CapitalSettings.targetMonthsKey: " 1 ", CapitalSettings.historyMonthsKey: "3",
      CapitalSettings.outOfFreeMoneyKey: "true",
    ])
    #expect(low.targetMonths == 1)
    #expect(low.historyMonths == 3)
    #expect(low.outOfFreeMoney)
    let high = CapitalSettings(storedValues: [
      CapitalSettings.targetMonthsKey: "24", CapitalSettings.historyMonthsKey: "12",
      CapitalSettings.outOfFreeMoneyKey: "0",
    ])
    #expect(high.targetMonths == 24)
    #expect(high.historyMonths == 12)
    #expect(!high.outOfFreeMoney)
  }

  @Test func anAssetIsGoneFromTheDayItWasDisposedOf() {
    let sold = Asset(
      name: "Машина", kind: .vehicle, disposedOn: DateOnly(year: 2026, month: 5, day: 10))
    #expect(!sold.isDisposed(on: DateOnly(year: 2026, month: 5, day: 9)))
    #expect(sold.isDisposed(on: DateOnly(year: 2026, month: 5, day: 10)))
    #expect(
      !Asset(name: "Квартира", kind: .realty).isDisposed(on: DateOnly(year: 2099, month: 1, day: 1))
    )
    #expect(
      AssetKind.allCases.map(\.rawValue) == [
        "vehicle", "realty", "equipment", "investment", "other",
      ])
  }
}
