import AppCore
import AppKit
import Foundation
import Observation
@preconcurrency import UserNotifications

/// The system's notification center as the app uses it. A seam: the app talks to the real
/// center, a test counts what was asked.
@MainActor
protocol NotificationPosting: AnyObject {
  func permission() async -> NotificationPlan.Permission
  func requestPermission() async -> Bool
  func pendingIds() async -> [String]
  func removePending(_ ids: [String])
  func post(_ request: UNNotificationRequest)
}

@MainActor
final class SystemNotificationPosting: NotificationPosting {
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

  func post(_ request: UNNotificationRequest) {
    center.add(request)
  }
}

/// The notifications of the Mac: «Платёж завтра» with «Записать оплату» right in the
/// notification, a limit nearly or over spent, «Итоги» ready (`NotificationPlan` decides what
/// and when). Permission is asked the first time there is something to say, after the app has
/// explained in its own words what it will say (`explaining`).
///
/// What a notification says is seen on the screen, outside the app's lock: with «Скрыть суммы»
/// it says no amount, and nothing about an account the owner hid is ever said.
@MainActor
@Observable
final class MacNotifications: NSObject {
  static let shared = MacNotifications(posting: SystemNotificationPosting())

  /// The keys of `UserDefaults` of this Mac.
  nonisolated static let postedKey = "notifications.posted"
  nonisolated static let explainedKey = "notifications.explained"
  /// What a notification may say about amounts and hidden accounts (`NotificationPlan.Privacy`:
  /// `quiet` by default, `anonymous`, `always`).
  nonisolated static let privacyKey = "notifications.privacy"
  nonisolated static func key(for kind: NotificationPlan.Kind) -> String {
    "notifications.\(kind.rawValue)"
  }

  static let paymentCategory = "payment"
  static let recordAction = "record"
  /// A notice is shown at 10:00 of its day when it waits for a day ahead.
  static let hourOfTheDay = 10

  /// The app's explanation is on screen, waiting for «Разрешить» or «Не сейчас».
  var explaining = false

  @ObservationIgnored let posting: any NotificationPosting
  @ObservationIgnored var defaults: UserDefaults = .standard
  @ObservationIgnored private(set) var dependencies: AppDependencies?
  @ObservationIgnored private var working = false
  /// What the system said about permission at the last look; `nil` before the first.
  @ObservationIgnored private(set) var permissionNow: NotificationPlan.Permission?
  /// The reminder of the evening last handed in (`HabitNudgeDelivering`), asked again when the
  /// permission changes.
  @ObservationIgnored private var lastNudge: HabitNudge?

  init(posting: any NotificationPosting) {
    self.posting = posting
  }

  /// Once, when the app has finished launching: the button of a payment, and the answer to a
  /// click on any notification.
  func install() {
    let center = UNUserNotificationCenter.current()
    center.delegate = self
    // The reminder of the evening of the habits is a notification from now on.
    HabitNudgeRoute.deliverer = self
    // So is the reminder of the drafts of «Запишу потом».
    NotificationCenter.default.addObserver(
      forName: .draftsChanged, object: nil, queue: .main
    ) { _ in
      Task { @MainActor in await MacNotifications.shared.refreshDrafts() }
    }
    let record = UNNotificationAction(
      identifier: Self.recordAction,
      title: AppLanguage()("mac.notify.record", table: MacCommands.table), options: [])
    // The categories replace each other as a whole: every one the app has is set here.
    center.setNotificationCategories([
      UNNotificationCategory(
        identifier: Self.paymentCategory, actions: [record], intentIdentifiers: [], options: []),
      Self.autoEntryCategory(),
    ])
  }

  func kinds() -> Set<NotificationPlan.Kind> {
    Set(
      NotificationPlan.Kind.allCases.filter {
        defaults.object(forKey: Self.key(for: $0)) as? Bool ?? true
      })
  }

  func privacy() -> NotificationPlan.Privacy {
    defaults.string(forKey: Self.privacyKey).flatMap(NotificationPlan.Privacy.init(rawValue:))
      ?? .standard
  }

  private var posted: Set<String> {
    get { Set(defaults.stringArray(forKey: Self.postedKey) ?? []) }
    set { defaults.set(newValue.sorted(), forKey: Self.postedKey) }
  }

