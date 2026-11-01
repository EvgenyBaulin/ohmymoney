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
  nonisolated static func key(for kind: NotificationPlan.Kind) -> String {
    "notifications.\(kind.rawValue)"
  }

  static let paymentCategory = "payment"
  static let recordAction = "record"
  /// A notice is shown at 10:00 of its day when it waits for a day ahead.
  static let hourOfTheDay = 10

  /// The app's explanation is on screen, waiting for «Разрешить» or «Не сейчас».
  var explaining = false

  @ObservationIgnored private let posting: any NotificationPosting
  @ObservationIgnored var defaults: UserDefaults = .standard
  @ObservationIgnored private var dependencies: AppDependencies?
  @ObservationIgnored private var working = false

  init(posting: any NotificationPosting) {
    self.posting = posting
  }

  /// Once, when the app has finished launching: the button of a payment, and the answer to a
  /// click on any notification.
  func install() {
    let center = UNUserNotificationCenter.current()
    center.delegate = self
    let record = UNNotificationAction(
      identifier: Self.recordAction,
      title: AppLanguage()("mac.notify.record", table: MacCommands.table), options: [])
    center.setNotificationCategories([
      UNNotificationCategory(
        identifier: Self.paymentCategory, actions: [record], intentIdentifiers: [], options: [])
    ])
  }

  func kinds() -> Set<NotificationPlan.Kind> {
    Set(
      NotificationPlan.Kind.allCases.filter {
        defaults.object(forKey: Self.key(for: $0)) as? Bool ?? true
      })
  }

  private var posted: Set<String> {
    get { Set(defaults.stringArray(forKey: Self.postedKey) ?? []) }
    set { defaults.set(newValue.sorted(), forKey: Self.postedKey) }
  }

  /// What the data says now, posted: called whenever the figures change.
  func refresh(_ dependencies: AppDependencies) async {
    self.dependencies = dependencies
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
      summaries: summaries, posted: [], kinds: kinds(), hiddenPayments: hiddenPayments)
    let fresh = all.filter { !posted.contains($0.id) }

    // A pending notice the data no longer says — the payment paid early — goes.
    let active = Set(all.map(\.id))
    let stale = await posting.pendingIds().filter { Self.isOurs($0) && !active.contains($0) }
    if !stale.isEmpty { posting.removePending(stale) }

    switch NotificationPlan.step(
      notices: fresh, permission: await posting.permission(),
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
    let words = NotificationWords(environment: environment, snapshot: snapshot)
    for notice in fresh {
      guard let content = words.content(of: notice) else { continue }
      posting.post(
        UNNotificationRequest(
          identifier: notice.id, content: content,
          trigger: trigger(for: notice.day, today: today, calendar: environment.calendar)))
    }
    posted = NotificationPlan.posted(
      keeping: posted, adding: Set(fresh.map(\.id)), active: active)
    AppLog.info(
      "notify.posted", .ui, "notifications were posted", [LogPair("count", .count(fresh.count))])
  }

  /// «Разрешить» or «Не сейчас» of the app's explanation: asked once either way.
  func answerExplanation(allow: Bool) async {
    explaining = false
    defaults.set(true, forKey: Self.explainedKey)
    guard allow else { return }
    _ = await posting.requestPermission()
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

/// The words of a notification, in the interface language. No amount with «Скрыть суммы» on.
@MainActor
struct NotificationWords {
  let environment: AppEnvironment
  let snapshot: DataSnapshot

  private func t(_ key: String) -> String { environment.language(key, table: MacCommands.table) }

  private func f(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: t(key), locale: environment.language.locale, arguments: arguments)
  }

  private var hidesAmounts: Bool { environment.amounts.isHidingNow }

  func content(of notice: NotificationPlan.Notice) -> UNMutableNotificationContent? {
    let content = UNMutableNotificationContent()
    switch notice.subject {
    case .paymentTomorrow(let paymentId, let due):
      guard let payment = snapshot.dataset.planning.scheduled.first(where: { $0.id == paymentId })
      else { return nil }
      content.title = f("mac.notify.payment.title", payment.name)
      let amount = SubscriptionMath.price(
        of: payment, on: due, prices: snapshot.dataset.planning.prices)
      content.body =
        hidesAmounts
        ? f("mac.notify.payment.bodyHidden", environment.dates.longDay(due))
        : f(
          "mac.notify.payment.body", environment.money.exact(amount, currency: payment.currency),
          environment.dates.longDay(due))
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
        hidesAmounts
        ? t("mac.notify.limit.bodyHidden")
        : f(
          "mac.notify.limit.body", environment.money.rounded(line.spent),
          environment.money.rounded(line.available))
      content.userInfo = ["section": MainWindow.Section.planning.rawValue]
    case .summary(let id):
      content.title = SummaryAnnouncementText.headline(of: id, language: environment.language)
      content.body = t("mac.notify.summary.body")
      content.userInfo = ["section": MainWindow.Section.overview.rawValue]
    }
    return content
  }
}
