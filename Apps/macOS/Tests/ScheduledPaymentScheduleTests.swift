import AppCore
import XCTest

@testable import OhMyMoney

/// The schedule of a scheduled payment and of an expected income as their forms write it: the
/// presets of «How often» both ways, «On the last day of the month», and the day a payment
/// keeps when it is saved again.
@MainActor
final class ScheduledPaymentScheduleTests: XCTestCase {
  private let today = DateOnly(year: 2026, month: 9, day: 25)

  private func day(_ year: Int, _ month: Int, _ day: Int) -> DateOnly {
    DateOnly(year: year, month: month, day: day)
  }

  // MARK: Presets

  /// Every preset writes its frequency and interval, and a row saved with them opens as the
  /// same preset.
  func testEveryPresetReadsBackAsItself() {
    let expected: [FrequencyPreset: FrequencyPreset.Cadence] = [
      .weekly: .init(.weekly, 1), .everyTwoWeeks: .init(.weekly, 2),
      .monthly: .init(.monthly, 1), .everyTwoMonths: .init(.monthly, 2),
      .quarterly: .init(.monthly, 3), .halfYearly: .init(.monthly, 6),
      .yearly: .init(.yearly, 1),
    ]
    for (preset, cadence) in expected {
      XCTAssertEqual(preset.cadence, cadence, preset.rawValue)
      let payment = ScheduledPayment(
        name: "Rent", amountE4: AmountE4(whole: 1), freq: cadence.freq,
        interval: cadence.interval, nextDate: today)
      XCTAssertEqual(FrequencyPreset.of(payment), preset, preset.rawValue)
    }
    XCTAssertNil(FrequencyPreset.once.cadence)
    XCTAssertNil(FrequencyPreset.other.cadence)
  }

  /// A row with any interval of 1…24 still opens: as its preset when there is one, otherwise
  /// as «Other…» with its own frequency and interval, which the form shows unchanged.
  func testAnyStoredIntervalOpensAsAPresetOrAsOther() {
    for freq in Frequency.allCases {
      for interval in FrequencyPreset.intervals {
        let payment = ScheduledPayment(
          name: "Rent", amountE4: AmountE4(whole: 1), freq: freq, interval: interval,
          nextDate: today)
        let preset = FrequencyPreset.of(payment)
        if let cadence = preset.cadence {
          XCTAssertEqual(cadence, .init(freq, interval))
        } else {
          XCTAssertEqual(preset, .other, "\(freq) × \(interval)")
        }
      }
    }
    XCTAssertEqual(
      FrequencyPreset.of(.init(.monthly, 12)), .other, "every 12 months is not «every year»")
    XCTAssertEqual(FrequencyPreset.of(.init(.weekly, 3)), .other)
    XCTAssertEqual(FrequencyPreset.of(.init(.yearly, 2)), .other)
  }

  /// «Once» is a payment that ends on its next date: saved that way, and read back as it.
  func testOnceEndsOnItsDateBothWays() {
    let planned = ScheduledPayment(
      name: "Sofa", amountE4: AmountE4(whole: 40_000), nextDate: day(2026, 10, 12))
    let saved = planned.readyToSave(
      original: nil, preset: .once, lastDay: false, hasEnd: false, hasTrial: false, today: today)
    XCTAssertEqual(saved.endDate, day(2026, 10, 12))
    XCTAssertEqual(saved.nextDate, day(2026, 10, 12))
    XCTAssertEqual(FrequencyPreset.of(saved), .once)

    // Leaving «Once» for a rhythm without an end drops the end date again.
    let monthly = saved.readyToSave(
      original: saved, preset: .monthly, lastDay: false, hasEnd: false, hasTrial: false,
      today: today)
    XCTAssertNil(monthly.endDate)
    XCTAssertEqual(FrequencyPreset.of(monthly), .monthly)
  }

  /// «Once» with no date yet is the date the form shows: today, not a monthly rhythm that the
  /// save would start from its first due and never end.
  func testOnceWithoutADateIsToday() {
    let planned = ScheduledPayment(name: "Sofa", amountE4: AmountE4(whole: 40_000))
    let saved = planned.readyToSave(
      original: nil, preset: .once, lastDay: false, hasEnd: false, hasTrial: false, today: today)
    XCTAssertEqual(saved.nextDate, today)
    XCTAssertEqual(saved.endDate, today)
  }

