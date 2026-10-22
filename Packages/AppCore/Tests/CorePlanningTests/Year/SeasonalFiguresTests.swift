import CoreKit
import Foundation
import Testing

@testable import CorePlanning

/// Shared helpers of the year-plan suites: months, rubles and a synthetic history.
enum YearFx {
  static func m(_ year: Int, _ month: Int) -> MonthKey { MonthKey(year: year, month: month) }
  static func day(_ iso: String) -> DateOnly {
    DateOnly(iso: iso) ?? DateOnly(year: 1970, month: 1, day: 1)
  }
  static func rub(_ whole: Int64) -> AmountE4 { AmountE4(whole: whole) }
  static func id(_ number: Int) -> UUID {
    UUID(uuidString: String(format: "7E4A0000-0000-0000-0000-%012d", number)) ?? UUID()
  }

  /// A history of `count` complete months ending the month before `today`'s, one category,
  /// every month `base` rubles and the months in `heavy` (calendar month → rubles) dearer.
  static func history(
    category: UUID = id(1), months count: Int, today: DateOnly = day("2027-01-15"),
    base: Int64 = 100_000, heavy: [Int: Int64] = [:], growthPerYear: Int64 = 0
  ) -> SpendingHistory {
    let last = today.monthKey.previous
    let first = last.adding(months: -(count - 1))
    var series: [MonthKey: AmountE4] = [:]
    for month in MonthKey.range(first, through: last) {
      let yearsBack = Int64(last.months(to: month) < -11 ? 0 : 1)
      series[month] = rub((heavy[month.month] ?? base) + growthPerYear * yearsBack)
    }
    return SpendingHistory(
      byCategory: [category: series], byRoot: [category: series], firstMonth: first,
      lastCompleteMonth: last)
  }
}

@Suite("Seasonality: which months are dear")
struct SeasonalityTests {
  typealias Fx = YearFx

  @Test func aDearDecemberIsFoundOverTwoYears() throws {
    let history = Fx.history(months: 24, heavy: [12: 160_000])
    let seasonality = try #require(Seasonality.ofTotal(history: history).seasonality)
    #expect(seasonality.basis == .twoYears)
    #expect(seasonality.expensiveMonths.map(\.month) == [12])
    let december = try #require(seasonality.month(12))
    // 160 000 against the mean of the twelve averages, 105 000: 52.38 % above.
    #expect(december.indexBp == 15_238)
    #expect(december.aboveUsualBp == 5_238)
    #expect(december.samples == 2)
    #expect(seasonality.month(6)?.isExpensive == false)
  }

  @Test func aYearOfHistoryIsMarkedAsOne() throws {
    let history = Fx.history(months: 12, heavy: [12: 160_000])
    let seasonality = try #require(Seasonality.ofTotal(history: history).seasonality)
    #expect(seasonality.basis == .oneYear)
    #expect(seasonality.expensiveMonths.map(\.month) == [12])
    #expect(seasonality.month(12)?.samples == 1)
  }

  @Test func underAYearIsNotEnoughData() {
    let result = Seasonality.ofTotal(history: Fx.history(months: 11))
    #expect(result == .notEnoughData(monthsAvailable: 11))
    #expect(
      Seasonality.ofTotal(history: Fx.history(months: 0)) == .notEnoughData(monthsAvailable: 0))
  }

  @Test func aFlatYearHasNoExpensiveMonth() throws {
    let seasonality = try #require(
      Seasonality.ofTotal(history: Fx.history(months: 24)).seasonality)
    #expect(seasonality.expensiveMonths.isEmpty)
    #expect(seasonality.months.allSatisfy { $0.indexBp == 10_000 })
  }

  @Test func theHistoryStartsOnTheNextMonthWhenItBeganLate() {
    // The same 24 months, but the first record was on the 20th of the first month: only 23
    // complete months count, still two years' worth of nothing special — the basis is one year.
    var history = Fx.history(months: 24)
    history = SpendingHistory(
      byCategory: history.byCategory, byRoot: history.byRoot, total: history.total,
      firstMonth: history.firstMonth?.next, lastCompleteMonth: history.lastCompleteMonth)
    #expect(history.completeMonths().count == 23)
    #expect(Seasonality.ofTotal(history: history).seasonality?.basis == .oneYear)
  }
}

@Suite("The expensive month and the range of the end of the month")
struct ExpensiveMonthTests {
  typealias Fx = YearFx

  @Test func theThresholdIsDearerThanEightTenthsOfTheMonths() {
    let totals = (1...12).map { Fx.rub(Int64($0) * 1_000) }
    // Position 0.8 × 11 = 8.8 between 9 000 and 10 000.
    #expect(ExpensiveMonth.threshold(of: totals) == Fx.rub(9_800))
    // Order does not matter, and only the last twelve count.
    #expect(ExpensiveMonth.threshold(of: totals.reversed()) == Fx.rub(9_800))
    #expect(ExpensiveMonth.threshold(of: [Fx.rub(1)] + totals) == Fx.rub(9_800))
  }

  @Test func oneRenovationDoesNotSetTheLevel() {
    var totals = Array(repeating: Fx.rub(80_000), count: 11)
    totals.append(Fx.rub(900_000))
    #expect(ExpensiveMonth.threshold(of: totals) == Fx.rub(80_000) + Fx.rub(0))
    // The 80 % mark lies between the 10th and the 11th month, both ordinary.
  }

  @Test func underSixMonthsThereIsNoLevel() {
    #expect(ExpensiveMonth.threshold(of: Array(repeating: Fx.rub(1), count: 5)) == nil)
  }

