import AppCore
import UserNotifications
import XCTest

@testable import OhMyMoney

/// The evening reminder of the phone at the edges: another zone, an hour out of range, a denied
/// permission, an evening already over, a setting that changes nothing, and the words in every
/// language. Same counting center as `PhoneEveningRemindersTests`.
@MainActor
final class PhoneEveningRemindersEdgeTests: XCTestCase {
  private let today = DateOnly(year: 2026, month: 11, day: 2)
  private var suite: UserDefaults!

  override func setUp() {
    super.setUp()
    suite = UserDefaults(suiteName: "evening-edge-\(UUID().uuidString)")
  }

  private func reminders(
    _ center: PhoneEveningRemindersTests.FakeCenter, zone: String = "Europe/Moscow",
    entryDays: Set<DateOnly>? = nil
  ) throws -> (PhoneEveningReminders, CalendarContext) {
    let calendar = CalendarContext(timeZone: try XCTUnwrap(TimeZone(identifier: zone)))
    let value = PhoneEveningReminders(center: center)
    value.defaults = suite
    value.inputs = .init(
      entryDays: entryDays ?? [today.adding(days: -1)], today: today, calendar: calendar)
    return (value, calendar)
  }

  func testTheHourIsTheOwnersOnTheClockOfEveryZone() async throws {
    for zone in ["Asia/Baku", "America/Los_Angeles", "Pacific/Auckland", "Asia/Kolkata", "UTC"] {
      let center = PhoneEveningRemindersTests.FakeCenter(status: .allowed)
      let (value, calendar) = try reminders(center, zone: zone)
      let now = calendar.moment(today, hour: 8, minute: 15)
      await value.apply(now: now)
      let trigger = center.added.first?.trigger as? UNTimeIntervalNotificationTrigger
      let evening = calendar.moment(today, hour: HabitNotes.defaultEveningHour, minute: 0)
      XCTAssertEqual(
        trigger?.timeInterval ?? -1, evening.timeIntervalSince(now), accuracy: 0.5, zone)
      XCTAssertEqual(center.added.count, EveningReminders.horizon, zone)
    }
  }

  func testAnHourOutOfRangeIsHeldToTheDay() async throws {
    for (stored, expected) in [(-5, 0), (24, 23), (99, 23), (0, 0), (23, 23)] {
      suite.set(stored, forKey: HabitNotesOnMac.eveningHourKey)
      let center = PhoneEveningRemindersTests.FakeCenter(status: .allowed)
      let (value, calendar) = try reminders(center)
      let now = calendar.moment(today.adding(days: -1), hour: 12, minute: 0)
      await value.apply(now: now)
      let trigger = center.added.first?.trigger as? UNTimeIntervalNotificationTrigger
      let wanted = calendar.moment(today, hour: expected, minute: 0).timeIntervalSince(now)
      XCTAssertEqual(trigger?.timeInterval ?? -1, wanted, accuracy: 0.5, "stored \(stored)")
    }
  }

  func testAfterTheEveningHasPassedTodayIsLeftOutAndTheDaysAheadStay() async throws {
    let center = PhoneEveningRemindersTests.FakeCenter(status: .allowed)
    let (value, calendar) = try reminders(center)
    await value.apply(now: calendar.moment(today, hour: 23, minute: 30))
    XCTAssertEqual(center.added.count, EveningReminders.horizon - 1)
    XCTAssertFalse(center.added.contains { $0.identifier == "habits.nudge:\(today.iso)" })
    for request in center.added {
      let trigger = request.trigger as? UNTimeIntervalNotificationTrigger
      XCTAssertGreaterThanOrEqual(trigger?.timeInterval ?? 0, 1, "never a trigger in the past")
    }
  }

  func testADayWithAnEntryHasNoReminderButTheNextOnesDo() async throws {
    let center = PhoneEveningRemindersTests.FakeCenter(status: .allowed)
    let (value, calendar) = try reminders(
      center, entryDays: [today.adding(days: -1), today, today.adding(days: 2)])
    await value.apply(now: calendar.moment(today, hour: 9, minute: 0))
    let days = Set(center.added.compactMap { EveningReminders.day(ofId: $0.identifier) })
    XCTAssertFalse(days.contains(today))
    XCTAssertFalse(days.contains(today.adding(days: 2)))
    XCTAssertTrue(days.contains(today.adding(days: 1)))
  }

  func testWithNoBooksYetNothingIsDoneAndASettingChangeIsIgnored() async {
    let center = PhoneEveningRemindersTests.FakeCenter(status: .allowed)
    let value = PhoneEveningReminders(center: center)
    value.defaults = suite
    await value.apply(now: Date())
    await value.settingsMayHaveChanged()
    XCTAssertTrue(center.added.isEmpty)
    XCTAssertTrue(center.removed.isEmpty)
    XCTAssertEqual(center.asked, 0)
    XCTAssertNil(value.permission)
  }