  /// A preset chosen writes its frequency and interval whatever the row had.
  func testAPresetWritesItsCadence() {
    let payment = ScheduledPayment(
      name: "Insurance", amountE4: AmountE4(whole: 1), freq: .weekly, interval: 5,
      nextDate: day(2026, 10, 1))
    let saved = payment.readyToSave(
      original: payment, preset: .quarterly, lastDay: false, hasEnd: false, hasTrial: false,
      today: today)
    XCTAssertEqual(saved.freq, .monthly)
    XCTAssertEqual(saved.interval, 3)
    XCTAssertEqual(saved.day, 1)
    XCTAssertNil(saved.month)
  }

  // MARK: The form

  /// A payment moved to a weekly rhythm can be saved: the day checked is the one the save
  /// writes — a weekday — not the day of the month the payment had, which a week does not
  /// have past the 7th.
  func testAPaymentMovedToAWeeklyRhythmCanBeSaved() {
    let gym = ScheduledPayment(
      name: "Gym", amountE4: AmountE4(whole: 3_000), freq: .monthly, day: 15,
      nextDate: day(2026, 10, 15))
    for preset in [FrequencyPreset.weekly, .everyTwoWeeks] {
      var draft = ScheduledPaymentDraft(opening: gym)
      draft.choose(preset, today: today)
      XCTAssertNil(draft.issue(original: gym, tree: CategoryTree(), today: today), preset.rawValue)
      XCTAssertEqual(draft.saved(original: gym, today: today).day, day(2026, 10, 15).weekday)
    }

    var inWeeks = ScheduledPaymentDraft(opening: gym)
    inWeeks.choose(.other, today: today)
    inWeeks.setUnit(.weekly, today: today)
    inWeeks.payment.interval = 3
    XCTAssertNil(inWeeks.issue(original: gym, tree: CategoryTree(), today: today))

    let domain = ScheduledPayment(
      name: "Domain", amountE4: AmountE4(whole: 1_000), freq: .yearly, day: 20, month: 11,
      nextDate: day(2026, 11, 20))
    var weekly = ScheduledPaymentDraft(opening: domain)
    weekly.choose(.weekly, today: today)
    XCTAssertNil(weekly.issue(original: domain, tree: CategoryTree(), today: today))

    // What is really wrong still says so.
    var unnamed = ScheduledPaymentDraft(opening: gym)
    unnamed.payment.name = " "
    XCTAssertEqual(unnamed.issue(original: gym, tree: CategoryTree(), today: today), .emptyName)
  }

  /// A yearly subscription whose last due has come — its end is its next date — opens as
  /// what it is, with its end, and a save keeps the end; the same for every 2 months.
  func testARhythmOnItsLastDueIsNotOnce() {
    let due = day(2026, 10, 12)
    for (freq, interval, preset) in [
      (Frequency.yearly, 1, FrequencyPreset.yearly), (.monthly, 2, .everyTwoMonths),
      (.weekly, 1, .weekly),
    ] {
      let row = ScheduledPayment(
        name: "Domain", kind: .subscription, amountE4: AmountE4(whole: 1_000), freq: freq,
        interval: interval, day: Recurrence.anchor(of: due, freq: freq).day,
        month: Recurrence.anchor(of: due, freq: freq).month, nextDate: due, endDate: due)
      XCTAssertEqual(FrequencyPreset.of(row), preset, preset.rawValue)
      let draft = ScheduledPaymentDraft(opening: row)
      XCTAssertEqual(draft.preset, preset)
      XCTAssertTrue(draft.offersEnd)
      XCTAssertTrue(draft.hasEnd, preset.rawValue)
      let saved = draft.saved(original: row, today: today)
      XCTAssertEqual(saved.endDate, due, preset.rawValue)
      XCTAssertEqual(saved.freq, freq)
      XCTAssertEqual(saved.interval, interval)
    }
  }

