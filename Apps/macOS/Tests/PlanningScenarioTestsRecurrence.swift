import AppCore
import XCTest

@testable import OhMyMoney

/// A planned payment walked through the calendar the way the owner lives it: rent on the 31st
/// through a leap February and over New Year, a weekly class across the turn of the year, a
/// yearly insurance on 29 February, quarterly bills, and what one charge costs per month and
/// per year in every rhythm — including the edges a form can store (interval 0, odd days).
final class PlanningScenarioTestsRecurrence: XCTestCase {

  private func day(_ iso: String) -> DateOnly { DateOnly(iso: iso)! }

  private func walk(_ start: String, _ rule: RecurrenceRule, steps: Int) -> [String] {
    var current = day(start)
    var result = [current.iso]
    for _ in 0..<steps {
      current = Recurrence.next(after: current, rule: rule)
      result.append(current.iso)
    }
    return result
  }

  // MARK: Monthly

  func testRentOnThe31stWalksThroughALeapFebruaryAndBack() {
    let rule = RecurrenceRule(freq: .monthly, day: 31)
    XCTAssertEqual(
      walk("2027-12-31", rule, steps: 4),
      ["2027-12-31", "2028-01-31", "2028-02-29", "2028-03-31", "2028-04-30"])
  }

  func testRentOnThe31stInACommonFebruaryIsThe28th() {
    let rule = RecurrenceRule(freq: .monthly, day: 31)
    XCTAssertEqual(Recurrence.next(after: day("2027-01-31"), rule: rule), day("2027-02-28"))
  }

  func testTheThirtiethSurvivesFebruaryAndComesBackInMarch() {
    let rule = RecurrenceRule(freq: .monthly, day: 30)
    XCTAssertEqual(walk("2026-01-30", rule, steps: 2), ["2026-01-30", "2026-02-28", "2026-03-30"])
  }

  func testAMonthlyPaymentCrossesNewYear() {
    let rule = RecurrenceRule(freq: .monthly, day: 15)
    XCTAssertEqual(Recurrence.next(after: day("2026-12-15"), rule: rule), day("2027-01-15"))
  }

  func testEveryThreeMonthsOnThe31stLandsOnTheLastDayOfShortMonths() {
    let rule = RecurrenceRule(freq: .monthly, interval: 3, day: 31)
    XCTAssertEqual(
      walk("2026-03-31", rule, steps: 3), ["2026-03-31", "2026-06-30", "2026-09-30", "2026-12-31"])
  }

  func testEverySixMonthsAcrossTheYear() {
    let rule = RecurrenceRule(freq: .monthly, interval: 6, day: 10)
    XCTAssertEqual(Recurrence.next(after: day("2026-09-10"), rule: rule), day("2027-03-10"))
  }

  func testAStoredZeroIntervalStillMovesForward() {
    let rule = RecurrenceRule(freq: .monthly, interval: 0, day: 5)
    XCTAssertEqual(rule.interval, 1)
    XCTAssertEqual(Recurrence.next(after: day("2026-05-05"), rule: rule), day("2026-06-05"))
  }

  func testANegativeIntervalIsOne() {
    XCTAssertEqual(RecurrenceRule(freq: .weekly, interval: -3).interval, 1)
  }

  func testAStoredDayAboveThirtyOneIsTheLastDay() {
    let rule = RecurrenceRule(freq: .monthly, day: 45)
    XCTAssertEqual(Recurrence.next(after: day("2026-03-31"), rule: rule), day("2026-04-30"))
  }

  // MARK: Weekly

  func testAWeeklyClassCrossesNewYearOnItsWeekday() {
    // 2026-12-28 is a Monday.
    let rule = RecurrenceRule(freq: .weekly, day: 1)
    XCTAssertEqual(walk("2026-12-28", rule, steps: 2), ["2026-12-28", "2027-01-04", "2027-01-11"])
  }

  func testEveryTwoWeeksOnFridayFromAWednesday() {
    // 2026-10-14 is a Wednesday; two weeks on, the Friday of that week.
    let rule = RecurrenceRule(freq: .weekly, interval: 2, day: 5)
    let next = Recurrence.next(after: day("2026-10-14"), rule: rule)
    XCTAssertEqual(next, day("2026-10-30"))
    XCTAssertEqual(next.weekday, 5)
  }

  func testAWeeklyRuleWithAnImpossibleWeekdayKeepsSevenDays() {
    let rule = RecurrenceRule(freq: .weekly, day: 9)
    XCTAssertEqual(Recurrence.next(after: day("2026-10-14"), rule: rule), day("2026-10-21"))
  }

  func testTheFirstSundayOnOrAfterASunday() {
    // 2026-10-18 is a Sunday.
    let rule = RecurrenceRule(freq: .weekly, day: 7)
    XCTAssertEqual(Recurrence.firstOnOrAfter(day("2026-10-18"), rule: rule), day("2026-10-18"))
    XCTAssertEqual(Recurrence.firstOnOrAfter(day("2026-10-19"), rule: rule), day("2026-10-25"))
  }

