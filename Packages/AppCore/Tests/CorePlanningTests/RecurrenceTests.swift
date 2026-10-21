import CoreKit
import CorePlanning
import Foundation
import Testing

@Suite("Recurrence: stepping a schedule through the calendar")
struct RecurrenceTests {
  typealias Fx = SchedFx

  private func next(_ iso: String, _ rule: RecurrenceRule) -> DateOnly {
    Recurrence.next(after: Fx.day(iso), rule: rule)
  }

  /// The day comes from the rule: 31 January → 28 February → 31 March, not the 28th forever.
  @Test func theThirtyFirstIsClippedAndComesBack() {
    let rule = RecurrenceRule(freq: .monthly, day: 31)
    #expect(next("2026-01-31", rule) == Fx.day("2026-02-28"))
    #expect(next("2026-02-28", rule) == Fx.day("2026-03-31"))
    #expect(next("2026-03-31", rule) == Fx.day("2026-04-30"))
    #expect(next("2026-12-31", rule) == Fx.day("2027-01-31"))
    #expect(next("2028-01-31", rule) == Fx.day("2028-02-29"))
  }

  /// Without a day in the rule the occurrence's own day is all there is to keep.
  @Test func aRuleWithoutADayKeepsTheDayOfTheOccurrence() {
    let rule = RecurrenceRule(freq: .monthly)
    #expect(next("2026-01-31", rule) == Fx.day("2026-02-28"))
    #expect(next("2026-02-28", rule) == Fx.day("2026-03-28"))
  }

  @Test func intervalsOfMonthsAndYears() {
    #expect(
      next("2026-11-15", RecurrenceRule(freq: .monthly, interval: 3, day: 15))
        == Fx.day("2027-02-15"))
    #expect(
      next("2026-03-10", RecurrenceRule(freq: .yearly, interval: 2, day: 10, month: 3))
        == Fx.day("2028-03-10"))
    // A stored interval of 0 would never move: it counts as 1.
    let zero = RecurrenceRule(freq: .monthly, interval: 0, day: 5)
    #expect(zero.interval == 1)
    #expect(next("2026-09-05", zero) == Fx.day("2026-10-05"))
  }

  /// 29 February falls on the 28th in common years and comes back in the next leap year.
  @Test func february29OfAYearlyPayment() {
    let rule = RecurrenceRule(freq: .yearly, day: 29, month: 2)
    #expect(next("2028-02-29", rule) == Fx.day("2029-02-28"))
    #expect(next("2029-02-28", rule) == Fx.day("2030-02-28"))
    #expect(next("2031-02-28", rule) == Fx.day("2032-02-29"))
  }

  /// 2026-09-16 is a Wednesday, 2026-09-18 a Friday, 2026-09-19 a Saturday.
  @Test func weeklyStepsAndTheWeekday() {
    #expect(next("2026-09-19", RecurrenceRule(freq: .weekly)) == Fx.day("2026-09-26"))
    #expect(
      next("2026-09-18", RecurrenceRule(freq: .weekly, interval: 2, day: 5))
        == Fx.day("2026-10-02"))
    // A Wednesday occurrence of a Friday rule: the Friday of the next week.
    #expect(next("2026-09-16", RecurrenceRule(freq: .weekly, day: 5)) == Fx.day("2026-09-25"))
    // A Saturday occurrence of a Monday rule: the Monday after, never a day back.
    #expect(next("2026-09-19", RecurrenceRule(freq: .weekly, day: 1)) == Fx.day("2026-09-21"))
  }

  @Test func occurrencesStopAtTheEndDateAndTheLimit() {
    let rule = RecurrenceRule(freq: .monthly, day: 31)
    let from = Fx.day("2026-01-31")
    let through = Fx.day("2026-06-30")
    #expect(
      Recurrence.occurrences(from: from, through: through, rule: rule)
        == ["2026-01-31", "2026-02-28", "2026-03-31", "2026-04-30", "2026-05-31", "2026-06-30"]
        .map(Fx.day))
    #expect(
      Recurrence.occurrences(from: from, through: through, rule: rule, end: Fx.day("2026-04-15"))
        == ["2026-01-31", "2026-02-28", "2026-03-31"].map(Fx.day))
    #expect(
      Recurrence.occurrences(from: from, through: through, rule: rule, limit: 2)
        == ["2026-01-31", "2026-02-28"].map(Fx.day))
    #expect(
      Recurrence.occurrences(from: Fx.day("2026-07-31"), through: through, rule: rule).isEmpty)
  }

  /// The default `next_date` of a new payment, from 19 September 2026 (a Saturday).
  @Test func theFirstDateOnOrAfterADay() {
    let today = Fx.day("2026-09-19")
    func first(_ rule: RecurrenceRule) -> DateOnly { Recurrence.firstOnOrAfter(today, rule: rule) }
    #expect(first(RecurrenceRule(freq: .monthly, day: 31)) == Fx.day("2026-09-30"))
    #expect(first(RecurrenceRule(freq: .monthly, day: 19)) == Fx.day("2026-09-19"))
    #expect(first(RecurrenceRule(freq: .monthly, day: 10)) == Fx.day("2026-10-10"))
    #expect(first(RecurrenceRule(freq: .monthly)) == Fx.day("2026-09-19"))
    #expect(first(RecurrenceRule(freq: .weekly, day: 1)) == Fx.day("2026-09-21"))
    #expect(first(RecurrenceRule(freq: .weekly, day: 6)) == Fx.day("2026-09-19"))
    #expect(first(RecurrenceRule(freq: .yearly, day: 29, month: 2)) == Fx.day("2027-02-28"))
    #expect(first(RecurrenceRule(freq: .yearly, day: 31, month: 12)) == Fx.day("2026-12-31"))
    #expect(first(RecurrenceRule(freq: .yearly, day: 1, month: 9)) == Fx.day("2027-09-01"))
  }

  @Test func rulesOfAPaymentAndOfAnExpectedIncome() {
    let payment = ScheduledPayment(
      name: "Rent", amountE4: .zero, freq: .yearly, interval: 2, day: 10, month: 3)
    #expect(
      RecurrenceRule(payment: payment)
        == RecurrenceRule(freq: .yearly, interval: 2, day: 10, month: 3))
    let help = ExpectedIncome(
      name: "Help", kind: .recurring, totalE4: .zero, dueDate: Fx.day("2026-09-05"),
      freq: .monthly, day: 5)
    #expect(RecurrenceRule(expected: help) == RecurrenceRule(freq: .monthly, day: 5, month: 9))
    #expect(next("2026-09-05", RecurrenceRule(expected: help)) == Fx.day("2026-10-05"))
  }
}