  /// «Once» is saved as a single month whatever rhythm was chosen before, so it reads back as
  /// «Once» and nothing else does.
  func testOnceIsSavedAsASingleMonth() {
    let insurance = ScheduledPayment(
      name: "Insurance", amountE4: AmountE4(whole: 1), freq: .yearly, day: 12, month: 10,
      nextDate: day(2026, 10, 12))
    var draft = ScheduledPaymentDraft(opening: insurance)
    draft.choose(.once, today: today)
    let saved = draft.saved(original: insurance, today: today)
    XCTAssertEqual(saved.freq, .monthly)
    XCTAssertEqual(saved.interval, 1)
    XCTAssertEqual(saved.endDate, day(2026, 10, 12))
    XCTAssertEqual(FrequencyPreset.of(saved), .once)

    var inWeeks = ScheduledPaymentDraft(opening: insurance)
    inWeeks.choose(.other, today: today)
    inWeeks.setUnit(.weekly, today: today)
    inWeeks.payment.interval = 5
    inWeeks.choose(.once, today: today)
    XCTAssertEqual(FrequencyPreset.of(inWeeks.saved(original: insurance, today: today)), .once)
  }

  /// Leaving «Once» for a rhythm keeps the end the row was saved with in view: a monthly row on
  /// its last due reads as «Once», and choosing its rhythm again does not make it endless
  /// unseen. A payment made «Once» in the form and then given a rhythm has no end.
  func testLeavingOnceKeepsTheStoredEnd() {
    let lastMonth = ScheduledPayment(
      name: "Streaming", kind: .subscription, amountE4: AmountE4(whole: 500), freq: .monthly,
      day: 12, nextDate: day(2026, 10, 12), endDate: day(2026, 10, 12))
    var draft = ScheduledPaymentDraft(opening: lastMonth)
    XCTAssertEqual(draft.preset, .once)
    XCTAssertFalse(draft.offersEnd)
    draft.choose(.monthly, today: today)
    XCTAssertTrue(draft.hasEnd)
    XCTAssertEqual(draft.saved(original: lastMonth, today: today).endDate, day(2026, 10, 12))

    // Its date moved while it was «Once»: the end it keeps is that date.
    var moved = ScheduledPaymentDraft(opening: lastMonth)
    moved.setNextDate(day(2026, 10, 20), today: today)
    moved.choose(.monthly, today: today)
    XCTAssertEqual(moved.saved(original: lastMonth, today: today).endDate, day(2026, 10, 20))

    // A rhythm with an end of its own keeps it through a visit to «Once».
    let ending = ScheduledPayment(
      name: "Gym", amountE4: AmountE4(whole: 3_000), freq: .monthly, day: 5,
      nextDate: day(2026, 10, 5), endDate: day(2026, 12, 5))
    var visit = ScheduledPaymentDraft(opening: ending)
    visit.choose(.once, today: today)
    visit.choose(.monthly, today: today)
    XCTAssertTrue(visit.hasEnd)
    XCTAssertEqual(visit.saved(original: ending, today: today).endDate, day(2026, 12, 5))

    var fresh = ScheduledPaymentDraft(
      opening: ScheduledPayment(
        name: "Sofa", amountE4: AmountE4(whole: 1), nextDate: day(2026, 10, 12)))
    fresh.choose(.once, today: today)
    fresh.choose(.monthly, today: today)
    XCTAssertFalse(fresh.hasEnd)
    XCTAssertNil(fresh.saved(original: nil, today: today).endDate)
  }

  /// «Once» dated the 31st does not open with the last-day switch on: a date the owner then
  /// picks stays where it was put when a rhythm is chosen.
  func testOnceOnThe31stLeavesTheDateAlone() {
    let planned = ScheduledPayment(
      name: "Sofa", amountE4: AmountE4(whole: 40_000), day: 31, nextDate: day(2026, 10, 31),
      endDate: day(2026, 10, 31))
    var draft = ScheduledPaymentDraft(opening: planned)
    XCTAssertEqual(draft.preset, .once)
    XCTAssertFalse(draft.lastDay)
    draft.setNextDate(day(2026, 11, 15), today: today)
    draft.choose(.monthly, today: today)
    XCTAssertEqual(draft.payment.nextDate, day(2026, 11, 15))
    XCTAssertFalse(draft.lastDay)
    XCTAssertEqual(draft.saved(original: planned, today: today).day, 15)
  }