  func testASettingThatChangedNothingSchedulesNothingMore() async throws {
    let center = PhoneEveningRemindersTests.FakeCenter(status: .allowed)
    let (value, calendar) = try reminders(center)
    await value.apply(now: calendar.moment(today, hour: 9, minute: 0))
    let added = center.added.count
    await value.settingsMayHaveChanged()
    XCTAssertEqual(center.added.count, added)
    XCTAssertTrue(center.removed.isEmpty)
  }

  func testAMovedHourLeavesEveryHeldEveningAtTheNewHour() async throws {
    let center = PhoneEveningRemindersTests.FakeCenter(status: .allowed)
    let (value, calendar) = try reminders(center)
    let now = calendar.moment(today.adding(days: -1), hour: 12, minute: 0)
    await value.apply(now: now)
    suite.set(7, forKey: HabitNotesOnMac.eveningHourKey)
    await value.apply(now: now)
    XCTAssertEqual(center.pending.count, EveningReminders.horizon)
    for offset in 0..<EveningReminders.horizon {
      let day = today.adding(days: offset)
      let id = "habits.nudge:\(day.iso)"
      // The system keeps the last request of an id: that one has to be at the new hour.
      let last =
        center.added.last { $0.identifier == id }?.trigger
        as? UNTimeIntervalNotificationTrigger
      let wanted = calendar.moment(day, hour: 7, minute: 0).timeIntervalSince(now)
      XCTAssertEqual(last?.timeInterval ?? -1, wanted, accuracy: 0.5, "\(day.iso)")
    }
  }

  /// Known gap: a reminder of a day keeps the id of its day, so a phone that crossed into another
  /// zone keeps the evenings it scheduled on the clock of the old one. The expectation turns
  /// into a failure the day this is fixed, and the marker is then taken out.
  func testAZoneChangedWhileEveningsAreHeldMovesThemToTheNewClock() async throws {
    let center = PhoneEveningRemindersTests.FakeCenter(status: .allowed)
    let (value, moscow) = try reminders(center)
    let now = moscow.moment(today.adding(days: -1), hour: 12, minute: 0)
    await value.apply(now: now)
    let baku = CalendarContext(timeZone: try XCTUnwrap(TimeZone(identifier: "Asia/Baku")))
    value.inputs = .init(
      entryDays: [today.adding(days: -1)], today: today, calendar: baku)
    await value.apply(now: now)
    let id = "habits.nudge:\(today.iso)"
    let last =
      center.added.last { $0.identifier == id }?.trigger as? UNTimeIntervalNotificationTrigger
    let wanted = baku.moment(today, hour: HabitNotes.defaultEveningHour, minute: 0)
      .timeIntervalSince(now)
    XCTExpectFailure("a held evening keeps the old zone's clock") {
      XCTAssertEqual(last?.timeInterval ?? -1, wanted, accuracy: 0.5)
    }
  }

  func testTheStreakWordsHoldAnyCountAndNoCountMeansThePlainWords() {
    let language = AppLanguage()
    language.choice = .english
    let moment = Date(timeIntervalSince1970: 1_800_000_000)
    let plain = PhoneEveningReminders.content(
      of: HabitNudge(day: today, at: moment, streakDays: nil), language: language)
    for streak in [0, -3] {
      let body = PhoneEveningReminders.content(
        of: HabitNudge(day: today, at: moment, streakDays: streak), language: language
      ).body
      XCTAssertEqual(body, plain.body, "a streak of \(streak) is no streak")
    }
    for streak in [1, 2, 5, 11, 21, 1_000, 1_000_000, Int.max] {
      let content = PhoneEveningReminders.content(
        of: HabitNudge(day: today, at: moment, streakDays: streak), language: language)
      XCTAssertFalse(content.body.contains("mac.notify"), "\(streak)")
      XCTAssertEqual(content.userInfo[PhoneEveningReminders.dayKey] as? String, today.iso)
    }
  }

  func testTheTitleAndTheActionAreNamedInEveryLanguage() {
    let moment = Date(timeIntervalSince1970: 1_800_000_000)
    for choice in AppLanguage.Choice.allCases where choice != .system {
      let language = AppLanguage()
      language.choice = choice
      let content = PhoneEveningReminders.content(
        of: HabitNudge(day: today, at: moment, streakDays: nil), language: language)
      XCTAssertFalse(content.title.isEmpty, choice.rawValue)
      XCTAssertNotEqual(content.title, "mac.notify.evening.title", choice.rawValue)
      let action = PhoneEveningReminders.makeCategory(language).actions.first?.title
      XCTAssertNotEqual(action, "habit.action.noSpend", choice.rawValue)
      XCTAssertFalse((action ?? "").isEmpty, choice.rawValue)
    }
  }

  func testAnAnswerForTheFutureOrWithoutADayOnlyOpensTheApp() throws {
    let center = PhoneEveningRemindersTests.FakeCenter(status: .allowed)
    let (value, _) = try reminders(center)
    XCTAssertEqual(value.answer(action: EveningReminders.noSpendAction, day: nil), .open)
    XCTAssertEqual(value.answer(action: "other", day: today), .open)
    XCTAssertEqual(value.answer(action: "", day: nil), .open)
  }
}
