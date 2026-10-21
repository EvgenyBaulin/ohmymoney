import CoreAccounting
import CoreAnalytics
import CoreKit
import CoreSample
import Foundation
import Testing

@testable import CorePlanning

/// The frequency presets of a scheduled payment — «Каждую неделю», «Раз в 2 недели», «Каждый
/// месяц», «Раз в 2 месяца», «Раз в квартал», «Раз в полгода», «Каждый год», «Разово» — and
/// «В последний день месяца» (a stored day 31; 29 for a yearly February), stepped through
/// years of calendar, leap years included, against the calendar written out by hand
/// (`PlainCalendar`).
@Suite("Schedules through the calendar: presets, month ends and leap years")
struct RecurrencePropertyTests {
  typealias Fx = CashFx

  static let seeds: [UInt64] = Array(1...40)

  /// A preset as it is saved: a frequency and an interval.
  static let presets: [(name: String, freq: Frequency, interval: Int)] = [
    ("weekly", .weekly, 1), ("every two weeks", .weekly, 2), ("monthly", .monthly, 1),
    ("every two months", .monthly, 2), ("quarterly", .monthly, 3),
    ("half-yearly", .monthly, 6), ("yearly", .yearly, 1),
  ]

  /// A random payment of a preset, its `next_date` a due date of its rule, the day of the
  /// month the last one («В последний день месяца») about half the time.
  static func payment(seed: UInt64) -> ScheduledPayment {
    var random = SeededRandom(seed: seed)
    let preset = random.choice(from: presets)
    var payment = ScheduledPayment(
      name: preset.name, amountE4: AmountE4(whole: 100), freq: preset.freq,
      interval: preset.interval)
    let year = random.int(in: 2025...2028)
    let month = random.int(in: 1...12)
    switch preset.freq {
    case .weekly:
      let weekday = random.int(in: 1...7)
      payment.day = weekday
      payment.nextDate = DateOnly(year: year, month: month, day: random.int(in: 1...28))
        .weekStart.adding(days: weekday - 1)
    case .monthly:
      let day = random.chance(1, outOf: 2) ? 31 : random.int(in: 1...31)
      payment.day = day
      payment.nextDate = DateOnly(
        year: year, month: month, day: min(day, PlainCalendar.daysIn(year, month)))
    case .yearly:
      let lastDay = random.chance(1, outOf: 2)
      let day =
        lastDay ? (month == 2 ? 29 : 31) : random.int(in: 1...PlainCalendar.daysIn(2000, month))
      payment.day = min(day, PlainCalendar.daysIn(2000, month))
      payment.month = month
      payment.nextDate = DateOnly(
        year: year, month: month, day: min(day, PlainCalendar.daysIn(year, month)))
    }
    return payment
  }

  // MARK: - Stepping

  /// Four years of due dates, leap day included, are exactly the days the rule names: every
  /// `interval` months on the day or the last day of a shorter month, every `interval` weeks
  /// on the weekday, every year in the month on the day.
  @Test(arguments: seeds)
  func theDueDatesAreTheDaysTheRuleNames(_ seed: UInt64) {
    let payment = Self.payment(seed: seed)
    guard let next = payment.nextDate else { return }
    let through = next.adding(days: 4 * 366)
    let stepped = Recurrence.occurrences(
      from: next, through: through, rule: RecurrenceRule(payment: payment), limit: 10_000)
    let walked = PlainCalendar.days(from: next, through: through).filter {
      PlainCalendar.isDue($0, of: payment)
    }
    #expect(stepped == walked, "seed \(seed): \(payment.name), day \(payment.day ?? 0)")
  }