  // MARK: Yearly

  func testInsuranceOn29FebruaryWalksEightYears() {
    let rule = RecurrenceRule(freq: .yearly, day: 29, month: 2)
    XCTAssertEqual(
      walk("2028-02-29", rule, steps: 4),
      ["2028-02-29", "2029-02-28", "2030-02-28", "2031-02-28", "2032-02-29"])
  }

  func testAYearlyPaymentOnNewYearsEve() {
    let rule = RecurrenceRule(freq: .yearly, day: 31, month: 12)
    XCTAssertEqual(Recurrence.next(after: day("2026-12-31"), rule: rule), day("2027-12-31"))
  }

  func testAYearlyRuleWithAnImpossibleMonthKeepsTheMonthOfTheDate() {
    let rule = RecurrenceRule(freq: .yearly, day: 3, month: 14)
    XCTAssertEqual(Recurrence.next(after: day("2026-07-03"), rule: rule), day("2027-07-03"))
  }

  func testTheFirstYearlyDateAfterItsDayThisYearIsNextYear() {
    let rule = RecurrenceRule(freq: .yearly, day: 1, month: 3)
    XCTAssertEqual(Recurrence.firstOnOrAfter(day("2026-03-02"), rule: rule), day("2027-03-01"))
    XCTAssertEqual(Recurrence.firstOnOrAfter(day("2026-03-01"), rule: rule), day("2026-03-01"))
  }

  func testAnchorsOfEachFrequency() {
    let date = day("2028-02-29")
    XCTAssertEqual(Recurrence.anchor(of: date, freq: .monthly).day, 29)
    XCTAssertNil(Recurrence.anchor(of: date, freq: .monthly).month)
    XCTAssertEqual(Recurrence.anchor(of: date, freq: .yearly).month, 2)
    XCTAssertEqual(Recurrence.anchor(of: date, freq: .weekly).day, date.weekday)
  }

  // MARK: Occurrences

  func testTheMonthlyOccurrencesOfAYearAreTwelve() {
    let rule = RecurrenceRule(freq: .monthly, day: 31)
    let dates = Recurrence.occurrences(
      from: day("2028-01-31"), through: day("2028-12-31"), rule: rule)
    XCTAssertEqual(dates.count, 12)
    XCTAssertEqual(dates[1], day("2028-02-29"))
  }

  func testOccurrencesStopOnTheEndDateEvenWhenItIsTheFirst() {
    let rule = RecurrenceRule(freq: .monthly, day: 1)
    let dates = Recurrence.occurrences(
      from: day("2026-11-01"), through: day("2027-12-31"), rule: rule, end: day("2026-11-01"))
    XCTAssertEqual(dates, [day("2026-11-01")])
  }

  func testOccurrencesBeforeTheFirstAreNone() {
    let rule = RecurrenceRule(freq: .weekly)
    XCTAssertTrue(
      Recurrence.occurrences(from: day("2026-11-01"), through: day("2026-10-01"), rule: rule)
        .isEmpty)
  }

  func testAWeeklyRhythmOverAYearHasFiftyThreeDatesAtMost() {
    let rule = RecurrenceRule(freq: .weekly)
    let dates = Recurrence.occurrences(
      from: day("2026-01-01"), through: day("2026-12-31"), rule: rule)
    XCTAssertEqual(dates.count, 53)
  }

  // MARK: What a charge costs

  private let thousand = AmountE4(whole: 1_000)

  func testAWeeklyChargeIsFiftyTwoAYear() {
    let rule = RecurrenceRule(freq: .weekly)
    XCTAssertEqual(SubscriptionMath.yearlyEquivalent(thousand, rule: rule), AmountE4(whole: 52_000))
    XCTAssertEqual(
      SubscriptionMath.monthlyEquivalent(thousand, rule: rule), try AmountE4(decimal: 4_333.3333))
  }

  func testAQuarterlyChargePerMonthAndPerYear() {
    let rule = RecurrenceRule(freq: .monthly, interval: 3)
    XCTAssertEqual(
      SubscriptionMath.monthlyEquivalent(thousand, rule: rule), try AmountE4(decimal: 333.3333))
    XCTAssertEqual(SubscriptionMath.yearlyEquivalent(thousand, rule: rule), AmountE4(whole: 4_000))
  }

  func testAYearlyChargeEveryTwoYears() {
    let rule = RecurrenceRule(freq: .yearly, interval: 2)
    XCTAssertEqual(SubscriptionMath.yearlyEquivalent(thousand, rule: rule), AmountE4(whole: 500))
    XCTAssertEqual(
      SubscriptionMath.monthlyEquivalent(thousand, rule: rule), try AmountE4(decimal: 41.6667))
  }

