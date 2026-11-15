import Foundation
import Testing

@testable import CorePlanning

@Suite("Official inflation: the built-in Rosstat table and the figures counted from it")
struct OfficialInflationTests {
  func dec(_ s: String) -> Decimal { Decimal(string: s, locale: Locale(identifier: "en_US_POSIX"))! }
  let table = OfficialInflation.builtIn

  @Test("A month reads as the percent change, 101.62 is 1.62 %")
  func monthValue() {
    #expect(table.monthlyPercent(year: 2026, month: 1) == dec("1.62"))
    #expect(table.monthlyPercent(year: 2022, month: 3) == dec("7.61"))
    #expect(table.monthlyPercent(year: 2025, month: 8) == dec("-0.40"))
  }

  @Test("The month after the last known one has no data, not zero")
  func noDataAfterLast() {
    #expect(table.latest?.year == 2026)
    #expect(table.latest?.month == 9)
    #expect(table.monthlyPercent(year: 2026, month: 10) == nil)
    #expect(table.monthlyPercent(year: 2019, month: 12) == nil)
    #expect(table.monthlyPercent(year: 2026, month: 13) == nil)
    #expect(table.yearOnYearPercent(year: 2026, month: 10) == nil)
  }

  @Test("Year over year from the months matches the published December-to-December figure")
  func yearOnYearMatchesPublished() {
    let published: [Int: String] = [
      2020: "4.91", 2021: "8.39", 2022: "11.94", 2023: "7.42", 2024: "9.52", 2025: "5.59",
    ]
    for (year, percent) in published {
      let counted = table.yearOnYearPercent(year: year, month: 12)
      #expect(counted != nil)
      let diff = abs((counted ?? 0) - dec(percent))
      // Each month is published to two decimals, so twelve of them drift by a few hundredths.
      #expect(diff <= dec("0.06"), "year \(year): counted \(String(describing: counted))")
    }
  }

  @Test("Year over year needs all twelve months")
  func yearOnYearNeedsTwelve() {
    #expect(table.yearOnYearPercent(year: 2020, month: 11) == nil)
    #expect(table.yearOnYearPercent(year: 2021, month: 1) != nil)
    #expect(table.yearOnYearPercent(year: 2026, month: 9) != nil)
  }

  @Test("Accumulated over a span multiplies the months after the start through the end")
  func cumulative() {
    // Two months of 1.62 % and 0.73 %: 1.0162 * 1.0073 - 1 = 2.3...
    let c = table.cumulativePercent(
      fromYear: 2025, month: 12, throughYear: 2026, month: 2)
    #expect(c != nil)
    #expect(abs((c ?? 0) - dec("2.3618")) < dec("0.0001"))
    #expect(
      table.cumulativePercent(fromYear: 2026, month: 9, throughYear: 2026, month: 10) == nil)
    #expect(table.cumulativePercent(fromYear: 2026, month: 3, throughYear: 2026, month: 2) == nil)
    #expect(
      table.cumulativePercent(fromYear: 2026, month: 5, throughYear: 2026, month: 5) == 0)
  }

  @Test("A table with a gap gives no figure across the gap")
  func gap() {
    let t = OfficialInflation(months: [
      .init(year: 2026, month: 1, index: dec("101")), .init(year: 2026, month: 3, index: dec("101")),
    ])
    #expect(t.cumulativePercent(fromYear: 2025, month: 12, throughYear: 2026, month: 3) == nil)
    #expect(t.monthlyPercent(year: 2026, month: 2) == nil)
  }

  @Test("The built-in table runs without a gap from January 2020 to September 2026")
  func builtInComplete() {
    #expect(table.months.count == 6 * 12 + 9)
    #expect(table.cumulativePercent(fromYear: 2019, month: 12, throughYear: 2026, month: 9) != nil)
  }
}
