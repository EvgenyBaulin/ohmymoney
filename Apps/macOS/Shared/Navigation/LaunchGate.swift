import Foundation

/// What the app asks by itself when it opens, and in which order — the order the Mac main window
/// keeps and the phone keeps too: one question at a time, the setup of the accounts first, then
/// the offer of a report after a crash, then the currencies the bank does not publish, then the
/// reminders and the overdue payments, and after them the questions of `LaunchQuestion` (debts
/// of an old version, the offer of self-employment). Nothing is asked while the app is covered
/// by its lock: the question waits, unspent, for the unlock.
struct LaunchGate: Equatable, Sendable {
  var covered = false
  var asksSetup = false
  var offersProblemReport = false
  var currenciesMissing = false
  /// The reminders sheet is on screen.
  var remindersShown = false
  /// The pipeline is still counting the reminders.
  var remindersCalculating = false

  enum Step: Equatable, Sendable {
    case accountSetup, problemReport, currencies, reminders, questions
  }

  /// The question that stands first now; `nil` while the app is covered.
  var current: Step? {
    if covered { return nil }
    if asksSetup { return .accountSetup }
    if offersProblemReport { return .problemReport }
    if currenciesMissing { return .currencies }
    if remindersShown || remindersCalculating { return .reminders }
    return .questions
  }

  /// The reminders may be shown: nothing before them is waiting for an answer.
  var allowsReminders: Bool {
    !covered && !asksSetup && !offersProblemReport && !currenciesMissing && !remindersShown
  }

  /// The offer of a report waits for the setup.
  var allowsProblemReport: Bool { !covered && !asksSetup }

  /// The currency notice waits for the setup and the reminders on screen.
  var currencyNoticeWaits: Bool { remindersShown || asksSetup }

  /// `LaunchQuestion`s wait for everything before them.
  var questionsWait: Bool {
    remindersShown || remindersCalculating || asksSetup || offersProblemReport
      || currenciesMissing
  }
}
