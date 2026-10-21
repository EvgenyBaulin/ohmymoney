import CoreKit
import Foundation
import Testing

@testable import CoreAccounting

/// When a deposit or a savings account pays its interest.
@Suite("The pay dates of a deposit")
struct DepositScheduleTests {
  func dates(_ terms: DepositTerms, after: String, through: String) -> [String] {
    DepositSchedule.payDates(terms: terms, after: day(after), through: day(through)).map(\.iso)
  }

  @Test func monthlyOnTheDayOfTheTermsAfterTheDayItWasOpened() {
    let terms = DepositTerms(
      rate: 16, period: .monthly, day: 15, openedOn: day("2026-01-10"))
    #expect(
      dates(terms, after: "2026-01-01", through: "2026-04-30")
        == ["2026-01-15", "2026-02-15", "2026-03-15", "2026-04-15"])
    // The day itself is not after `after`; the day of `through` is in.
    #expect(dates(terms, after: "2026-02-15", through: "2026-03-15") == ["2026-03-15"])
    #expect(dates(terms, after: "2026-03-15", through: "2026-03-15") == [])
  }

  @Test func aDayTheMonthDoesNotHaveIsItsLastDay() {
    let terms = DepositTerms(rate: 10, period: .monthly, day: 31)
    #expect(
      dates(terms, after: "2026-01-31", through: "2026-04-30")
        == ["2026-02-28", "2026-03-31", "2026-04-30"])
    #expect(dates(terms, after: "2028-01-31", through: "2028-02-29") == ["2028-02-29"])
  }

  @Test func withoutADayTheDayItWasOpenedElseTheLastDay() {
    let opened = DepositTerms(rate: 10, period: .monthly, openedOn: day("2026-01-31"))
    #expect(
      dates(opened, after: "2026-01-01", through: "2026-03-31")
        == ["2026-02-28", "2026-03-31"])
    let never = DepositTerms(rate: 10, period: .monthly)
    #expect(
      dates(never, after: "2026-01-31", through: "2026-03-31") == ["2026-02-28", "2026-03-31"])
  }

  @Test func nothingIsPaidOnOrBeforeTheDayItWasOpened() {
    let terms = DepositTerms(rate: 10, period: .monthly, day: 20, openedOn: day("2026-03-20"))
    #expect(
      dates(terms, after: "2026-01-01", through: "2026-05-31") == ["2026-04-20", "2026-05-20"])
  }

  @Test func quarterlyFromTheMonthItWasOpened() {
    let terms = DepositTerms(rate: 12, period: .quarterly, openedOn: day("2026-01-20"))
    #expect(
      dates(terms, after: "2026-01-01", through: "2026-12-31")
        == ["2026-04-20", "2026-07-20", "2026-10-20"])
    #expect(
      dates(terms, after: "2026-05-01", through: "2026-12-31") == ["2026-07-20", "2026-10-20"])
    #expect(
      dates(terms, after: "2026-07-20", through: "2027-01-20") == ["2026-10-20", "2027-01-20"])
  }

  @Test func quarterlyNeverOpenedPaysAtTheEndOfEachCalendarQuarter() {
    let terms = DepositTerms(rate: 12, period: .quarterly)
    #expect(
      dates(terms, after: "2026-01-01", through: "2026-12-31")
        == ["2026-03-31", "2026-06-30", "2026-09-30", "2026-12-31"])
  }

  @Test func atTheEndOnceOnTheDayItEnds() {
    let terms = DepositTerms(
      rate: 15, period: .atEnd, openedOn: day("2026-01-10"), endsOn: day("2026-07-10"))
    #expect(dates(terms, after: "2026-01-01", through: "2026-12-31") == ["2026-07-10"])
    #expect(dates(terms, after: "2026-01-01", through: "2026-07-09") == [])
    #expect(dates(terms, after: "2026-07-10", through: "2026-12-31") == [])
  }

  @Test func aDepositEndingBetweenTwoPayDatesPaysItsLastShortPeriodOnItsLastDay() {
    let terms = DepositTerms(
      rate: 16, period: .monthly, day: 15, openedOn: day("2025-12-15"),
      endsOn: day("2026-03-10"))
    #expect(
      dates(terms, after: "2026-01-01", through: "2026-12-31")
        == ["2026-01-15", "2026-02-15", "2026-03-10"])
    // Ending on a pay date: paid once.
    var onAPayDate = terms
    onAPayDate.endsOn = day("2026-03-15")
    #expect(
      dates(onAPayDate, after: "2026-01-01", through: "2026-12-31")
        == ["2026-01-15", "2026-02-15", "2026-03-15"])
  }

  @Test func theDaysOfAPeriodAreAfterItsStartThroughItsPayDate() {
    let terms = DepositTerms(rate: 16, period: .monthly, day: 15, openedOn: day("2026-01-10"))
    func period(_ iso: String) -> DepositPeriod? {
      DepositSchedule.period(terms: terms, containing: day(iso), firstCount: nil)
    }
    #expect(
      period("2026-02-15") == DepositPeriod(start: day("2026-01-15"), payDate: day("2026-02-15")))
    #expect(
      period("2026-02-16") == DepositPeriod(start: day("2026-02-15"), payDate: day("2026-03-15")))
    // The first period starts on the day it was opened.
    #expect(
      period("2026-01-11") == DepositPeriod(start: day("2026-01-10"), payDate: day("2026-01-15")))
    #expect(period("2026-01-10") == nil)
  }

  @Test func aPeriodWithNothingBeforeItStartsAtTheFirstCount() {
    let terms = DepositTerms(rate: 15, period: .atEnd, endsOn: day("2026-07-10"))
    #expect(
      DepositSchedule.period(
        terms: terms, containing: day("2026-03-01"), firstCount: day("2026-02-01"))
        == DepositPeriod(start: day("2026-02-01"), payDate: day("2026-07-10")))
    // Before the first count, or with none, the day earns in no period.
    #expect(
      DepositSchedule.period(
        terms: terms, containing: day("2026-01-15"), firstCount: day("2026-02-01"))
        == nil)
    #expect(
      DepositSchedule.period(terms: terms, containing: day("2026-03-01"), firstCount: nil) == nil)
    // After the deposit ends, nothing earns.
    #expect(
      DepositSchedule.period(
        terms: terms, containing: day("2026-07-11"), firstCount: day("2026-02-01"))
        == nil)
  }

  @Test func aSavingsAccountPeriodRunsFromThePayDateBefore() {
    let terms = DepositTerms(rate: 16, period: .monthly)
    #expect(
      DepositSchedule.period(
        terms: terms, containing: day("2026-03-01"), firstCount: day("2026-02-20"))
        == DepositPeriod(start: day("2026-02-28"), payDate: day("2026-03-31")))
  }

  /// Every day after the day of opening through the end earns in exactly one period, and the
  /// periods follow one another: one's pay date is the next one's start.
  @Test func thePeriodsCoverEveryDayOnce() {
    let all = [
      DepositTerms(rate: 10, period: .monthly, day: 31, openedOn: day("2025-11-30")),
      DepositTerms(
        rate: 10, period: .monthly, day: 5, openedOn: day("2025-11-30"), endsOn: day("2027-01-17")),
      DepositTerms(
        rate: 10, period: .quarterly, openedOn: day("2025-11-30"), endsOn: day("2027-02-01")),
      DepositTerms(
        rate: 10, period: .atEnd, openedOn: day("2025-11-30"), endsOn: day("2026-11-29")),
    ]
    for terms in all {
      var previous: DepositPeriod?
      var current = day("2025-12-01")
      let last = terms.endsOn ?? day("2026-12-31")
      while current <= last {
        let period = DepositSchedule.period(terms: terms, containing: current, firstCount: nil)
        #expect(period != nil, "\(current.iso) earns in no period")
        guard let period else { break }
        #expect(period.start < current && current <= period.payDate)
        if let previous, previous != period { #expect(previous.payDate == period.start) }
        previous = period
        current = DepositDays.adding(days: 1, to: current)
      }
    }
  }
}
