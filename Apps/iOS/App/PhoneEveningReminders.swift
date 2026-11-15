import AppCore
import Foundation
import UIKit
@preconcurrency import UserNotifications

/// The system's notification center as the evening reminder uses it. A seam: the app talks to
/// the real center, a test counts what was asked and never shows a system question.
@MainActor
protocol EveningCenter: AnyObject {
  func permission() async -> NotificationPlan.Permission
  func requestPermission() async -> Bool
  func pendingIds() async -> [String]
  func removePending(_ ids: [String])
  func add(_ request: UNNotificationRequest)
  func setCategory(_ category: UNNotificationCategory)
}

@MainActor
final class SystemEveningCenter: EveningCenter {
  private var center: UNUserNotificationCenter { .current() }

  func permission() async -> NotificationPlan.Permission {
    switch await center.notificationSettings().authorizationStatus {
    case .authorized, .provisional, .ephemeral: .allowed
    case .denied: .denied
    case .notDetermined: .undetermined
    @unknown default: .denied
    }
  }

  func requestPermission() async -> Bool {
    (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
  }

  func pendingIds() async -> [String] {
    await center.pendingNotificationRequests().map(\.identifier)
  }

  func removePending(_ ids: [String]) {
    center.removePendingNotificationRequests(withIdentifiers: ids)
  }

  func add(_ request: UNNotificationRequest) { center.add(request) }

  func setCategory(_ category: UNNotificationCategory) {
    center.setNotificationCategories([category])
  }
}

/// «Запишите траты за день» on the phone: a local notification at the evening hour of the
/// habits for today and the six evenings after it (the app is not open every evening), with the
/// action «Трат не было» that marks the day without opening the books. No network; the hour and
/// the switch are the ones of «Привычки». Permission is asked once, the first time there is
/// something to say.
@MainActor
final class PhoneEveningReminders: NSObject, HabitNudgeDelivering {
  static let shared = PhoneEveningReminders(center: SystemEveningCenter())

  static let category = "habits.evening"
  /// The key of `UserDefaults`: permission was asked once.
  static let askedKey = "habits.evening.asked"
  nonisolated static let dayKey = "day"
  /// The table the words of the Mac's reminder live in; the same words serve the phone.
  static let wordsTable = "MacFeatures"

  struct Inputs {
    var entryDays: Set<DateOnly>
    var today: DateOnly
    var calendar: CalendarContext
  }

  let center: any EveningCenter
  var defaults: UserDefaults = .standard
  private(set) var permission: NotificationPlan.Permission?
  /// What the last recount said; set by `refresh`.
  var inputs: Inputs?
  private var language = AppLanguage()
  private(set) var dependencies: AppDependencies?
  private var waitingDay: DateOnly?

  init(center: any EveningCenter) { self.center = center }

  /// Once, when the app starts: the answer to the notification and the reminder as the route's
  /// deliverer. Nothing in the host of the unit tests.
  static func install() {
    guard !AppEnvironment.isTestHost else { return }
    UNUserNotificationCenter.current().delegate = shared
    HabitNudgeRoute.deliverer = shared
    NotificationCenter.default.addObserver(
      forName: UserDefaults.didChangeNotification, object: nil, queue: .main
    ) { _ in
      Task { @MainActor in await PhoneEveningReminders.shared.settingsMayHaveChanged() }
    }
  }

  // MARK: Delivering

  /// Whether the reminder reaches the owner as a notification: «Стоит посмотреть» then does not
  /// say it again. The scheduling itself is `refresh`.
  func schedule(_ nudge: HabitNudge?) -> Bool {
    permission == .allowed && HabitNotesOnMac.eveningEnabled(defaults)
  }

  // MARK: Scheduling

  /// After every recount: what the books say, made the reminders of the evenings ahead.
  func refresh(_ snapshot: DataSnapshot, dependencies: AppDependencies) async {
    guard !AppEnvironment.isTestHost else { return }
    self.dependencies = dependencies
    language = dependencies.environment.language
    inputs = Inputs(
      entryDays: HabitNotesOnMac.entryDays(snapshot), today: snapshot.today,
      calendar: snapshot.ledger.calendar)
    if let day = waitingDay {
      waitingDay = nil
      answer(action: EveningReminders.noSpendAction, day: day)
    }
    await apply(now: dependencies.environment.now())
  }