  func testRublesOfADollarChargeNeedARate() {
    XCTAssertNil(SubscriptionMath.rubles(thousand, in: .usd, rubPerUnit: [:]))
    XCTAssertNil(SubscriptionMath.rubles(thousand, in: .usd, rubPerUnit: [.usd: 0]))
    XCTAssertEqual(
      SubscriptionMath.rubles(thousand, in: .usd, rubPerUnit: [.usd: Decimal(string: "92.5")!]),
      AmountE4(whole: 92_500))
    XCTAssertEqual(SubscriptionMath.rubles(thousand, in: .rub, rubPerUnit: [:]), thousand)
  }

  func testAHugeChargeInRublesIsClampedNotATrap() {
    let huge = AmountE4(raw: .max / 2)
    let rubles = SubscriptionMath.rubles(huge, in: .usd, rubPerUnit: [.usd: 1_000])
    XCTAssertEqual(rubles, AmountE4(raw: .max))
  }

  // MARK: Price history

  private func payment(_ amount: Int64 = 1_000) -> ScheduledPayment {
    ScheduledPayment(
      name: "Music", kind: .subscription, amountE4: AmountE4(whole: amount),
      nextDate: day("2026-11-01"))
  }

  func testThePriceOnADayIsTheLatestRowNotLater() {
    let music = payment()
    let rows = [
      SubscriptionPrice(
        paymentId: music.id, date: day("2026-01-01"), amountE4: AmountE4(whole: 800)),
      SubscriptionPrice(
        paymentId: music.id, date: day("2026-06-01"), amountE4: AmountE4(whole: 900)),
    ]
    XCTAssertEqual(
      SubscriptionMath.price(of: music, on: day("2025-12-31"), prices: rows), music.amountE4)
    XCTAssertEqual(
      SubscriptionMath.price(of: music, on: day("2026-05-31"), prices: rows), AmountE4(whole: 800))
    XCTAssertEqual(
      SubscriptionMath.price(of: music, on: day("2026-06-01"), prices: rows), AmountE4(whole: 900))
  }

  func testRowsOfAnotherPaymentDoNotPriceThisOne() {
    let music = payment()
    let other = SubscriptionPrice(
      paymentId: UUID(), date: day("2026-01-01"), amountE4: AmountE4(whole: 1))
    XCTAssertEqual(
      SubscriptionMath.price(of: music, on: day("2026-10-01"), prices: [other]), music.amountE4)
  }

  func testAChangeOfCurrencyRemovesTheHistory() {
    let music = payment()
    var dollars = music
    dollars.currency = .usd
    let row = SubscriptionPrice(
      paymentId: music.id, date: day("2026-01-01"), amountE4: AmountE4(whole: 1))
    let edit = SubscriptionMath.priceEdit(
      previous: music, updated: dollars, prices: [row], today: day("2026-10-14"), since: nil)
    XCTAssertEqual(edit.removed, [row.id])
    XCTAssertTrue(edit.rows.isEmpty)
  }

  func testTheSameAmountChangesNothing() {
    let music = payment()
    let edit = SubscriptionMath.priceEdit(
      previous: music, updated: music, prices: [], today: day("2026-10-14"),
      since: day("2026-10-01"))
    XCTAssertEqual(edit, PriceEdit(rows: [], removed: []))
  }

  func testANewPriceKeepsTheOverduePastAtTheOldOne() {
    let music = payment()
    var dearer = music
    dearer.amountE4 = AmountE4(whole: 1_200)
    let edit = SubscriptionMath.priceEdit(
      previous: music, updated: dearer, prices: [], today: day("2026-10-14"),
      since: day("2026-10-01"))
    XCTAssertEqual(edit.rows.count, 2)
    XCTAssertTrue(
      edit.rows.contains { $0.date == day("2026-10-14") && $0.amountE4 == AmountE4(whole: 1_200) })
    XCTAssertTrue(
      edit.rows.contains { $0.date == day("2026-10-01") && $0.amountE4 == AmountE4(whole: 1_000) })
  }

  func testANewPriceAfterAChargeAheadStartsTheDayAfterIt() {
    let music = payment()
    var dearer = music
    dearer.amountE4 = AmountE4(whole: 1_200)
    let edit = SubscriptionMath.priceEdit(
      previous: music, updated: dearer, prices: [], today: day("2026-10-14"), since: nil,
      charged: day("2026-10-20"))
    XCTAssertEqual(edit.rows.map(\.date), [day("2026-10-21")])
  }

  func testAPriceComingWithinTheWindowIsAnnouncedOnce() {
    let music = payment()
    let rows = [
      SubscriptionPrice(paymentId: music.id, date: day("2026-10-20"), amountE4: music.amountE4),
      SubscriptionPrice(
        paymentId: music.id, date: day("2026-10-25"), amountE4: AmountE4(whole: 1_300)),
    ]
    let change = SubscriptionMath.upcomingPriceChange(
      of: music, prices: rows, today: day("2026-10-14"), within: 14)
    XCTAssertEqual(change?.date, day("2026-10-25"))
    XCTAssertEqual(change?.old, music.amountE4)
    XCTAssertNil(
      SubscriptionMath.upcomingPriceChange(
        of: music, prices: rows, today: day("2026-10-14"), within: 5))
  }
}
