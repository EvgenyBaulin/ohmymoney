import CoreKit
import Foundation
import Testing

@testable import CorePlanning

/// The evenings an iPhone holds a reminder for: the app is not open every evening, so the
/// coming days are scheduled ahead and taken back when the day gets its entry.
@Suite("Habits: reminders of the evenings ahead")
struct EveningRemindersTests {
  typealias F = HabitFixture
  private let calendar = F.calendar
  private let today = F.monday
  private var morning: Date { calendar.moment(today, hour: 9, minute: 0) }

  private func upcoming(
    entryDays: Set<DateOnly>, hour: Int = 20, enabled: Bool = true, now: Date? = nil
  ) -> [HabitNudge] {
    EveningReminders.upcoming(
      entryDays: entryDays, today: today, hour: hour, enabled: enabled, calendar: calendar,
      now: now ?? morning)
  }

  @Test("today and the six evenings after it, each at the hour of the evening")
  func aWeekAhead() {
    let nudges = upcoming(entryDays: [today.adding(days: -1)])
    #expect(nudges.map(\.day) == (0..<EveningReminders.horizon).map { today.adding(days: $0) })
    #expect(nudges.allSatisfy { $0.at == calendar.moment($0.day, hour: 20, minute: 0) })
  }

  @Test("an entry today leaves today out and keeps the evenings ahead")
  func entryToday() {
    let nudges = upcoming(entryDays: [today, today.adding(days: -1)])
    #expect(nudges.first?.day == today.adding(days: 1))
    #expect(nudges.count == EveningReminders.horizon - 1)
  }

  @Test("switched off: nothing is held")
  func off() {
    #expect(upcoming(entryDays: [today.adding(days: -1)], enabled: false).isEmpty)
  }

  @Test("nothing was ever typed: no reminder, the first month has its own checklist")
  func neverTyped() {
    #expect(upcoming(entryDays: []).isEmpty)
  }

  @Test("an evening that has passed is not scheduled again")
  func passedEvening() {
    let late = calendar.moment(today, hour: 21, minute: 30)
    let nudges = upcoming(entryDays: [today.adding(days: -1)], now: late)
    #expect(nudges.first?.day == today.adding(days: 1))
  }

  @Test("only today's reminder speaks of the streak: tomorrow's would promise what is not known")
  func streakOnlyToday() {
    let nudges = upcoming(entryDays: F.days(today.adding(days: -3), 3))
    #expect(nudges.first?.streakDays == 3)
    #expect(nudges.dropFirst().allSatisfy { $0.streakDays == nil })
  }

  @Test("the hour is kept between 0 and 23")
  func hourClamped() {
    let nudges = upcoming(entryDays: [today.adding(days: -1)], hour: 31)
    #expect(nudges.first?.at == calendar.moment(today, hour: 23, minute: 0))
  }

  @Test("what the system holds is made to match: stale taken back, missing added, ours only")
  func difference() {
    let wanted = upcoming(entryDays: [today.adding(days: -1)])
    let stale = "habits.nudge:2026-10-01"
    let foreign = "pay:abc"
    let held: Set<String> = [stale, foreign, wanted[0].id]
    let change = EveningReminders.change(wanted: wanted, held: held)
    #expect(change.remove == [stale])
    #expect(change.add.map(\.id) == wanted.dropFirst().map(\.id))
  }

  @Test("the day of an id is read back for the answer of the notification")
  func dayOfId() {
    let nudge = upcoming(entryDays: [today.adding(days: -1)])[2]
    #expect(EveningReminders.day(ofId: nudge.id) == nudge.day)
    #expect(EveningReminders.day(ofId: "pay:abc") == nil)
  }

  @Test("the action marks the day of the reminder once the books are open")
  func answerMarks() {
    let answer = EveningReminders.answer(
      action: EveningReminders.noSpendAction, day: today, today: today, ready: true,
      canWrite: true)
    #expect(answer == .mark(today))
  }

  @Test("an answer that started the app waits for the books")
  func answerWaits() {
    let answer = EveningReminders.answer(
      action: EveningReminders.noSpendAction, day: today, today: nil, ready: false,
      canWrite: true)
    #expect(answer == .wait(today))
  }

  @Test("locked, read-only, a tap on the body, a day to come: nothing is written")
  func answerWritesNothing() {
    let mark = EveningReminders.noSpendAction
    #expect(
      EveningReminders.answer(action: mark, day: today, today: today, ready: true, canWrite: false)
        == .open)
    #expect(
      EveningReminders.answer(
        action: "com.apple.UNNotificationDefaultActionIdentifier", day: today, today: today,
        ready: true, canWrite: true) == .open)
    #expect(
      EveningReminders.answer(
        action: mark, day: today.adding(days: 1), today: today, ready: true, canWrite: true)
        == .open)
    #expect(
      EveningReminders.answer(action: mark, day: nil, today: today, ready: true, canWrite: true)
        == .open)
  }
}