  @Test func theRangeNeverFallsBelowTheForecast() {
    var heavy: [Int: Int64] = [:]
    for month in 1...12 { heavy[month] = Int64(month) * 10_000 }
    let history = Fx.history(months: 12, today: Fx.day("2027-01-15"), heavy: heavy)
    // The last twelve months are December…, ranked 10 000…120 000: level 98 000.
    let low = ExpensiveMonth.range(usual: Fx.rub(85_000), history: history)
    #expect(low.usual == Fx.rub(85_000))
    #expect(low.expensive == Fx.rub(98_000))
    #expect(low.hasSecondFigure)
    let high = ExpensiveMonth.range(usual: Fx.rub(110_000), history: history)
    #expect(high.expensive == Fx.rub(110_000))
    #expect(!high.hasSecondFigure)
    let short = ExpensiveMonth.range(usual: Fx.rub(1), history: Fx.history(months: 3))
    #expect(short.threshold == nil && short.expensive == short.usual)
  }
}

@Suite("The forecast of the year by category")
struct YearForecastTests {
  typealias Fx = YearFx

  @Test func theSameMonthOfLastYearTimesGrowth() throws {
    // 24 months: the earlier year 100 000 a month, the later one 110 000, December 200 000
    // in both years' pattern. Growth of the last three months over the same three a year
    // before is 1.1.
    var series: [MonthKey: AmountE4] = [:]
    let last = Fx.m(2026, 12)
    for month in MonthKey.range(Fx.m(2025, 1), through: last) {
      let year2026 = month.year == 2026
      var value: Int64 = year2026 ? 110_000 : 100_000
      if month.month == 12 { value = year2026 ? 220_000 : 200_000 }
      series[month] = Fx.rub(value)
    }
    let category = Fx.id(1)
    let history = SpendingHistory(
      byCategory: [category: series], byRoot: [category: series], firstMonth: Fx.m(2025, 1),
      lastCompleteMonth: last)
    let forecast = YearForecast.build(history: history, from: Fx.m(2027, 1))
    let row = try #require(forecast.category(category))
    #expect(row.method == .sameMonthLastYear)
    // Growth: (110+110+220) / (100+100+200) = 1.1. March: 110 000 × 1.1; December: 220 000 × 1.1.
    #expect(row.months[2].usual == Fx.rub(121_000))
    #expect(row.months[11].usual == Fx.rub(242_000))
    #expect(!forecast.lowData && forecast.basis == .twoYears)
    #expect(row.usualTotal == AmountE4.sum(row.months.map(\.usual)))
    #expect(row.months.allSatisfy { $0.expensive >= $0.usual })
    #expect(forecast.usualTotal == row.usualTotal)
  }

  @Test func underThirteenMonthsItIsTheAverage() throws {
    let history = Fx.history(months: 8, heavy: [10: 180_000])
    let forecast = YearForecast.build(history: history, from: Fx.m(2027, 1))
    let row = try #require(forecast.category(Fx.id(1)))
    #expect(row.method == .average)
    #expect(forecast.lowData)
    // Mean of seven months at 100 000 and one at 180 000 is 110 000.
    #expect(Set(row.months.map(\.usual)) == [Fx.rub(110_000)])
  }

  @Test func theRangeLiftsACheapMonthToTheExpensiveLevel() throws {
    let history = Fx.history(months: 24, heavy: [12: 300_000])
    let forecast = YearForecast.build(history: history, from: Fx.m(2027, 1))
    let row = try #require(forecast.category(Fx.id(1)))
    // Ordinary months stay 100 000 as usual; the 80 % level of the last 12 months is 100 000
    // as well, because only December is dear.
    #expect(row.months[5].usual == Fx.rub(100_000) && row.months[5].expensive == Fx.rub(100_000))
    #expect(row.months[11].usual == Fx.rub(300_000))
  }

  @Test func growthIsKeptBetweenHalfAndTwo() {
    var series: [MonthKey: AmountE4] = [:]
    let window = MonthKey.range(Fx.m(2025, 1), through: Fx.m(2026, 12))
    for month in window { series[month] = Fx.rub(month.year == 2025 ? 1_000 : 50_000) }
    #expect(YearForecast.growth(series: series, window: window) == 2)
    for month in window { series[month] = Fx.rub(month.year == 2025 ? 50_000 : 1_000) }
    #expect(YearForecast.growth(series: series, window: window) == Decimal(string: "0.5"))
    #expect(YearForecast.growth(series: [:], window: window) == 1)
  }

  @Test func spendingWithoutACategoryHasItsOwnRow() throws {
    let category = Fx.id(1)
    let months = MonthKey.range(Fx.m(2026, 1), through: Fx.m(2026, 12))
    var inCategory: [MonthKey: AmountE4] = [:]
    var total: [MonthKey: AmountE4] = [:]
    for month in months {
      inCategory[month] = Fx.rub(100)
      total[month] = Fx.rub(130)
    }
    let history = SpendingHistory(
      byCategory: [category: inCategory], byRoot: [category: inCategory], total: total,
      firstMonth: Fx.m(2026, 1), lastCompleteMonth: Fx.m(2026, 12))
    let forecast = YearForecast.build(history: history, from: Fx.m(2027, 1))
    #expect(forecast.category(nil)?.months.first?.usual == Fx.rub(30))
    #expect(forecast.total.first?.usual == Fx.rub(130))
  }

  @Test func noHistoryMeansNoRows() {
    let forecast = YearForecast.build(history: Fx.history(months: 0), from: Fx.m(2027, 1))
    #expect(forecast.categories.isEmpty)
    #expect(forecast.usualTotal == .zero && forecast.total.count == 12)
  }
}