  /// A hidden switch moves no date: «Once» and a weekly rhythm turn it off, so coming back to
  /// a month leaves the date the owner picked meanwhile.
  func testAHiddenLastDaySwitchIsOff() {
    let rent = ScheduledPayment(
      name: "Rent", amountE4: AmountE4(whole: 30_000), freq: .monthly, day: 31,
      nextDate: day(2026, 9, 30))
    for away in [FrequencyPreset.once, .weekly] {
      var draft = ScheduledPaymentDraft(opening: rent)
      XCTAssertTrue(draft.lastDay)
      draft.choose(away, today: today)
      XCTAssertFalse(draft.lastDay, away.rawValue)
      draft.setNextDate(day(2026, 11, 15), today: today)
      draft.choose(.monthly, today: today)
      XCTAssertEqual(draft.payment.nextDate, day(2026, 11, 15), away.rawValue)
    }

    // Another month-based rhythm keeps the switch and the date.
    var quarterly = ScheduledPaymentDraft(opening: rent)
    quarterly.choose(.quarterly, today: today)
    XCTAssertTrue(quarterly.lastDay)
    XCTAssertEqual(quarterly.payment.nextDate, day(2026, 9, 30))
    XCTAssertEqual(quarterly.saved(original: rent, today: today).day, 31)
  }

  // MARK: The day a payment keeps

  /// A payment of the 31st whose next due was clipped to the 30th, opened and saved again with
  /// nothing of its schedule changed, stays a payment of the 31st — it used to become one of
  /// the 30th for good.
  func testSavingAgainKeepsTheDayOfAClippedPayment() {
    let rent = ScheduledPayment(
      name: "Rent", amountE4: AmountE4(whole: 30_000), freq: .monthly, day: 31,
      nextDate: day(2026, 9, 30))
    var edited = rent
    edited.amountE4 = AmountE4(whole: 32_000)
    let saved = edited.readyToSave(
      original: rent, preset: .monthly, lastDay: rent.isOnLastDay, hasEnd: false,
      hasTrial: false, today: today)
    XCTAssertEqual(saved.day, 31)
    XCTAssertEqual(saved.nextDate, day(2026, 9, 30))
  }

  /// The same for a day that is not the last one: the 30th clipped to 28 February stays the
  /// 30th.
  func testSavingAgainKeepsTheThirtiethInFebruary() {
    let payment = ScheduledPayment(
      name: "Gym", amountE4: AmountE4(whole: 3_000), freq: .monthly, day: 30,
      nextDate: day(2027, 2, 28))
    let saved = payment.readyToSave(
      original: payment, preset: .monthly, lastDay: payment.isOnLastDay, hasEnd: false,
      hasTrial: false, today: today)
    XCTAssertEqual(saved.day, 30)
  }

  /// A yearly payment keeps its month and day the same way.
  func testSavingAgainKeepsAYearlyDay() {
    let payment = ScheduledPayment(
      name: "Domain", amountE4: AmountE4(whole: 1_000), freq: .yearly, day: 29, month: 2,
      nextDate: day(2027, 2, 28))
    let saved = payment.readyToSave(
      original: payment, preset: .yearly, lastDay: payment.isOnLastDay, hasEnd: false,
      hasTrial: false, today: today)
    XCTAssertEqual(saved.day, 29)
    XCTAssertEqual(saved.month, 2)
  }

  /// A date chosen by the owner is the new day of the rule.
  func testANewDateIsTheNewDay() {
    let rent = ScheduledPayment(
      name: "Rent", amountE4: AmountE4(whole: 30_000), freq: .monthly, day: 31,
      nextDate: day(2026, 9, 30))
    var edited = rent
    edited.nextDate = day(2026, 10, 5)
    let saved = edited.readyToSave(
      original: rent, preset: .monthly, lastDay: false, hasEnd: false, hasTrial: false,
      today: today)
    XCTAssertEqual(saved.day, 5)
  }