  /// What the data says now, posted: called whenever the figures change.
  func refresh(_ dependencies: AppDependencies) async {
    self.dependencies = dependencies
    await refreshDrafts()
    guard !working, let snapshot = dependencies.compute.wholeSnapshot else { return }
    working = true
    defer { working = false }
    let environment = dependencies.environment
    let today = snapshot.today
    let storage = SummaryStorage(defaults: defaults)
    let summaries = SummaryScheduler.ready(
      today: today, firstDay: snapshot.ledger.firstDay, switches: storage.switches,
      shown: storage.shown)
    let hidden = HiddenAccounts(accounts: snapshot.dataset.paymentMethods)
    let hiddenPayments = Set(
      snapshot.dataset.planning.scheduled.filter { hidden.isHidden($0.paymentMethodId) }.map(\.id))
    let all = NotificationPlan.notices(
      today: today, reminders: snapshot.planning.reminders, limits: snapshot.planning.limits,
      summaries: summaries, posted: [], kinds: kinds(), hiddenPayments: hiddenPayments,
      privacy: privacy())
    let fresh = all.filter { !posted.contains($0.id) }

    // A pending notice the data no longer says — the payment paid early — goes.
    let active = Set(all.map(\.id))
    let stale = await posting.pendingIds().filter { Self.isOurs($0) && !active.contains($0) }
    if !stale.isEmpty { posting.removePending(stale) }

    let permission = await posting.permission()
    notePermission(permission)
    switch NotificationPlan.step(
      notices: fresh, permission: permission,
      explained: defaults.bool(forKey: Self.explainedKey))
    {
    case .nothing:
      return
    case .explain:
      explaining = true
      return
    case .post:
      break
    }
    let words = NotificationWords(
      environment: environment, snapshot: snapshot, privacy: privacy())
    for notice in fresh {
      guard let content = words.content(of: notice) else { continue }
      posting.post(
        UNNotificationRequest(
          identifier: notice.id, content: content,
          trigger: trigger(for: notice.day, today: today, calendar: environment.calendar)))
    }
    // The reminders of the evening are not this plan's: they are kept as they are.
    posted =
      NotificationPlan.posted(keeping: posted, adding: Set(fresh.map(\.id)), active: active)
      .union(posted.filter { $0.hasPrefix(Self.eveningPrefix) })
    AppLog.info(
      "notify.posted", .ui, "notifications were posted", [LogPair("count", .count(fresh.count))])
  }

  /// «Разрешить» or «Не сейчас» of the app's explanation: asked once either way.
  func answerExplanation(allow: Bool) async {
    explaining = false
    defaults.set(true, forKey: Self.explainedKey)
    guard allow else { return }
    _ = await posting.requestPermission()
    notePermission(await posting.permission())
    if let dependencies { await refresh(dependencies) }
  }

  private func trigger(
    for day: DateOnly, today: DateOnly, calendar: CalendarContext
  ) -> UNNotificationTrigger? {
    guard day > today else { return nil }
    let moment = calendar.startOfDay(day).addingTimeInterval(
      TimeInterval(Self.hourOfTheDay * 3_600))
    var components = Calendar(identifier: .gregorian).dateComponents(
      in: calendar.timeZone, from: moment)
    components.nanosecond = nil
    return UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
  }

  nonisolated static func isOurs(_ id: String) -> Bool {
    id.hasPrefix("pay:") || id.hasPrefix("limit:") || id.hasPrefix("summary:")
  }

  // MARK: Answers

  /// «Записать оплату»: the due date of the payment written as «Провести» in the reminders
  /// writes it — one step of ⌘Z. When that would ask something (a count made that day), or the
  /// app is locked or read-only, the app comes forward on Planning instead and writes nothing.
  func recordPayment(paymentId: UUID, due: DateOnly) -> Bool {
    guard let dependencies, let snapshot = dependencies.compute.wholeSnapshot,
      !dependencies.environment.lock.isLocked, !dependencies.environment.shield.isReadOnly,
      let payment = snapshot.dataset.planning.scheduled.first(where: { $0.id == paymentId })
    else { return false }
    let actions = PlanningActions(dependencies)
    let amount = SubscriptionMath.price(
      of: payment, on: due, prices: snapshot.dataset.planning.prices)
    let moment = dependencies.environment.now()
    guard actions.countToAsk(paying: payment, due: due, amount: amount, on: moment) == nil else {
      return false
    }
    let written = actions.markAsPaid(
      payment, due: due, amount: amount, on: moment, account: payment.paymentMethodId,
      charged: nil, updatePrice: false)
    AppLog.info(
      "notify.paymentRecorded", .db, "a payment was recorded from its notification",
      [LogPair("written", .flag(written))])
    return written
  }

