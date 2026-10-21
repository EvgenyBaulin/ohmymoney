import CoreAccounting
import CoreAnalytics
import CoreKit
import CoreSample
import Foundation
import Testing

@testable import CorePlanning

/// «Другое…»: every N weeks, months or years, N from 1 to 24 — not only the presets — through
/// the calendar written out by hand, the last day of the month and 29 February included.
@Suite("Schedules of «Другое…»: any interval through the calendar")
struct RecurrenceOtherIntervalTests {
  typealias Fx = CashFx

  static let seeds: [UInt64] = Array(1...60)

  /// A random payment of any unit and any interval of «Другое…», its next date on its rule.
  static func payment(seed: UInt64) -> ScheduledPayment {
    var random = SeededRandom(seed: seed &+ 1_000)
    let freq = random.choice(from: [Frequency.weekly, .monthly, .yearly])
    var payment = ScheduledPayment(
      name: "Other", amountE4: AmountE4(whole: 100), freq: freq,
      interval: random.int(in: FrequencyInterval.range))
    let year = random.int(in: 2024...2029)
    let month = random.int(in: 1...12)
    switch freq {
    case .weekly:
      let weekday = random.int(in: 1...7)
      payment.day = weekday
      payment.nextDate = DateOnly(year: year, month: month, day: random.int(in: 1...28))
        .weekStart.adding(days: weekday - 1)
    case .monthly:
      let day = random.chance(1, outOf: 2) ? 31 : random.int(in: 28...31)
      payment.day = day
      payment.nextDate = DateOnly(
        year: year, month: month, day: min(day, PlainCalendar.daysIn(year, month)))
    case .yearly:
      let february = random.chance(1, outOf: 2)
      let chosen = february ? 2 : month
      let day = february ? 29 : random.int(in: 1...PlainCalendar.daysIn(2000, chosen))
      payment.month = chosen
      payment.day = day
      payment.nextDate = DateOnly(
        year: year, month: chosen, day: min(day, PlainCalendar.daysIn(year, chosen)))
    }
    return payment
  }

  /// Ten years of due dates are exactly the days the rule names — counted from the next date,
  /// every N units, on the day or on the last day of a shorter month.
  @Test(arguments: seeds)
  func anyIntervalNamesTheDaysOfTheRule(_ seed: UInt64) {
    let payment = Self.payment(seed: seed)
    guard let next = payment.nextDate else { return }
    let through = next.adding(days: 10 * 366)
    let stepped = Recurrence.occurrences(
      from: next, through: through, rule: RecurrenceRule(payment: payment), limit: 10_000)
    let walked = PlainCalendar.days(from: next, through: through).filter {
      PlainCalendar.isDue($0, of: payment)
    }
    #expect(stepped == walked, "seed \(seed): \(payment.freq) × \(payment.interval)")
    // Stepping back from any of them comes to the one before.
    let rule = RecurrenceRule(payment: payment)
    for (earlier, later) in zip(stepped, stepped.dropFirst()) {
      #expect(ScheduledMatching.previous(before: later, rule: rule) == earlier, "seed \(seed)")
    }
  }

  /// The free sum over a year takes exactly the due dates of the rule, whatever the interval.
  @Test(arguments: seeds)
  func theFreeSumTakesEveryDueOfAnyInterval(_ seed: UInt64) {
    var payment = Self.payment(seed: seed)
    payment.id = Fx.id(170)
    payment.categoryId = Fx.housing
    // Moved into the year ahead: the same rule, its next due on or after tomorrow.
    let rule = RecurrenceRule(payment: payment)
    var next = payment.nextDate ?? Fx.today
    while next <= Fx.today { next = Recurrence.next(after: next, rule: rule) }
    while ScheduledMatching.previous(before: next, rule: rule) > Fx.today {
      next = ScheduledMatching.previous(before: next, rule: rule)
    }
    payment.nextDate = next
    var fx = Fx()
    fx.settings.reserveGoalPlan = false
    fx.count([(Fx.main, .rub, "100000")], at: Fx.at("2026-09-01", 9))
    fx.scheduled = [payment]
    let until = Fx.today.adding(days: 365)
    let dues = PlainCalendar.days(from: next, through: until).filter {
      PlainCalendar.isDue($0, of: payment)
    }
    #expect(
      fx.plan(until: until.iso).scheduled
        == AmountE4(whole: 100 * Int64(dues.count)), "seed \(seed)")
  }

  /// Every two years from 29 February 2028: 28 February 2030, then 29 February 2032.
  @Test func everyTwoYearsFromALeapDay() {
    let rule = RecurrenceRule(freq: .yearly, interval: 2, day: 29, month: 2)
    let dues = Recurrence.occurrences(
      from: Fx.day("2028-02-29"), through: Fx.day("2034-12-31"), rule: rule)
    #expect(
      dues == [
        Fx.day("2028-02-29"), Fx.day("2030-02-28"), Fx.day("2032-02-29"), Fx.day("2034-02-28"),
      ])
  }

  /// Every five months on the 31st from January: 30 June, 30 November, 30 April, 30 September —
  /// each the last day of its month, the 31st never lost.
  @Test func everyFiveMonthsOnTheLastDay() {
    let rule = RecurrenceRule(freq: .monthly, interval: 5, day: 31)
    let dues = Recurrence.occurrences(
      from: Fx.day("2026-01-31"), through: Fx.day("2027-12-31"), rule: rule)
    #expect(
      dues == [
        Fx.day("2026-01-31"), Fx.day("2026-06-30"), Fx.day("2026-11-30"), Fx.day("2027-04-30"),
        Fx.day("2027-09-30"),
      ])
  }

  /// Every three weeks on Wednesday, and every four months on the 29th through February of a
  /// leap year and of a common one.
  @Test func everyThreeWeeksAndEveryFourMonths() {
    let weeks = Recurrence.occurrences(
      from: Fx.day("2026-09-02"), through: Fx.day("2026-11-01"),
      rule: RecurrenceRule(freq: .weekly, interval: 3, day: 3))
    #expect(weeks == [Fx.day("2026-09-02"), Fx.day("2026-09-23"), Fx.day("2026-10-14")])
    let months = Recurrence.occurrences(
      from: Fx.day("2027-10-29"), through: Fx.day("2029-03-01"),
      rule: RecurrenceRule(freq: .monthly, interval: 4, day: 29))
    #expect(
      months == [
        Fx.day("2027-10-29"), Fx.day("2028-02-29"), Fx.day("2028-06-29"), Fx.day("2028-10-29"),
        Fx.day("2029-02-28"),
      ])
  }
}

/// The intervals «Другое…» offers.
enum FrequencyInterval {
  static let range = 1...24
}