  /// A new frequency derives the day again: a weekly payment keeps a weekday.
  func testANewFrequencyDerivesTheDay() {
    let rent = ScheduledPayment(
      name: "Rent", amountE4: AmountE4(whole: 30_000), freq: .monthly, day: 31,
      nextDate: day(2026, 9, 30))
    let saved = rent.readyToSave(
      original: rent, preset: .weekly, lastDay: true, hasEnd: false, hasTrial: false,
      today: today)
    XCTAssertEqual(saved.freq, .weekly)
    XCTAssertEqual(saved.day, day(2026, 9, 30).weekday, "a weekly rule has no last day")
    XCTAssertNil(saved.month)
  }

  /// Only the interval changed: the day of the rule stays.
  func testANewIntervalKeepsTheDay() {
    let rent = ScheduledPayment(
      name: "Rent", amountE4: AmountE4(whole: 30_000), freq: .monthly, day: 31,
      nextDate: day(2026, 9, 30))
    let saved = rent.readyToSave(
      original: rent, preset: .quarterly, lastDay: true, hasEnd: false, hasTrial: false,
      today: today)
    XCTAssertEqual(saved.interval, 3)
    XCTAssertEqual(saved.day, 31)
  }

  // MARK: The last day of the month

  /// The switch keeps day 31 for a monthly rule; turned off, the day is the date's own.
  func testTheLastDaySwitchKeepsDay31() {
    let gym = ScheduledPayment(
      name: "Gym", amountE4: AmountE4(whole: 3_000), freq: .monthly, day: 15,
      nextDate: day(2026, 9, 15))
    var edited = gym
    edited.nextDate = MonthEnd.lastDay(of: gym.nextDate!)
    let saved = edited.readyToSave(
      original: gym, preset: .monthly, lastDay: true, hasEnd: false, hasTrial: false,
      today: today)
    XCTAssertEqual(saved.nextDate, day(2026, 9, 30))
    XCTAssertEqual(saved.day, 31)
    XCTAssertTrue(saved.isOnLastDay)
    XCTAssertEqual(
      Recurrence.next(after: saved.nextDate!, rule: RecurrenceRule(payment: saved)),
      day(2026, 10, 31), "the next due is the last day of October")

    // Turned off with the date left as it was: the day is the 30th from now on.
    let off = saved.readyToSave(
      original: saved, preset: .monthly, lastDay: false, hasEnd: false, hasTrial: false,
      today: today)
    XCTAssertEqual(off.day, 30)
    XCTAssertFalse(off.isOnLastDay)
  }

  /// A yearly rule keeps the longest its month gets: 29 in February, 30 in April, 31 in
  /// January — each passes the check of a yearly day.
  func testTheLastDayOfAYearlyRuleIsTheLongestOfItsMonth() {
    for (date, expected) in [
      (day(2027, 2, 28), 29), (day(2027, 4, 30), 30), (day(2027, 1, 31), 31),
    ] {
      let payment = ScheduledPayment(
        name: "Insurance", amountE4: AmountE4(whole: 1), freq: .yearly, nextDate: date)
      let saved = payment.readyToSave(
        original: nil, preset: .yearly, lastDay: true, hasEnd: false, hasTrial: false,
        today: today)
      XCTAssertEqual(saved.day, expected)
      XCTAssertEqual(saved.month, date.month)
      XCTAssertTrue(saved.isOnLastDay)
      XCTAssertNil(ScheduledRules.validate(saved, tree: CategoryTree()))
    }
    XCTAssertEqual(
      Recurrence.next(
        after: day(2027, 2, 28),
        rule: RecurrenceRule(freq: .yearly, day: 29, month: 2)),
      day(2028, 2, 29), "a leap year reaches the 29th")
  }