  /// A click on a notification, or a payment that could not be written from it: the main window
  /// on the section the notice is about.
  func open(_ section: MainWindow.Section) {
    NSApp.activate()
    NotificationCenter.default.post(name: .openSidebarItem, object: SidebarItem.section(section))
    _ = AppWindows.bringForward(.main)
  }
}

// MARK: - The reminder of the evening

extension MacNotifications: HabitNudgeDelivering {
  /// The id of every reminder of the evening starts so (`HabitNudge.id`).
  nonisolated static let eveningPrefix = "habits.nudge:"

  /// Permission as the system says it now. A change hands the reminder of the evening to the
  /// route again, so «Стоит посмотреть» stops saying it once the notification can.
  func notePermission(_ permission: NotificationPlan.Permission) {
    let changed = permissionNow != nil && permissionNow != permission
    permissionNow = permission
    if changed { HabitNudgeRoute.route(lastNudge) }
  }

  /// «Запишите траты за день» at the hour of the evening (`nudge.at`), keyed by its day: the same
  /// day handed in again is not shown twice; `nil` takes back what was scheduled. `false` — no
  /// permission yet or any more, or the evening switched off in «За пределами приложения»: the
  /// line of «Стоит посмотреть» says it then. With permission never asked, the app's explanation
  /// comes up — there is something to say now.
  func schedule(_ nudge: HabitNudge?) -> Bool {
    lastNudge = nudge
    let scheduled = posted.filter { $0.hasPrefix(Self.eveningPrefix) }
    guard let nudge, kinds().contains(.evening) else {
      takeBack(scheduled)
      return false
    }
    // Another day's reminder, not shown yet, goes.
    takeBack(scheduled.subtracting([nudge.id]))
    switch permissionNow {
    case .allowed:
      break
    case .undetermined:
      if !defaults.bool(forKey: Self.explainedKey) { explaining = true }
      return false
    case .denied, nil:
      return false
    }
    guard !posted.contains(nudge.id) else { return true }
    let content = EveningWords(language: dependencies?.environment.language ?? AppLanguage())
      .content(of: nudge)
    let now = dependencies?.environment.now() ?? Date()
    let trigger: UNNotificationTrigger? =
      nudge.at > now
      ? UNTimeIntervalNotificationTrigger(
        timeInterval: nudge.at.timeIntervalSince(now), repeats: false)
      : nil
    posting.post(UNNotificationRequest(identifier: nudge.id, content: content, trigger: trigger))
    posted = posted.union([nudge.id])
    AppLog.info("notify.evening", .ui, "the reminder of the evening was scheduled")
    return true
  }

  private func takeBack(_ ids: Set<String>) {
    guard !ids.isEmpty else { return }
    posting.removePending(Array(ids))
    posted = posted.subtracting(ids)
  }
}

/// The words of the reminder of the evening: no amount in it, so nothing to hide.
@MainActor
struct EveningWords {
  let language: AppLanguage

  func content(of nudge: HabitNudge) -> UNMutableNotificationContent {
    let content = UNMutableNotificationContent()
    content.title = language("mac.notify.evening.title", table: MacCommands.table)
    if let streak = nudge.streakDays, streak > 0 {
      content.body = language.counted(
        "mac.notify.evening.streak", table: MacCommands.table, [streak])
    } else {
      content.body = language("mac.notify.evening.body", table: MacCommands.table)
    }
    content.userInfo = ["section": MainWindow.Section.overview.rawValue]
    return content
  }
}

