import AppCore
import Foundation

/// A text a bank sent — an SMS or a push passed on by «Быстрые команды» («Передать сообщение
/// банка»), or pasted — read and acted on as the owner chose: offered first by default
/// («Кафе 450 ₽ — записать?» with «Записать» and «Изменить»), written at once when he switched
/// it so in Settings.
///
/// Every write goes the way of the entry line (`MacCommands.add`, `EntryLineCommand`): the same
/// reading, the same questions, one step of ⌘Z. A question the line would ask — no category
/// said, a card past its limit — is never answered for the owner: the operation is offered
/// instead. An offer waits as a draft of «Запишу потом», so nothing is lost while notifications
/// are off, the app is closed or the owner is away.
///
/// The text itself is kept nowhere: only the fields read out of it (`AutoEntrySuggestion`) and
/// the line they make. An operation already in the books — typed by hand, or the SMS and the
/// push of one purchase — is neither written nor offered again. The balance the bank reports is
/// compared with the account's: a difference is a hint to count, never a count.
@MainActor
final class AutoEntryCenter {
  static let shared = AutoEntryCenter()

  /// `UserDefaults` of this Mac: `propose` (the default) or `immediate`.
  nonisolated static let modeKey = "autoEntry.mode"
  nonisolated static let table = AutoEntryWords.table

  var defaults: UserDefaults = .standard
  /// The texts of the last minutes, in memory only.
  private var recent = AutoEntryRecent()

  func mode() -> AutoEntryMode {
    defaults.string(forKey: Self.modeKey).flatMap(AutoEntryMode.init(rawValue:)) ?? .standard
  }

  /// What one text came to: the answer for «Быстрые команды» and the notification to show.
  struct Result: Equatable {
    var outcome: CommandOutcome
    var action: AutoEntryPlan.Action?
    /// The draft the offer waits in.
    var draftId: UUID?
    /// The notification, when there is one to show.
    var title: String?
    var body: String?
  }

  func receive(_ text: String, commands: MacCommands) async -> Result {
    let environment = commands.environment
    let words = AutoEntryWords(environment: environment)
    if let refusal = commands.refusal(writes: true) { return Result(outcome: .refused(refusal)) }
    guard let whole = commands.compute.wholeSnapshot else {
      return Result(outcome: .refused(commands.t("mac.command.notReady")))
    }
    guard let reading = AutoEntryReading(text, environment: environment, snapshot: whole) else {
      AppLog.info("autoEntry.notBank", .db, "a text passed on was not a bank's")
      return Result(outcome: .refused(words.t("autoEntry.notBank")))
    }
    let message = reading.message
    let line = reading.line
    let isHidden = reading.isHidden
    let placeName = reading.placeName
    let now = environment.now()
    let repeated = recent.repeats(reading.suggestion(receivedAt: now).fingerprint, at: now)
    let duplicate =
      reading.isInBooks || repeated
      || reading.isWaiting(environment: environment, defaults: defaults)
    let mismatch = reading.mismatch(includesOperation: duplicate)

    // An operation of a hidden account is always offered: written at once it would land on the
    // main card, since its line does not name the card.
    var action = AutoEntryPlan.action(
      mode: isHidden ? .propose : mode(), isDuplicate: duplicate)
    var outcome = CommandOutcome.done(words.t("autoEntry.duplicate"))
    var draftId: UUID?
    if action == .write {
      let written = await commands.add(line: line)
      if case .done = written {
        outcome = written
      } else {
        action = AutoEntryPlan.afterWrite(succeeded: false)
      }
    }
    if action == .propose {
      guard let id = reading.keepDraft(environment: environment, now: now, defaults: defaults)
      else {
        return Result(
          outcome: .refused(environment.language("entry.error.notSaved", table: "Entry")))
      }
      draftId = id
      outcome = .done(
        isHidden
          ? words.t("autoEntry.proposed.hidden")
          : words.f(
            "autoEntry.proposed",
            words.subject(
              name: placeName, operation: message.operation, money: message.money,
              saysAmount: !environment.amounts.isHidingNow)))
    }
    AppLog.info(
      "autoEntry.received", .db, "a text of a bank was read",
      [
        LogPair("action", .token(action.token)), LogPair("hidden", .flag(isHidden)),
        LogPair("mismatch", .flag(mismatch != nil)),
      ])

    let privacy = MacNotifications.shared.privacy()
    let notice = AutoEntryPlan.notice(
      for: action, hiddenAccount: isHidden, hidden: privacy.hiddenAccountNotices,
      amountsHidden: environment.amounts.isHidingNow, amountsAlways: privacy == .always)
    let saysAmount = privacy.saysAmount(hidesAmounts: environment.amounts.isHidingNow)
    var result = Result(outcome: outcome, action: action, draftId: draftId)
    switch notice {
    case .none:
      // A message about an operation typed by hand still tells a balance that does not agree.
      if action == .skipDuplicate, let mismatch, !isHidden {
        result.title = words.t("autoEntry.notify.mismatchTitle")
        result.body = words.mismatch(mismatch, saysAmount: saysAmount)
      }
    case .anonymous:
      result.title = words.t(
        action == .write ? "autoEntry.notify.anonymousWritten" : "autoEntry.notify.anonymous")
      result.body = words.t("autoEntry.notify.fromBank")
    case .named(let amount):
      let subject = words.subject(
        name: placeName, operation: message.operation, money: message.money,
        saysAmount: amount)
      result.title = words.f(
        action == .write ? "autoEntry.notify.written" : "autoEntry.notify.propose", subject)
      result.body =
        mismatch.map { words.mismatch($0, saysAmount: amount) }
        ?? words.t("autoEntry.notify.fromBank")
    }
    return result
  }

  /// «Записать» of the notification: the draft written as Return in the line writes it. When the
  /// line would ask something, the draft stays and `false` says to open it in the window.
  func recordDraft(_ id: UUID, commands: MacCommands) async -> Bool {
    let store = SettingsDraftStore(settings: commands.environment.settings)
    guard let draft = store.load().first(where: { $0.id == id }) else { return false }
    guard case .done = await commands.add(line: draft.text) else { return false }
    _ = store.save(store.load().filter { $0.id != id })
    _ = AutoEntryLearning.takeMerchant(ofDraft: id, defaults: defaults)
    NotificationCenter.default.post(name: .draftsChanged, object: nil)
    AppLog.info("autoEntry.recorded", .db, "an offered operation was written from its notification")
    return true
  }

  /// A text from the pasteboard, passed on as «Быстрые команды» pass one.
  func receivePasteboard(_ text: String?, commands: MacCommands) async -> Result {
    guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return Result(
        outcome: .refused(AutoEntryWords(environment: commands.environment).t("autoEntry.notBank")))
    }
    return await receive(text, commands: commands)
  }
}

extension AutoEntryPlan.Action {
  fileprivate var token: String {
    switch self {
    case .skipDuplicate: "duplicate"
    case .write: "write"
    case .propose: "propose"
    }
  }
}

extension NotificationPlan.Privacy {
  /// The owner's choice of what notifications say, read for an operation of a hidden account.
  var hiddenAccountNotices: AutoEntryPlan.HiddenAccountNotices {
    switch self {
    case .quiet: .silent
    case .anonymous: .anonymous
    case .always: .full
    }
  }
}
