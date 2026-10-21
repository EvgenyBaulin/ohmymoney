import AppCore
import XCTest

@testable import OhMyMoney

/// When a deposit or a savings account pays its interest, as the owner opens one on an awkward
/// day: the 31st in short months, a quarter counted from the day it was opened, a deposit that
/// ends between two pay dates or on one, interest only at the end, and the period a day earns in.
final class AccountsScenarioDepositScheduleTests: XCTestCase {
  private func d(_ year: Int, _ month: Int, _ day: Int) -> DateOnly {
    DateOnly(year: year, month: month, day: day)
  }

  private func dates(
    _ terms: DepositTerms, after: DateOnly, through: DateOnly
  ) -> [DateOnly] {
    DepositSchedule.payDates(terms: terms, after: after, through: through)
  }

  func testMonthlyOnThe31stIsTheLastDayOfEveryShortMonth() {
    let terms = DepositTerms(rate: 16, period: .monthly, day: 31)
    XCTAssertEqual(
      dates(terms, after: d(2026, 1, 31), through: d(2026, 5, 31)),
      [d(2026, 2, 28), d(2026, 3, 31), d(2026, 4, 30), d(2026, 5, 31)])
  }

  func testMonthlyOnThe30thInALeapFebruaryIsThe29th() {
    let terms = DepositTerms(rate: 16, period: .monthly, day: 30)
    XCTAssertEqual(
      dates(terms, after: d(2028, 1, 30), through: d(2028, 3, 30)),
      [d(2028, 2, 29), d(2028, 3, 30)])
  }

  func testMonthlyWithoutADayPaysOnTheDayItWasOpenedAndNotOnThatDayItself() {
    let terms = DepositTerms(rate: 10, period: .monthly, openedOn: d(2026, 1, 15))
    XCTAssertEqual(
      dates(terms, after: d(2026, 1, 1), through: d(2026, 3, 20)),
      [d(2026, 2, 15), d(2026, 3, 15)])
  }

  func testASavingsAccountNeverOpenedPaysOnTheLastDay() {
    let terms = DepositTerms(rate: 10, period: .monthly)
    XCTAssertEqual(
      dates(terms, after: d(2026, 11, 15), through: d(2027, 1, 31)),
      [d(2026, 11, 30), d(2026, 12, 31), d(2027, 1, 31)])
  }

  func testQuarterlyCountsFromTheMonthItWasOpened() {
    let terms = DepositTerms(rate: 10, period: .quarterly, openedOn: d(2026, 2, 10))
    XCTAssertEqual(
      dates(terms, after: d(2026, 2, 10), through: d(2026, 12, 31)),
      [d(2026, 5, 10), d(2026, 8, 10), d(2026, 11, 10)])
  }

  func testQuarterlyNeverOpenedPaysAtTheEndOfCalendarQuarters() {
    let terms = DepositTerms(rate: 10, period: .quarterly)
    XCTAssertEqual(
      dates(terms, after: d(2026, 1, 1), through: d(2026, 12, 31)),
      [d(2026, 3, 31), d(2026, 6, 30), d(2026, 9, 30), d(2026, 12, 31)])
  }

  func testQuarterlyFromAnAfterMidQuarterStillFindsTheRightMonth() {
    let terms = DepositTerms(rate: 10, period: .quarterly, day: 5, openedOn: d(2025, 11, 5))
    XCTAssertEqual(
      dates(terms, after: d(2026, 3, 20), through: d(2026, 9, 1)),
      [d(2026, 5, 5), d(2026, 8, 5)])
  }

  func testAtTheEndPaysOnceOnTheLastDay() {
    let terms = DepositTerms(
      rate: 18, period: .atEnd, openedOn: d(2026, 3, 1), endsOn: d(2026, 9, 1))
    XCTAssertEqual(dates(terms, after: d(2026, 3, 1), through: d(2027, 1, 1)), [d(2026, 9, 1)])
    XCTAssertTrue(dates(terms, after: d(2026, 3, 1), through: d(2026, 8, 31)).isEmpty)
  }

