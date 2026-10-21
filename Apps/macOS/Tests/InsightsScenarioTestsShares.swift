import AppCore
import XCTest

@testable import OhMyMoney

/// The arithmetic every table and card of the figures stands on: shares split by the largest
/// remainder so a level always reads 100.00 %, ratios and changes against an empty or negative
/// base, quantiles, whole rubles half away from zero, and periods at the edges of months, of
/// years and of a leap February.
final class InsightsScenarioSharesTests: XCTestCase {
  private func rub(_ value: Int64) -> AmountE4 { AmountE4(whole: value) }

  // MARK: - Shares

  /// Three equal lines: 33.34 + 33.33 + 33.33 — the lost unit goes to the first in list order.
  func testThreeEqualLinesReadOneHundredPercent() {
    let shares = Shares.basisPoints([rub(1), rub(1), rub(1)])
    XCTAssertEqual(shares, [3_334, 3_333, 3_333])
  }

  /// Seven equal lines: the four lost units go to the first four.
  func testSevenEqualLinesHandOutTheLostUnitsInListOrder() {
    let shares = Shares.basisPoints(Array(repeating: rub(10), count: 7))
    XCTAssertEqual(shares, [1_429, 1_429, 1_429, 1_429, 1_428, 1_428, 1_428])
    XCTAssertEqual(shares.compactMap { $0 }.reduce(0, +), Shares.whole)
  }

  /// A line refunds outweighed has no share; the others still make the whole.
  func testANegativeLineHasNoShareAndTheRestAreWhole() {
    let shares = Shares.basisPoints([rub(100), rub(-50), rub(300)])
    XCTAssertEqual(shares, [2_500, nil, 7_500])
  }

  /// Nothing positive: every share is «not enough data», never a division by zero.
  func testNothingPositiveGivesNoShares() {
    XCTAssertEqual(Shares.basisPoints([rub(0), rub(-1)]), [nil, nil])
    XCTAssertEqual(Shares.basisPoints([]), [])
  }

  /// A zero line beside a positive one has no share; the positive one is all of it.
  func testAZeroLineHasNoShare() {
    XCTAssertEqual(Shares.basisPoints([.zero, rub(5)]), [nil, Shares.whole])
  }

  /// Amounts whose sum leaves Int64 are shared without trapping.
  func testHugeAmountsAreSharedWithoutOverflow() {
    let huge = AmountE4(raw: .max)
    let shares = Shares.basisPoints([huge, huge, huge])
    XCTAssertEqual(shares.compactMap { $0 }.reduce(0, +), Shares.whole)
    XCTAssertEqual(shares, [3_334, 3_333, 3_333])
  }

  /// A kopeck beside a million: the kopeck rounds down to nothing, the total is still whole.
  func testATinyLineBesideAHugeOneKeepsTheWhole() {
    let shares = Shares.basisPoints([rub(1_000_000), AmountE4(raw: 100)])
    XCTAssertEqual(shares, [Shares.whole, 0])
  }

  /// Ratios round half away from zero; an empty base gives none.
  func testRatiosRoundHalfAwayFromZero() {
    XCTAssertEqual(Shares.ratio(rub(1), of: rub(3)), 3_333)
    XCTAssertEqual(Shares.ratio(rub(2), of: rub(3)), 6_667)
    XCTAssertEqual(Shares.ratio(rub(-1), of: rub(8)), -1_250)
    XCTAssertNil(Shares.ratio(rub(1), of: .zero))
    XCTAssertNil(Shares.ratio(rub(1), of: rub(-3)))
  }

  /// A change against nothing has no percentage; against a negative month it is measured
  /// against its size.
  func testAChangeAgainstNothingOrANegativeBase() {
    XCTAssertNil(Change(current: rub(100), previous: .zero).basisPoints)
    XCTAssertEqual(Change(current: .zero, previous: rub(-100)).basisPoints, 10_000)
    XCTAssertEqual(Change(current: rub(150), previous: rub(100)).basisPoints, 5_000)
    XCTAssertEqual(Change(current: rub(50), previous: rub(100)).delta, rub(-50))
  }

  // MARK: - Quantiles and rubles

  /// Type 7 quantiles: linear between ranks, the ends for 0 and 1.
  func testQuantilesAreLinearBetweenRanks() {
    XCTAssertNil(Quantile.value([], 0.5))
    XCTAssertEqual(Quantile.value([7], 0.9), 7)
    XCTAssertEqual(Quantile.value([4, 1, 3, 2], 0.5), Decimal(string: "2.5"))
    XCTAssertEqual(Quantile.value([10, 20], Decimal(string: "0.1")!), 11)
    XCTAssertEqual(Quantile.value([5, 9, 1], 0), 1)
    XCTAssertEqual(Quantile.value([5, 9, 1], 1), 9)
  }

  /// Whole rubles of the charts and of `amount_rub`: half away from zero, both signs.
  func testWholeRublesRoundHalfAwayFromZero() {
    XCTAssertEqual(AmountE4(raw: 5_000).wholeRubles, 1)
    XCTAssertEqual(AmountE4(raw: -5_000).wholeRubles, -1)
    XCTAssertEqual(AmountE4(raw: 14_999).wholeRubles, 1)
    XCTAssertEqual(AmountE4(raw: -25_000).wholeRubles, -3)
    XCTAssertEqual(AmountE4.zero.wholeRubles, 0)
  }

  // MARK: - Periods

  /// On 31 March the same span of February is 1–28, in a leap year 1–29.
  func testTheSameSpanOfFebruaryIsClippedToItsLength() {
    XCTAssertEqual(
      Period.sameSpanOfPreviousMonth(today: .d(3, 31)).range, DayRange(.d(2, 1), .d(2, 28)))
    XCTAssertEqual(
      Period.sameSpanOfPreviousMonth(today: .d(3, 31, 2028)).range,
      DayRange(.d(2, 1, 2028), .d(2, 29, 2028)))
  }

