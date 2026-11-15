import AppCore
import UserNotifications
import XCTest

@testable import OhMyMoney

/// The evening reminder of the phone against a center that only counts: no system question is
/// ever shown. The rules of the evenings are tested in the core (`EveningRemindersTests`).
@MainActor
final class PhoneEveningRemindersTests: XCTestCase {
  private let calendar = CalendarContext.moscow
  private let today = DateOnly(year: 2026, month: 11, day: 2)
  private var suite: UserDefaults!

  override func setUp() {
    super.setUp()
    suite = UserDefaults(suiteName: "evening-\(UUID().uuidString)")
  }

  final class FakeCenter: EveningCenter {
    var status: NotificationPlan.Permission
    var grants: Bool
    var pending: Set<String> = []
    private(set) var asked = 0
    private(set) var added: [UNNotificationRequest] = []
    private(set) var removed: [String] = []
    private(set) var category: UNNotificationCategory?

    init(status: NotificationPlan.Permission, grants: Bool = true) {
      self.status = status
      self.grants = grants
    }

    func permission() async -> NotificationPlan.Permission { status }
    func requestPermission() async -> Bool {
      asked += 1
      if grants { status = .allowed } else { status = .denied }
      return grants
    }
    func pendingIds() async -> [String] { Array(pending) }
    func removePending(_ ids: [String]) {
      removed += ids
      pending.subtract(ids)
    }
    func add(_ request: UNNotificationRequest) {
      added.append(request)
      pending.insert(request.identifier)
    }
    func setCategory(_ category: UNNotificationCategory) { self.category = category }
  }

  private func reminders(_ center: FakeCenter, typedYesterday: Bool = true) -> PhoneEveningReminders
  {
    let value = PhoneEveningReminders(center: center)
    value.defaults = suite
    value.inputs = .init(
      entryDays: typedYesterday ? [today.adding(days: -1)] : [], today: today, calendar: calendar)
    return value
  }

  private var morning: Date { calendar.moment(today, hour: 9, minute: 0) }

  func testAWeekOfEveningsIsScheduledAndTheNotificationCarriesItsDay() async {
    let center = FakeCenter(status: .allowed)
    let value = reminders(center)
    await value.apply(now: morning)
    XCTAssertEqual(center.added.count, EveningReminders.horizon)
    let first = center.added[0]
    XCTAssertEqual(first.identifier, "habits.nudge:\(today.iso)")
    XCTAssertEqual(first.content.categoryIdentifier, PhoneEveningReminders.category)
    XCTAssertEqual(first.content.userInfo[PhoneEveningReminders.dayKey] as? String, today.iso)
    XCTAssertEqual(center.category?.actions.first?.identifier, EveningReminders.noSpendAction)
    XCTAssertEqual(center.asked, 0)
  }

  func testTheSecondRecountSchedulesNothingNew() async {
    let center = FakeCenter(status: .allowed)
    let value = reminders(center)
    await value.apply(now: morning)
    let count = center.added.count
    await value.apply(now: morning)
    XCTAssertEqual(center.added.count, count)
  }

  func testPermissionIsAskedOnceAndDeclinedMeansNothingScheduled() async {
    let center = FakeCenter(status: .undetermined, grants: false)
    let value = reminders(center)
    value.permissionPrompt = {
      await NotificationPermissionGate(center: center).answer(allow: true)
    }
    await value.apply(now: morning)
    await value.apply(now: morning)
    XCTAssertEqual(center.asked, 1)
    XCTAssertTrue(center.added.isEmpty)
    XCTAssertFalse(value.schedule(nil), "«Стоит посмотреть» says the evening instead")
  }

  func testNotNowDisablesUntilEnabledAgain() async {
    let center = FakeCenter(status: .undetermined)
    let value = reminders(center)
    var explanations = 0
    value.permissionPrompt = {
      explanations += 1
      return false
    }
    await value.apply(now: morning)
    XCTAssertEqual(center.asked, 0)
    XCTAssertFalse(HabitNotesOnMac.eveningEnabled(suite))
    await value.apply(now: morning)
    XCTAssertEqual(explanations, 1)
    suite.set(true, forKey: HabitNotesOnMac.eveningEnabledKey)
    await value.apply(now: morning)
    XCTAssertEqual(explanations, 2)
    XCTAssertEqual(center.asked, 0)
  }

  func testWithPermissionTheReminderIsDelivered() async {
    let center = FakeCenter(status: .undetermined)
    let value = reminders(center)
    value.permissionPrompt = {
      await NotificationPermissionGate(center: center).answer(allow: true)
    }
    await value.apply(now: morning)
    XCTAssertEqual(center.asked, 1)
    XCTAssertFalse(center.added.isEmpty)
    XCTAssertTrue(value.schedule(nil))
  }

  func testSwitchedOffTakesTheHeldRemindersBack() async {
    let center = FakeCenter(status: .allowed)
    let value = reminders(center)
    await value.apply(now: morning)
    suite.set(false, forKey: HabitNotesOnMac.eveningEnabledKey)
    await value.apply(now: morning)
    XCTAssertTrue(center.pending.isEmpty)
    XCTAssertEqual(center.removed.count, EveningReminders.horizon)
    XCTAssertFalse(value.schedule(nil))
  }

  func testTheHourOfTheSettingIsTheHourOfTheNotification() async {
    let center = FakeCenter(status: .allowed)
    let value = reminders(center)
    suite.set(22, forKey: HabitNotesOnMac.eveningHourKey)
    await value.apply(now: morning)
    let trigger = center.added.first?.trigger as? UNTimeIntervalNotificationTrigger
    XCTAssertEqual(
      trigger?.timeInterval, calendar.moment(today, hour: 22, minute: 0).timeIntervalSince(morning))
  }

  func testNothingTypedEverMeansNoReminder() async {
    let center = FakeCenter(status: .allowed)
    let value = reminders(center, typedYesterday: false)
    await value.apply(now: morning)
    XCTAssertTrue(center.added.isEmpty)
    XCTAssertEqual(center.asked, 0)
  }

  func testTheWordsAreInBothLanguagesAndHoldNoAmount() {
    for choice in [AppLanguage.Choice.russian, .english] {
      let language = AppLanguage()
      language.choice = choice
      let plain = HabitNudge(day: today, at: morning, streakDays: nil)
      let streak = HabitNudge(day: today, at: morning, streakDays: 5)
      for nudge in [plain, streak] {
        let content = PhoneEveningReminders.content(of: nudge, language: language)
        XCTAssertFalse(content.title.isEmpty)
        XCTAssertNotEqual(content.title, "mac.notify.evening.title")
        XCTAssertNotEqual(content.body, "mac.notify.evening.body")
        XCTAssertFalse(content.body.contains("mac.notify"))
      }
      XCTAssertTrue(
        PhoneEveningReminders.content(of: streak, language: language).body.contains("5"))
      let category = PhoneEveningReminders.makeCategory(language)
      XCTAssertNotEqual(category.actions.first?.title, "habit.action.noSpend")
      XCTAssertEqual(category.actions.first?.options, [.foreground])
    }
  }

  func testWithoutTheBooksTheAnswerWaitsAndWritesNothing() {
    let value = reminders(FakeCenter(status: .allowed))
    XCTAssertEqual(
      value.answer(action: EveningReminders.noSpendAction, day: today), .wait(today))
    XCTAssertEqual(
      value.answer(action: UNNotificationDefaultActionIdentifier, day: today), .open)
  }
}