  private var applied: (enabled: Bool, hour: Int)?

  /// The evening switched on or off, or its hour moved, in the settings.
  func settingsMayHaveChanged() async {
    let now = (HabitNotesOnMac.eveningEnabled(defaults), HabitNotesOnMac.eveningHour(defaults))
    guard inputs != nil else { return }
    if let applied, applied == now { return }
    await apply(now: dependencies?.environment.now() ?? Date())
  }

  /// Makes the system hold exactly the reminders wanted now; permission is asked once.
  func apply(now: Date) async {
    guard let inputs else { return }
    let enabled = HabitNotesOnMac.eveningEnabled(defaults)
    let hour = HabitNotesOnMac.eveningHour(defaults)
    applied = (enabled, hour)
    let wanted = EveningReminders.upcoming(
      entryDays: inputs.entryDays, today: inputs.today, hour: hour, enabled: enabled,
      calendar: inputs.calendar, now: now)
    var status = await center.permission()
    if status == .undetermined, !wanted.isEmpty, !defaults.bool(forKey: Self.askedKey) {
      defaults.set(true, forKey: Self.askedKey)
      _ = await center.requestPermission()
      status = await center.permission()
    }
    permission = status
    let change = EveningReminders.change(
      wanted: status == .allowed ? wanted : [], held: Set(await center.pendingIds()))
    if !change.remove.isEmpty { center.removePending(Array(change.remove)) }
    guard !change.add.isEmpty else { return }
    center.setCategory(Self.makeCategory(language))
    for nudge in change.add {
      let interval = max(1, nudge.at.timeIntervalSince(now))
      center.add(
        UNNotificationRequest(
          identifier: nudge.id, content: Self.content(of: nudge, language: language),
          trigger: UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)))
    }
    AppLog.info(
      "notify.evening", .ui, "the reminders of the evenings were scheduled",
      [LogPair("count", .count(change.add.count))])
  }

  // MARK: Words

  /// The category with its one action, «Трат не было»; `.foreground` so the app starts and
  /// opens the books before the day is written.
  static func makeCategory(_ language: AppLanguage) -> UNNotificationCategory {
    let action = UNNotificationAction(
      identifier: EveningReminders.noSpendAction,
      title: language("habit.action.noSpend", table: "Habits"), options: [.foreground])
    return UNNotificationCategory(
      identifier: category, actions: [action], intentIdentifiers: [], options: [])
  }

  /// No amount in it, so nothing to hide; the day goes in `userInfo` for the answer.
  static func content(of nudge: HabitNudge, language: AppLanguage) -> UNMutableNotificationContent {
    let content = UNMutableNotificationContent()
    content.title = language("mac.notify.evening.title", table: wordsTable)
    if let streak = nudge.streakDays, streak > 0 {
      content.body = language.counted("mac.notify.evening.streak", table: wordsTable, [streak])
    } else {
      content.body = language("mac.notify.evening.body", table: wordsTable)
    }
    content.categoryIdentifier = category
    content.userInfo = [dayKey: nudge.day.iso]
    return content
  }

  // MARK: Answer

  /// A tap on the action (or the body) of a reminder.
  @discardableResult
  func answer(action: String, day: DateOnly?) -> EveningReminders.Answer {
    let environment = dependencies?.environment
    let result = EveningReminders.answer(
      action: action, day: day, today: inputs?.today, ready: environment?.state == .ready,
      canWrite: environment.map { !$0.lock.isLocked && !$0.shield.isReadOnly } ?? false)
    switch result {
    case .mark(let day):
      if let dependencies { HabitActions(dependencies).markNoSpend(day) }
    case .wait(let day):
      waitingDay = day
    case .open:
      break
    }
    return result
  }
}

extension PhoneEveningReminders: UNUserNotificationCenterDelegate {
  /// Shown even while the app is in front: the evening is news there too.
  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions {
    [.banner, .list]
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
  ) async {
    let action = response.actionIdentifier
    let day = (response.notification.request.content.userInfo[Self.dayKey] as? String)
      .flatMap(DateOnly.init(iso:))
    await MainActor.run { _ = PhoneEveningReminders.shared.answer(action: action, day: day) }
  }
}