  /// In January the previous month is December of the year before.
  func testTheSameSpanOfJanuaryIsInTheYearBefore() {
    XCTAssertEqual(
      Period.sameSpanOfPreviousMonth(today: .d(1, 15)).range,
      DayRange(.d(12, 1, 2025), .d(12, 15, 2025)))
    XCTAssertEqual(Period.monthToDate(today: .d(1, 1)).range, DayRange(.d(1, 1), .d(1, 1)))
  }

  /// The period before: a month, a year, twelve months, a span of days by its own length.
  func testThePeriodBeforeEachKind() {
    XCTAssertEqual(
      Period.month(MonthKey(year: 2026, month: 1)).previous,
      .month(MonthKey(year: 2025, month: 12)))
    XCTAssertEqual(Period.year(2026).previous, .year(2025))
    XCTAssertEqual(
      Period.twelveMonths(endingWith: MonthKey(year: 2026, month: 2)).previous.range,
      DayRange(.d(3, 1, 2024), .d(2, 28, 2025)))
    let days = Period.days(DayRange(.d(3, 1), .d(3, 10)))
    XCTAssertEqual(days.previous.range, DayRange(.d(2, 19), .d(2, 28)))
  }

  /// Twelve months ending with February 2026 start on 1 March 2025.
  func testTwelveMonthsEndingWithFebruary() {
    let period = Period.twelveMonths(endingWith: MonthKey(year: 2026, month: 2))
    XCTAssertEqual(period.range, DayRange(.d(3, 1, 2025), .d(2, 28)))
    XCTAssertEqual(period.months.count, 12)
    XCTAssertTrue(period.isWholeMonths)
  }

  /// Whole months: a month and a leap February written as days are; half a month is not.
  func testWholeMonthsAndHalfMonths() {
    XCTAssertTrue(Period.month(MonthKey(year: 2028, month: 2)).isWholeMonths)
    XCTAssertTrue(Period.days(DayRange(.d(2, 1, 2028), .d(2, 29, 2028))).isWholeMonths)
    XCTAssertFalse(Period.days(DayRange(.d(2, 1, 2028), .d(2, 28, 2028))).isWholeMonths)
    XCTAssertFalse(Period.days(DayRange(.d(3, 2), .d(3, 31))).isWholeMonths)
    XCTAssertFalse(Period.days(DayRange(.d(3, 31), .d(3, 1))).isWholeMonths)
  }

  /// An unfinished month on its 31st is compared with the whole of a shorter month before;
  /// a finished one with the whole month before.
  func testComparisonSpansClipToTheMonthBefore() {
    let march = Period.month(MonthKey(year: 2026, month: 3))
    let spans = march.comparisonSpans(today: .d(3, 31))
    XCTAssertEqual(spans.current, DayRange(.d(3, 1), .d(3, 31)))
    XCTAssertEqual(spans.previous, DayRange(.d(2, 1), .d(2, 28)))
    let done = march.comparisonSpans(today: .d(4, 2))
    XCTAssertEqual(done.current, march.range)
    XCTAssertEqual(done.previous, DayRange(.d(2, 1), .d(2, 28)))
  }

  /// A leap day of a year still running is compared with 28 February of the year before.
  func testALeapDayIsComparedWithTheLastDayOfFebruary() {
    let spans = Period.year(2028).comparisonSpans(today: .d(2, 29, 2028))
    XCTAssertEqual(spans.current, DayRange(.d(1, 1, 2028), .d(2, 29, 2028)))
    XCTAssertEqual(spans.previous, DayRange(.d(1, 1, 2027), .d(2, 28, 2027)))
  }

  /// A period that has not begun is compared with an empty span.
  func testAPeriodNotBegunComparesWithNothing() {
    let april = Period.month(MonthKey(year: 2026, month: 4))
    let spans = april.comparisonSpans(today: .d(3, 20))
    XCTAssertTrue(spans.current.isEmpty)
    XCTAssertTrue(spans.previous.isEmpty)
  }

  /// A span over New Year: its months and its days.
  func testASpanOverNewYear() {
    let range = DayRange(.d(12, 30, 2025), .d(1, 2))
    XCTAssertEqual(range.dayCount, 4)
    XCTAssertEqual(range.months, [MonthKey(year: 2025, month: 12), MonthKey(year: 2026, month: 1)])
    XCTAssertTrue(range.contains(.d(12, 31, 2025)))
    XCTAssertFalse(range.contains(.d(1, 3)))
    let empty = DayRange(.d(1, 2), .d(1, 1))
    XCTAssertEqual(empty.dayCount, 0)
    XCTAssertFalse(empty.contains(.d(1, 1)))
  }

  /// A month later on the 31st lands on the last day of a short month; a year from a leap day
  /// on 28 February.
  func testAddingMonthsClipsToTheLastDay() {
    XCTAssertEqual(DateOnly.d(1, 31).adding(months: 1), .d(2, 28))
    XCTAssertEqual(DateOnly.d(1, 31, 2028).adding(months: 1), .d(2, 29, 2028))
    XCTAssertEqual(DateOnly.d(2, 29, 2028).adding(months: 12), .d(2, 28, 2029))
    XCTAssertEqual(DateOnly.d(12, 31, 2025).adding(days: 1), .d(1, 1))
    XCTAssertEqual(MonthKey(year: 2026, month: 12).next, MonthKey(year: 2027, month: 1))
    XCTAssertEqual(MonthKey(year: 2100, month: 2).dayCount, 28)
    XCTAssertEqual(MonthKey(year: 2000, month: 2).dayCount, 29)
  }
}