  func testAtTheEndWithoutAnEndPaysNothing() {
    let terms = DepositTerms(rate: 18, period: .atEnd)
    XCTAssertTrue(dates(terms, after: d(2026, 1, 1), through: d(2030, 1, 1)).isEmpty)
  }

  func testADepositEndingBetweenPayDatesPaysTheShortPeriodOnItsLastDay() {
    let terms = DepositTerms(rate: 12, period: .monthly, day: 1, endsOn: d(2026, 3, 15))
    XCTAssertEqual(
      dates(terms, after: d(2026, 1, 1), through: d(2026, 6, 1)),
      [d(2026, 2, 1), d(2026, 3, 1), d(2026, 3, 15)])
  }

  func testADepositEndingOnAPayDatePaysThatDayOnce() {
    let terms = DepositTerms(rate: 12, period: .monthly, day: 1, endsOn: d(2026, 3, 1))
    XCTAssertEqual(
      dates(terms, after: d(2026, 1, 1), through: d(2026, 6, 1)), [d(2026, 2, 1), d(2026, 3, 1)])
  }

  func testNoWindowNoDates() {
    let terms = DepositTerms(rate: 12, period: .monthly, day: 1)
    XCTAssertTrue(dates(terms, after: d(2026, 5, 1), through: d(2026, 5, 1)).isEmpty)
    XCTAssertTrue(dates(terms, after: d(2026, 6, 1), through: d(2026, 5, 1)).isEmpty)
  }

  func testMonthlyAcrossNewYear() {
    let terms = DepositTerms(rate: 12, period: .monthly, day: 25)
    XCTAssertEqual(
      dates(terms, after: d(2026, 12, 1), through: d(2027, 2, 1)),
      [d(2026, 12, 25), d(2027, 1, 25)])
  }

  // MARK: The period of a day

  func testADayEarnsFromThePayDateBeforeToTheNextOne() {
    let terms = DepositTerms(rate: 12, period: .monthly, day: 1, openedOn: d(2026, 1, 5))
    XCTAssertEqual(
      DepositSchedule.period(terms: terms, containing: d(2026, 2, 10), firstCount: nil),
      DepositPeriod(start: d(2026, 2, 1), payDate: d(2026, 3, 1)))
  }

  func testThePayDateItselfEndsItsPeriod() {
    let terms = DepositTerms(rate: 12, period: .monthly, day: 1, openedOn: d(2026, 1, 5))
    XCTAssertEqual(
      DepositSchedule.period(terms: terms, containing: d(2026, 3, 1), firstCount: nil),
      DepositPeriod(start: d(2026, 2, 1), payDate: d(2026, 3, 1)))
  }

  func testTheFirstPeriodStartsOnTheDayItWasOpened() {
    let terms = DepositTerms(rate: 12, period: .monthly, day: 1, openedOn: d(2026, 1, 5))
    XCTAssertEqual(
      DepositSchedule.period(terms: terms, containing: d(2026, 1, 20), firstCount: nil),
      DepositPeriod(start: d(2026, 1, 5), payDate: d(2026, 2, 1)))
  }

  func testNoPeriodOnTheOpeningDayOrAfterTheEnd() {
    let terms = DepositTerms(
      rate: 12, period: .monthly, day: 1, openedOn: d(2026, 1, 5), endsOn: d(2026, 6, 1))
    XCTAssertNil(DepositSchedule.period(terms: terms, containing: d(2026, 1, 5), firstCount: nil))
    XCTAssertNil(DepositSchedule.period(terms: terms, containing: d(2026, 6, 2), firstCount: nil))
  }