  /// A day of 31 read from an older row is the last day; any other day is not.
  func testWhatReadsAsTheLastDay() {
    XCTAssertTrue(MonthEnd.isLastDay(day: 31, freq: .monthly, month: nil))
    XCTAssertFalse(MonthEnd.isLastDay(day: 30, freq: .monthly, month: nil))
    XCTAssertFalse(MonthEnd.isLastDay(day: nil, freq: .monthly, month: nil))
    XCTAssertFalse(MonthEnd.isLastDay(day: 7, freq: .weekly, month: nil))
    XCTAssertTrue(MonthEnd.isLastDay(day: 29, freq: .yearly, month: 2))
    XCTAssertFalse(MonthEnd.isLastDay(day: 28, freq: .yearly, month: 2))
    XCTAssertTrue(MonthEnd.isLastDay(day: 31, freq: .yearly, month: nil))
  }

  /// «Once» and a weekly rule have no last day of a month, whatever the switch said.
  func testOnceAndWeeklyIgnoreTheLastDaySwitch() {
    let planned = ScheduledPayment(
      name: "Sofa", amountE4: AmountE4(whole: 1), nextDate: day(2026, 10, 12))
    let once = planned.readyToSave(
      original: nil, preset: .once, lastDay: true, hasEnd: false, hasTrial: false, today: today)
    XCTAssertEqual(once.day, 12)
    let weekly = planned.readyToSave(
      original: nil, preset: .weekly, lastDay: true, hasEnd: false, hasTrial: false,
      today: today)
    XCTAssertEqual(weekly.day, day(2026, 10, 12).weekday)
  }

  // MARK: Expected income

  /// A recurring income on the last day keeps day 31 even when its first due is the 30th, and
  /// its due dates fall on the last day of every month.
  func testARecurringIncomeOnTheLastDay() {
    var income = ExpectedIncome(
      name: "Salary", kind: .recurring, totalE4: AmountE4(whole: 100_000),
      dueDate: day(2026, 9, 30), freq: .monthly)
    let saved = income.readyToSave(today: today, lastDay: true)
    XCTAssertEqual(saved.day, 31)
    XCTAssertEqual(
      Recurrence.next(after: day(2026, 9, 30), rule: RecurrenceRule(expected: saved)),
      day(2026, 10, 31))

    XCTAssertEqual(income.readyToSave(today: today, lastDay: false).day, 30)

    income.freq = .yearly
    income.dueDate = day(2027, 2, 28)
    XCTAssertEqual(income.readyToSave(today: today, lastDay: true).day, 29)

    income.freq = .weekly
    XCTAssertEqual(
      income.readyToSave(today: today, lastDay: true).day, day(2027, 2, 28).weekday,
      "a weekly income has no last day")

    var once = income
    once.kind = .oneOff
    XCTAssertNil(once.readyToSave(today: today, lastDay: true).day)
  }

  /// The switch of the income form moves the first due date to the end of its month, and a
  /// switch the form hides — a one-off income, a weekly one — is off: coming back leaves the
  /// date picked meanwhile where it was put.
  func testAHiddenIncomeSwitchIsOff() {
    var salary = ExpectedIncome(
      name: "Salary", kind: .recurring, totalE4: AmountE4(whole: 1),
      dueDate: day(2026, 9, 15), freq: .monthly)
    var lastDay = true
    salary.followTheLastDay(&lastDay, today: today)
    XCTAssertEqual(salary.dueDate, day(2026, 9, 30))

    for away in [
      { (income: inout ExpectedIncome) in income.kind = .oneOff },
      { (income: inout ExpectedIncome) in income.freq = .weekly },
    ] {
      var income = salary
      var on = true
      away(&income)
      income.followTheLastDay(&on, today: today)
      XCTAssertFalse(on)
      income.dueDate = day(2026, 11, 15)
      income.kind = .recurring
      income.freq = .monthly
      income.followTheLastDay(&on, today: today)
      XCTAssertEqual(income.dueDate, day(2026, 11, 15))
    }
  }

  /// The switch of the income form reads the stored day the same way.
  func testAnIncomeReadsAsOnTheLastDay() {
    let income = ExpectedIncome(
      name: "Salary", kind: .recurring, totalE4: AmountE4(whole: 1),
      dueDate: day(2026, 9, 30), freq: .monthly, day: 31)
    XCTAssertTrue(income.isOnLastDay)
    var weekly = income
    weekly.freq = .weekly
    XCTAssertFalse(weekly.isOnLastDay)
    var once = income
    once.kind = .oneOff
    XCTAssertFalse(once.isOnLastDay)
  }