extension MacNotifications: UNUserNotificationCenterDelegate {
  /// Shown even while the app is in front: a payment due tomorrow is news there too.
  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions {
    [.banner, .list]
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
  ) async {
    let action = response.actionIdentifier
    let info = response.notification.request.content.userInfo
    let payment = (info["payment"] as? String).flatMap(UUID.init(uuidString:))
    let due = (info["due"] as? String).flatMap(DateOnly.init(iso:))
    let section = (info["section"] as? String).flatMap(MainWindow.Section.init(rawValue:))
    let draft = (info[Self.autoEntryDraftKey] as? String).flatMap(UUID.init(uuidString:))
    if let draft {
      await MacNotifications.shared.answerAutoEntry(action: action, draft: draft)
      return
    }
    if info[Self.openDraftsKey] != nil {
      await MainActor.run {
        MacNotifications.shared.open(.overview)
        NotificationCenter.default.post(name: .openDrafts, object: nil)
      }
      return
    }
    await MainActor.run {
      if action == Self.recordAction, let payment, let due {
        if !MacNotifications.shared.recordPayment(paymentId: payment, due: due) {
          MacNotifications.shared.open(.planning)
        }
        return
      }
      MacNotifications.shared.open(section ?? .overview)
    }
  }
}

/// The words of a notification, in the interface language, as the owner's choice says
/// (`NotificationPlan.Privacy`): by default no amount with «Скрыть суммы» on.
@MainActor
struct NotificationWords {
  let environment: AppEnvironment
  let snapshot: DataSnapshot
  var privacy: NotificationPlan.Privacy = .standard

  private func t(_ key: String) -> String { environment.language(key, table: MacCommands.table) }

  private func f(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: t(key), locale: environment.language.locale, arguments: arguments)
  }

  private var saysAmount: Bool {
    privacy.saysAmount(hidesAmounts: environment.amounts.isHidingNow)
  }

  /// Amounts written in full: a notice says one only when it may (`saysAmount`), and then the
  /// mask of the screen is not what it means.
  private var money: MoneyFormatter {
    MoneyFormatter(
      locale: environment.language.locale, hidesAmounts: false,
      currencyStyle: environment.theme.currencyStyle, catalog: environment.currencyCatalog)
  }

  func content(of notice: NotificationPlan.Notice) -> UNMutableNotificationContent? {
    let content = UNMutableNotificationContent()
    switch notice.subject {
    case .paymentTomorrow(let paymentId, let due):
      guard let payment = snapshot.dataset.planning.scheduled.first(where: { $0.id == paymentId })
      else { return nil }
      let amount = SubscriptionMath.price(
        of: payment, on: due, prices: snapshot.dataset.planning.prices)
      if notice.anonymous {
        // A payment of a hidden account: neither its name nor its amount.
        content.title = t("mac.notify.payment.anonymous")
        content.body = f("mac.notify.payment.bodyHidden", environment.dates.longDay(due))
      } else {
        content.title = f("mac.notify.payment.title", payment.name)
        content.body =
          saysAmount
          ? f(
            "mac.notify.payment.body", money.exact(amount, currency: payment.currency),
            environment.dates.longDay(due))
          : f("mac.notify.payment.bodyHidden", environment.dates.longDay(due))
      }
      content.categoryIdentifier = MacNotifications.paymentCategory
      content.userInfo = [
        "payment": paymentId.uuidString, "due": due.iso,
        "section": MainWindow.Section.planning.rawValue,
      ]
    case .limitNear(let budgetId, _), .limitOver(let budgetId, _):
      guard let line = snapshot.planning.limits.first(where: { $0.budget.id == budgetId }) else {
        return nil
      }
      let name = PlanningText.limitName(
        line.budget, tree: CategoryTree(snapshot.dataset.categories), environment)
      let over: Bool
      if case .limitOver = notice.subject { over = true } else { over = false }
      content.title = f(over ? "mac.notify.limit.over" : "mac.notify.limit.near", name)
      content.body =
        saysAmount
        ? f("mac.notify.limit.body", money.rounded(line.spent), money.rounded(line.available))
        : t("mac.notify.limit.bodyHidden")
      content.userInfo = ["section": MainWindow.Section.planning.rawValue]
    case .summary(let id):
      content.title = SummaryAnnouncementText.headline(of: id, language: environment.language)
      content.body = t("mac.notify.summary.body")
      content.userInfo = ["section": MainWindow.Section.overview.rawValue]
    }
    return content
  }
}