  /// Stepping back is the mirror of stepping forward: from any due date, one step forward and
  /// one back come home, and so do one back and one forward.
  @Test(arguments: seeds)
  func steppingBackMirrorsSteppingForward(_ seed: UInt64) {
    let payment = Self.payment(seed: seed)
    let rule = RecurrenceRule(payment: payment)
    guard let next = payment.nextDate else { return }
    var due = next
    for _ in 0..<30 {
      #expect(
        ScheduledMatching.previous(before: Recurrence.next(after: due, rule: rule), rule: rule)
          == due, "seed \(seed), \(due)")
      #expect(
        Recurrence.next(after: ScheduledMatching.previous(before: due, rule: rule), rule: rule)
          == due, "seed \(seed), \(due)")
      due = Recurrence.next(after: due, rule: rule)
    }
  }

  /// The due dates before `next_date` the forecast looks back over are the days the rule
  /// names, oldest first — read off the rule counted back from `next_date` by the plain
  /// calendar, not stepped to.
  @Test(arguments: seeds)
  func theDueDatesBackAreTheDaysTheRuleNames(_ seed: UInt64) {
    let payment = Self.payment(seed: seed)
    guard let next = payment.nextDate else { return }
    let first = next.adding(days: -400)
    let back = ScheduledMatching.dues(
      before: next, from: first, rule: RecurrenceRule(payment: payment))
    let walked = PlainCalendar.days(from: first, through: next.adding(days: -1)).filter {
      PlainCalendar.isOnTheRule($0, of: payment)
    }
    #expect(back == walked, "seed \(seed): \(payment.name)")
    #expect(!back.isEmpty, "seed \(seed): four hundred days hold a due date of any rule")
  }

  /// The first due date on or after a day — the `next_date` of a new payment — is on the rule,
  /// not before the day, and no day in between is on the rule.
  @Test(arguments: seeds)
  func theFirstDueOnOrAfterADay(_ seed: UInt64) {
    var random = SeededRandom(seed: seed &+ 99)
    let template = Self.payment(seed: seed)
    let rule = RecurrenceRule(freq: template.freq, day: template.day, month: template.month)
    for _ in 0..<20 {
      let day = Fx.day("2026-01-01").adding(days: random.int(in: 0...1_200))
      let first = Recurrence.firstOnOrAfter(day, rule: rule)
      var payment = template
      payment.interval = 1
      payment.nextDate = first
      #expect(first >= day, "seed \(seed)")
      #expect(PlainCalendar.isDue(first, of: payment), "seed \(seed): \(first)")
      // Nothing between the day and the first due date fits the rule, whatever year or
      // week it counts from.
      for between in PlainCalendar.days(from: day, through: first.adding(days: -1)) {
        let fits: Bool
        switch rule.freq {
        case .weekly: fits = between.weekday == rule.day
        case .monthly:
          fits =
            between.day == min(rule.day ?? 0, PlainCalendar.daysIn(between.year, between.month))
        case .yearly:
          fits =
            between.month == rule.month
            && between.day
              == min(rule.day ?? 0, PlainCalendar.daysIn(between.year, between.month))
        }
        #expect(!fits, "seed \(seed): \(between) fits before \(first)")
      }
    }
  }

  // MARK: - The last day of the month

  /// «В последний день месяца» monthly: five years of due dates, every one the last day of its
  /// month — 28 February, 29 February 2028, 30 April, 31 May.
  @Test func theLastDayOfEveryMonthForFiveYears() {
    let rule = RecurrenceRule(freq: .monthly, day: 31)
    let dues = Recurrence.occurrences(
      from: Fx.day("2026-01-31"), through: Fx.day("2030-12-31"), rule: rule)
    #expect(dues.count == 60)
    for due in dues {
      #expect(due.day == PlainCalendar.daysIn(due.year, due.month), "\(due)")
    }
    #expect(dues.contains(Fx.day("2028-02-29")))
    #expect(dues.contains(Fx.day("2027-02-28")))
  }

  /// Every two months from 31 January: March, May, July on the 31st, September and November
  /// on the 30th, then January on the 31st again — the day is never lost to a short month.
  @Test func everyTwoMonthsOnTheLastDay() {
    let rule = RecurrenceRule(freq: .monthly, interval: 2, day: 31)
    #expect(
      Recurrence.occurrences(
        from: Fx.day("2026-01-31"), through: Fx.day("2027-01-31"), rule: rule)
        == [
          "2026-01-31", "2026-03-31", "2026-05-31", "2026-07-31", "2026-09-30", "2026-11-30",
          "2027-01-31",
        ].map(Fx.day))
    // A quarter from 30 November: the last day of February, then May the 30th — the rule says
    // 30, not «the last day».
    let quarter = RecurrenceRule(freq: .monthly, interval: 3, day: 30)
    #expect(
      Recurrence.occurrences(
        from: Fx.day("2027-11-30"), through: Fx.day("2028-08-31"), rule: quarter)
        == ["2027-11-30", "2028-02-29", "2028-05-30", "2028-08-30"].map(Fx.day))
  }

  /// A yearly payment on the last day of February: the 28th in common years, the 29th in leap
  /// years, for a whole leap cycle and across a century that is no leap year.
  @Test func theLastDayOfFebruaryEveryYear() {
    let rule = RecurrenceRule(freq: .yearly, day: 29, month: 2)
    let dues = Recurrence.occurrences(
      from: Fx.day("2027-02-28"), through: Fx.day("2031-12-31"), rule: rule)
    #expect(
      dues == ["2027-02-28", "2028-02-29", "2029-02-28", "2030-02-28", "2031-02-28"].map(Fx.day))
    #expect(
      Recurrence.next(after: Fx.day("2099-02-28"), rule: rule) == Fx.day("2100-02-28"))
    #expect(
      Recurrence.next(after: Fx.day("2399-02-28"), rule: rule) == Fx.day("2400-02-29"))
  }

  /// A payment on the 31st whose next due was clipped to 30 September is paid: it moves to
  /// 31 October, not to the 30th — the day lives in the rule, the clipped date does not
  /// rewrite it. Paying it back and forth never loses the day.
  @Test func payingAClippedDueKeepsTheDay() throws {
    let payment = ScheduledPayment(
      name: "Rent", amountE4: AmountE4(whole: 30_000), day: 31,
      nextDate: Fx.day("2026-09-30"))
    let paid = try ScheduledRules.markAsPaid(
      payment, due: Fx.day("2026-09-30"), amount: AmountE4(whole: 30_000),
      occurredAt: Fx.at("2026-09-30", 10))
    #expect(paid.payment.nextDate == Fx.day("2026-10-31"))
    #expect(paid.payment.day == 31)
    let skipped = ScheduledRules.skip(paid.payment, due: Fx.day("2026-10-31"))
    #expect(skipped.nextDate == Fx.day("2026-11-30"))
    #expect(
      ScheduledRules.skip(skipped, due: Fx.day("2026-11-30")).nextDate == Fx.day("2026-12-31"))
    // The operation of 30 September deleted: the payment is owed on the 30th again, and moves
    // on to the 31st from there.
    let reopened = ScheduledRules.reopened(paid.payment, due: Fx.day("2026-09-30"))
    #expect(reopened?.nextDate == Fx.day("2026-09-30"))
    #expect(reopened?.day == 31)
  }

  // MARK: - «Разово»

  /// A one-off planned expense is a scheduled payment that ends on its own date: exactly one
  /// due date however far one looks; «Провести» or «Пропустить» closes it.
  @Test func aOneOffHasOneDueAndIsClosedByPayingIt() throws {
    let sofa = ScheduledPayment(
      name: "Sofa", amountE4: AmountE4(whole: 25_000), day: 28,
      nextDate: Fx.day("2026-09-28"), endDate: Fx.day("2026-09-28"))
    #expect(
      Recurrence.occurrences(
        from: Fx.day("2026-09-28"), through: Fx.day("2030-01-01"),
        rule: RecurrenceRule(payment: sofa), end: sofa.endDate) == [Fx.day("2026-09-28")])
    let paid = try ScheduledRules.markAsPaid(
      sofa, due: Fx.day("2026-09-28"), amount: AmountE4(whole: 24_500),
      occurredAt: Fx.at("2026-09-27", 10))
    #expect(paid.payment.nextDate == nil)
    #expect(ScheduledRules.skip(sofa, due: Fx.day("2026-09-28")).nextDate == nil)
    // Paid, it is no status, no due of the plan, no reminder.
    var fx = Fx()
    fx.scheduled = [paid.payment]
    let snapshot = fx.snapshot()
    #expect(snapshot.scheduled.isEmpty)
    #expect(snapshot.planned.items.isEmpty)
    #expect(!snapshot.reminders.contains { $0.kind == .payment })
    #expect(fx.plan(until: "2027-09-19").scheduled == .zero)
  }

  /// Unpaid, a one-off is due once everywhere: the plan of the month, the free sum up to a
  /// year ahead, the 7-day card and the reminders name its one date, and its funding is its
  /// price once.
  @Test func anUnpaidOneOffIsDueOnceEverywhere() {
    var fx = Fx()
    fx.count([(Fx.main, .rub, "100000")], at: Fx.at("2026-09-10", 9))
    fx.scheduled = [
      Fx.payment(1, "Sofa", "25000", day: 21, next: "2026-09-21", end: "2026-09-21")
    ]
    let snapshot = fx.snapshot()
    #expect(snapshot.planned.items.map(\.due) == [Fx.day("2026-09-21")])
    #expect(snapshot.upcoming.map(\.due) == [Fx.day("2026-09-21")])
    #expect(snapshot.reminders.filter { $0.kind == .payment }.map(\.due) == [Fx.day("2026-09-21")])
    #expect(fx.plan(until: "2026-09-30").scheduled == Fx.money("25000"))
    #expect(fx.plan(until: "2027-09-19").scheduled == Fx.money("25000"))
    #expect(snapshot.funding.map(\.due) == [Fx.money("25000")])
    #expect(snapshot.scheduled.first?.dueDates == [Fx.day("2026-09-21")])
  }

  // MARK: - Per month and per year

  /// What one charge of 1 200 comes to per month and per year for every preset: 52 weeks a
  /// year, 26 fortnights, 12 months, 6, 4 and 2 charges, one a year.
  @Test func perMonthAndPerYearOfEveryPreset() {
    let charge = AmountE4(whole: 1_200)
    let expected: [(String, String, String)] = [
      ("weekly", "5200", "62400"), ("every two weeks", "2600", "31200"),
      ("monthly", "1200", "14400"), ("every two months", "600", "7200"),
      ("quarterly", "400", "4800"), ("half-yearly", "200", "2400"), ("yearly", "100", "1200"),
    ]
    for (name, monthly, yearly) in expected {
      guard let preset = Self.presets.first(where: { $0.name == name }) else { continue }
      let rule = RecurrenceRule(freq: preset.freq, interval: preset.interval)
      #expect(
        SubscriptionMath.monthlyEquivalent(charge, rule: rule) == Fx.money(monthly), "\(name)")
      #expect(SubscriptionMath.yearlyEquivalent(charge, rule: rule) == Fx.money(yearly), "\(name)")
    }
  }

  /// The yearly figure of the monthly presets is the number of their due dates in a year
  /// times the charge, counted on the calendar.
  @Test func theYearlyFigureCountsTheDueDatesOfAYear() {
    for preset in Self.presets where preset.freq != .weekly {
      let rule = RecurrenceRule(freq: preset.freq, interval: preset.interval, day: 31, month: 1)
      let dues = Recurrence.occurrences(
        from: Fx.day("2027-01-31"), through: Fx.day("2027-12-31"), rule: rule)
      #expect(
        SubscriptionMath.yearlyEquivalent(AmountE4(whole: 1_000), rule: rule)
          == AmountE4(whole: Int64(1_000 * dues.count)), "\(preset.name)")
    }
  }
}