  // MARK: Words

  /// «Other…» declines its unit with the number in Russian and in English, and says one unit
  /// the way its preset does: «Каждую неделю», never «каждую 1 неделю».
  func testOtherIsDeclinedWithTheNumber() {
    let language = AppLanguage()
    func every(_ freq: Frequency, _ count: Int) -> String {
      FrequencyPreset.everyText(freq, interval: count, language: language)
    }
    language.choice = .russian
    XCTAssertEqual(every(.weekly, 1), "Каждую неделю")
    XCTAssertEqual(every(.weekly, 3), "Каждые 3 недели")
    XCTAssertEqual(every(.weekly, 5), "Каждые 5 недель")
    XCTAssertEqual(every(.weekly, 21), "Каждые 21 неделю")
    XCTAssertEqual(every(.monthly, 1), "Каждый месяц")
    XCTAssertEqual(every(.monthly, 4), "Каждые 4 месяца")
    XCTAssertEqual(every(.monthly, 11), "Каждые 11 месяцев")
    XCTAssertEqual(every(.monthly, 21), "Каждые 21 месяц")
    XCTAssertEqual(every(.yearly, 1), "Каждый год")
    XCTAssertEqual(every(.yearly, 2), "Каждые 2 года")
    XCTAssertEqual(every(.yearly, 5), "Каждые 5 лет")
    XCTAssertEqual(every(.yearly, 21), "Каждые 21 год")
    XCTAssertEqual(every(.yearly, 22), "Каждые 22 года")
    language.choice = .english
    XCTAssertEqual(every(.weekly, 1), "Every week")
    XCTAssertEqual(every(.weekly, 2), "Every 2 weeks")
    XCTAssertEqual(every(.monthly, 5), "Every 5 months")
    XCTAssertEqual(every(.yearly, 1), "Every year")
    XCTAssertEqual(every(.yearly, 2), "Every 2 years")
  }

  /// Every preset, unit and caption of the schedule is in the catalogue in both languages.
  func testThePresetsAreTranslatedInBothLanguages() {
    let language = AppLanguage()
    let keys =
      FrequencyPreset.allCases.map(\.key)
      + Frequency.allCases.map { "form.unit.\($0.rawValue)" } + ["form.lastDay"]
    for choice in [AppLanguage.Choice.english, .russian] {
      language.choice = choice
      for key in keys {
        XCTAssertNotEqual(language(key, table: "Planning"), key, "\(key) in \(choice.rawValue)")
      }
    }
    language.choice = .russian
    XCTAssertEqual(language(FrequencyPreset.quarterly.key, table: "Planning"), "Раз в квартал")
    XCTAssertEqual(language(FrequencyPreset.once.key, table: "Planning"), "Разово")
    XCTAssertEqual(language("form.lastDay", table: "Planning"), "В последний день месяца")
  }

  /// The debt's day of payment says «the last day» at 31, and the number otherwise.
  func testTheDebtDayOfPaymentSaysTheLastDayAt31() {
    let language = AppLanguage()
    language.choice = .russian
    func text(_ day: Int) -> String { DebtSheetView.paymentDayText(day, language: language) }
    XCTAssertEqual(text(31), "День платежа: последний день")
    XCTAssertEqual(text(5), "День платежа: 5")
    language.choice = .english
    XCTAssertEqual(text(31), "Payment day: last day")
  }

  /// The card of a debt says the same: «в последний день месяца» at 31, the number otherwise.
  func testTheDebtCardSaysTheLastDayAt31() {
    let language = AppLanguage()
    language.choice = .russian
    func text(_ day: Int?) -> String {
      DebtSheetView.cardPaymentText("5 000 ₽", day: day, language: language)
    }
    XCTAssertEqual(text(31), "платёж 5 000 ₽, в последний день месяца")
    XCTAssertEqual(text(10), "платёж 5 000 ₽, 10-го числа")
    language.choice = .english
    XCTAssertEqual(text(31), "payment 5 000 ₽ on the last day of the month")
    XCTAssertEqual(text(10), "payment 5 000 ₽ on day 10")
  }
}