  func testAtTheEndNeverOpenedStartsFromTheFirstCount() {
    let terms = DepositTerms(rate: 12, period: .atEnd, endsOn: d(2026, 12, 1))
    XCTAssertEqual(
      DepositSchedule.period(terms: terms, containing: d(2026, 5, 1), firstCount: d(2026, 2, 1)),
      DepositPeriod(start: d(2026, 2, 1), payDate: d(2026, 12, 1)))
    XCTAssertNil(
      DepositSchedule.period(terms: terms, containing: d(2026, 5, 1), firstCount: nil),
      "nothing to start from")
    XCTAssertNil(
      DepositSchedule.period(terms: terms, containing: d(2026, 1, 1), firstCount: d(2026, 2, 1)),
      "a day before the first count earns in no period")
  }
}

/// The interest a deposit earns, worked out by hand for each case: a plain month, money paid in
/// mid-period, a period over New Year into a leap year, a day in the middle of a period, interest
/// joining the balance, and what is still to come to the day a deposit ends.
final class AccountsScenarioDepositInterestTests: XCTestCase {
  private func d(_ year: Int, _ month: Int, _ day: Int) -> DateOnly {
    DateOnly(year: year, month: month, day: day)
  }

  private func rub(_ whole: Int64) -> AmountE4 { AmountE4(whole: whole) }

  func testAMonthOf30DaysAt16PercentOnAHundredThousand() {
    // 100 000 × 16 % × 30 / 365 = 1 315.068… → 1 315.07
    let terms = DepositTerms(rate: 16, period: .monthly, day: 1)
    let amount = DepositInterest.expected(
      terms: terms, segments: [(d(2026, 9, 1), rub(100_000))],
      period: DepositPeriod(start: d(2026, 9, 1), payDate: d(2026, 10, 1)))
    XCTAssertEqual(amount, AmountE4(raw: 13_150_700))
  }

  func testMoneyPaidInEarnsFromTheNextDay() {
    // 15 days on 100 000 and 15 on 200 000 at 16 %: 4 500 000 × 0.16 / 365 = 1 972.60
    let terms = DepositTerms(rate: 16, period: .monthly, day: 1)
    let amount = DepositInterest.expected(
      terms: terms, segments: [(d(2026, 9, 1), rub(100_000)), (d(2026, 9, 16), rub(200_000))],
      period: DepositPeriod(start: d(2026, 9, 1), payDate: d(2026, 10, 1)))
    XCTAssertEqual(amount, AmountE4(raw: 19_726_000))
  }

  func testAPeriodOverNewYearIntoALeapYearSplitsTheYears() {
    // 16 days of 2027 / 365 + 15 days of 2028 / 366 on 100 000 at 12 %:
    // 526.0274 + 491.8033 = 1 017.83
    let terms = DepositTerms(rate: 12, period: .monthly, day: 15)
    let amount = DepositInterest.expected(
      terms: terms, segments: [(d(2027, 12, 1), rub(100_000))],
      period: DepositPeriod(start: d(2027, 12, 15), payDate: d(2028, 1, 15)))
    XCTAssertEqual(amount, AmountE4(raw: 10_178_300))
  }

  func testAnEmptyBalanceEarnsNothing() {
    let terms = DepositTerms(rate: 16, period: .monthly, day: 1)
    XCTAssertEqual(
      DepositInterest.expected(
        terms: terms, segments: [(d(2026, 9, 1), .zero)],
        period: DepositPeriod(start: d(2026, 9, 1), payDate: d(2026, 10, 1))), .zero)
  }

  func testWhatIsAccruedByMidPeriodIsItsShare() {
    // 15 days on 100 000 at 16 %: 657.53
    let terms = DepositTerms(rate: 16, period: .monthly, day: 1)
    let accrued = DepositInterest.accrued(
      terms: terms, segments: [(d(2026, 9, 1), rub(100_000))],
      period: DepositPeriod(start: d(2026, 9, 1), payDate: d(2026, 10, 1)),
      through: d(2026, 9, 16))
    XCTAssertEqual(InterestMath.cents(accrued), AmountE4(raw: 6_575_300))
  }

