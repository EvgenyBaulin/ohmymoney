import AppCore
import AppKit
import Foundation
@preconcurrency import UserNotifications

/// The notifications of auto entry: «Кафе 450 ₽ — записать?» with «Записать» and «Изменить»,
/// «Записано: Кафе 450 ₽», «Остаток не сходится». Shown at once, never scheduled; they are not
/// the plan's (`NotificationPlan`), so the plan's refresh neither keeps nor takes them back.
extension MacNotifications {
  nonisolated static let autoEntryCategoryId = "autoEntry"
  nonisolated static let autoEntryRecordAction = "autoEntry.record"
  nonisolated static let autoEntryEditAction = "autoEntry.edit"
  /// The id of the draft an offer waits in, in `userInfo` — never the line or the text.
  nonisolated static let autoEntryDraftKey = "autoEntryDraft"
  nonisolated static let autoEntryPrefix = "autoEntry:"

  static func autoEntryCategory() -> UNNotificationCategory {
    let language = AppLanguage()
    let record = UNNotificationAction(
      identifier: autoEntryRecordAction,
      title: language("autoEntry.action.record", table: "AutoEntry"), options: [])
    let edit = UNNotificationAction(
      identifier: autoEntryEditAction,
      title: language("autoEntry.action.edit", table: "AutoEntry"),
      options: [.foreground])
    return UNNotificationCategory(
      identifier: autoEntryCategoryId, actions: [record, edit], intentIdentifiers: [],
      options: [])
  }

  /// Shows what a text of a bank came to, when there is something to show and the system lets
  /// the app. Without permission the offer still waits in «Запишу потом».
  func post(_ result: AutoEntryCenter.Result) async {
    guard let title = result.title else { return }
    let permission = await posting.permission()
    notePermission(permission)
    switch permission {
    case .allowed:
      break
    case .undetermined:
      if !defaults.bool(forKey: Self.explainedKey) { explaining = true }
      return
    case .denied:
      return
    }
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = result.body ?? ""
    var info: [String: String] = ["section": MainWindow.Section.overview.rawValue]
    if let draft = result.draftId {
      content.categoryIdentifier = Self.autoEntryCategoryId
      info[Self.autoEntryDraftKey] = draft.uuidString
    }
    content.userInfo = info
    posting.post(
      UNNotificationRequest(
        identifier: Self.autoEntryPrefix + (result.draftId ?? UUID()).uuidString,
        content: content, trigger: nil))
    AppLog.info("notify.autoEntry", .ui, "a notification about a bank text was shown")
  }

  /// «Записать» writes the draft as the line would; «Изменить», a click, or a write the line
  /// would stop for, open the drafts in the main window.
  func answerAutoEntry(action: String, draft: UUID) async {
    if action == Self.autoEntryRecordAction, let commands = await MacCommandsHost.commands(),
      await AutoEntryCenter.shared.recordDraft(draft, commands: commands)
    {
      return
    }
    open(.overview)
    NotificationCenter.default.post(name: .openDrafts, object: nil)
  }

  // MARK: The drafts of the evening

  /// The id of the reminder of the drafts: one at a time, replaced whenever the drafts change.
  nonisolated static let draftsReminderId = "drafts.evening"
  nonisolated static let openDraftsKey = "openDrafts"

  /// «3 операции ждут разбора — дописать?» at 21:00 while drafts of «Запишу потом» wait — the
  /// row of «Стоит посмотреть» said as a notification too. Taken back when nothing waits, or
  /// when the evening reminders are switched off in «За пределами приложения». No amount and no
  /// name in it, so nothing to hide.
  func scheduleDrafts(_ drafts: [PendingDraft], now: Date, calendar: CalendarContext) async {
    posting.removePending([Self.draftsReminderId])
    let count = DraftReminder.waiting(drafts).count
    guard count > 0, kinds().contains(.evening) else { return }
    let permission = await posting.permission()
    notePermission(permission)
    guard permission == .allowed else { return }
    let language = dependencies?.environment.language ?? AppLanguage()
    let content = UNMutableNotificationContent()
    content.title = language("autoEntry.notify.drafts.title", table: "AutoEntry")
    content.body = language.counted("autoEntry.notify.drafts.body", table: "AutoEntry", [count])
    content.userInfo = [
      "section": MainWindow.Section.overview.rawValue, Self.openDraftsKey: "1",
    ]
    let fire = DraftReminder.nextFire(after: now, calendar: calendar)
    posting.post(
      UNNotificationRequest(
        identifier: Self.draftsReminderId, content: content,
        trigger: UNTimeIntervalNotificationTrigger(
          timeInterval: max(1, fire.timeIntervalSince(now)), repeats: false)))
    AppLog.info(
      "notify.drafts", .ui, "the reminder of the drafts was scheduled",
      [LogPair("count", .count(count))])
  }

  /// The drafts as they are now, scheduled.
  func refreshDrafts() async {
    guard let dependencies else { return }
    let environment = dependencies.environment
    await scheduleDrafts(
      SettingsDraftStore(settings: environment.settings).load(), now: environment.now(),
      calendar: environment.calendar)
  }
}
