import CoreKit
import Foundation
import Testing

@testable import CoreRates

/// A custom currency has no bank: its rate on a day is the last one the owner typed for that
/// day or before it, never provisional, and before the first one there is none — not a guess.
@Suite("Rates of custom currencies come from their own history")
struct CustomCurrencyRatesTests {
  let tether = CurrencyCode("UST")
  let first = DateOnly(year: 2026, month: 9, day: 10)
  let second = DateOnly(year: 2026, month: 9, day: 20)

  func typed(_ day: DateOnly, _ value: Decimal) -> Rate {
    Rate(date: day, currency: tether, rubPerUnit: value, nominal: 1, source: .manual)
  }

  var table: RateTable { RateTable(rates: [typed(first, 95), typed(second, 97)]) }

  @Test func theRateOfADayIsTheLastTypedNotAfterIt() {
    #expect(table.rate(for: tether, on: first)?.perUnit == 95)
    #expect(table.rate(for: tether, on: DateOnly(year: 2026, month: 9, day: 15))?.perUnit == 95)
    #expect(table.rate(for: tether, on: second)?.perUnit == 97)
    #expect(table.rate(for: tether, on: DateOnly(year: 2026, month: 12, day: 31))?.perUnit == 97)
  }

  @Test func beforeTheFirstRateThereIsNone() {
    let before = DateOnly(year: 2026, month: 9, day: 9)
    #expect(table.rate(for: tether, on: before) == nil)
    #expect(table.resolve(tether, on: before) == nil)
    #expect(RateTable().resolve(tether, on: first) == nil)
  }

  @Test func itIsNeverProvisionalAndNeverAskedOfTheBank() {
    let between = DateOnly(year: 2026, month: 9, day: 15)
    let resolved = table.resolve(tether, on: between)
    #expect(resolved?.rate.date == first)
    #expect(resolved?.isProvisional == false)
    #expect(!table.needsFetch(currency: tether, on: between))
    #expect(!RateTable().needsFetch(currency: tether, on: between))
    #expect(!RateTable.isAskedOfTheBank(tether))
    #expect(!RateTable.isAskedOfTheBank(.rub))
    #expect(RateTable.isAskedOfTheBank(.usd))
    #expect(RateTable().needsFetch(currency: .usd, on: between))
  }

  @Test func theBanksSnapshotLeavesItAlone() {
    let snapshot = RateSnapshot(
      date: second,
      rates: [.usd: Rate(date: second, currency: .usd, rubPerUnit: 80, source: .cbr)],
      source: .cbr)
    let merged = table.merging(snapshot)
    #expect(merged.history(of: tether).map(\.date) == [second, first])
    #expect(merged.rate(for: .usd, on: second)?.perUnit == 80)
  }

  @Test func theBankNeverOverwritesATypedRate() {
    let bank = RateSnapshot(
      date: second, rates: [tether: Rate(date: second, currency: tether, rubPerUnit: 1)],
      source: .cbr)
    #expect(table.merging(bank).rate(for: tether, on: second)?.perUnit == 97)
  }

  @Test func anOperationInItIsNeverRefinedByTheBank() {
    let usage = RateTable.RateUsage(
      currency: tether, day: second, source: .manual, isProvisional: true,
      appliedRateDate: first)
    #expect(RateTable.refinement(for: [usage], with: table).isEmpty)
  }
}