  func testNothingIsAccruedOnTheFirstDayOrPastThePayDate() {
    let terms = DepositTerms(rate: 16, period: .monthly, day: 1)
    let segments = [(from: d(2026, 9, 1), amount: rub(100_000))]
    let period = DepositPeriod(start: d(2026, 9, 1), payDate: d(2026, 10, 1))
    XCTAssertEqual(
      DepositInterest.accrued(
        terms: terms, segments: segments, period: period, through: d(2026, 9, 1)), 0)
    XCTAssertEqual(
      DepositInterest.accrued(
        terms: terms, segments: segments, period: period, through: d(2026, 12, 1)),
      DepositInterest.accrued(
        terms: terms, segments: segments, period: period, through: d(2026, 10, 1)),
      "the period stops on its pay date")
  }

  func testInterestPaidOntoTheAccountJoinsTheBalanceFromItsDay() {
    let joined = DepositInterest.compounded(
      [(d(2026, 9, 1), rub(100_000))], adding: [(d(2026, 10, 1), AmountE4(raw: 13_150_700))])
    XCTAssertEqual(joined.map(\.from), [d(2026, 9, 1), d(2026, 10, 1)])
    XCTAssertEqual(joined.map(\.amount), [rub(100_000), AmountE4(raw: 1_013_150_700)])
  }

  func testNothingToAddLeavesTheSegments() {
    let segments = [(from: d(2026, 9, 1), amount: rub(5))]
    XCTAssertEqual(DepositInterest.compounded(segments, adding: []).map(\.amount), [rub(5)])
  }

  func testAMovementAfterTheInterestKeepsTheInterestOnTop() {
    let joined = DepositInterest.compounded(
      [(d(2026, 9, 1), rub(100_000)), (d(2026, 10, 15), rub(50_000))],
      adding: [(d(2026, 10, 1), rub(1_000))])
    XCTAssertEqual(joined.map(\.amount), [rub(100_000), rub(101_000), rub(51_000)])
  }

  func testASavingsAccountHasNoProjectionToAnEnd() {
    let terms = DepositTerms(rate: 16, period: .monthly, day: 1)
    XCTAssertNil(
      DepositInterest.projectionToEnd(
        terms: terms, segments: [(d(2026, 9, 1), rub(100_000))], today: d(2026, 9, 10)))
  }

  func testAnEndedDepositHasNothingLeftToPay() {
    let terms = DepositTerms(
      rate: 16, period: .monthly, day: 1, openedOn: d(2026, 1, 1), endsOn: d(2026, 6, 1))
    XCTAssertEqual(
      DepositInterest.projectionToEnd(
        terms: terms, segments: [(d(2026, 1, 1), rub(100_000))], today: d(2026, 7, 1)), .zero)
  }

  func testACapitalizingDepositEarnsOnItsInterest() {
    // 1 October: 100 000 × 12 % × 30 / 365 = 986.30, joining the balance;
    // 1 November: 100 986.30 × 12 % × 31 / 365 = 1 029.23 — 2 015.53 in all.
    let terms = DepositTerms(
      rate: 12, period: .monthly, day: 1, openedOn: d(2026, 9, 1), endsOn: d(2026, 11, 1))
    XCTAssertEqual(
      DepositInterest.projectionToEnd(
        terms: terms, segments: [(d(2026, 9, 1), rub(100_000))], today: d(2026, 9, 10)),
      AmountE4(raw: 20_155_300))
  }

  func testInterestPaidElsewhereDoesNotCompound() {
    // 986.30 + 100 000 × 12 % × 31 / 365 (1 019.18) = 2 005.48
    let terms = DepositTerms(
      rate: 12, period: .monthly, day: 1, payoutAccountId: UUID(), openedOn: d(2026, 9, 1),
      endsOn: d(2026, 11, 1))
    XCTAssertFalse(terms.capitalizes)
    XCTAssertEqual(
      DepositInterest.projectionToEnd(
        terms: terms, segments: [(d(2026, 9, 1), rub(100_000))], today: d(2026, 9, 10)),
      AmountE4(raw: 20_054_800))
  }
}
