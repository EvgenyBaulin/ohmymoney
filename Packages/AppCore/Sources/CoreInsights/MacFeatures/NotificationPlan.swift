import CoreKit
import CorePlanning
import Foundation

/// What the system notifications of the Mac say, decided from the numbers the app already
/// has: a payment due tomorrow (with «Записать оплату» right in the notification), a limit that
/// is nearly spent or overspent, and «Итоги» that are ready.
///
/// Each notice has an id that names its subject **and** its occasion — `pay:<payment>:<due>`
/// (the id of the reminder), `limit:<budget>:<month>:near|over`, `summary:<kind>:<key>` — so
/// a notice is posted once, a payment paid early takes its pending notice away, and next
/// month's limit is news again.
public enum NotificationPlan {
  /// The three kinds the owner can switch on and off one by one.
  public enum Kind: String, CaseIterable, Hashable, Sendable {
    case payments
    case limits
    case summaries
  }

  public enum Subject: Hashable, Sendable {
    /// `due` is tomorrow, or later and the notice waits for the day before it.
    case paymentTomorrow(paymentId: UUID, due: DateOnly)
    /// Spent most of the limit of the month (its status is «warning»).
    case limitNear(budgetId: UUID, month: MonthKey)
    case limitOver(budgetId: UUID, month: MonthKey)
    case summary(SummaryID)
  }

  /// What a notification may say, the owner's choice in Settings: a notice is seen outside the
  /// app — on the screen, in the Notification Center — so by default it keeps to what «Скрыть
  /// суммы» and the hidden accounts keep.
  public enum Privacy: String, CaseIterable, Hashable, Sendable {
    /// No amount while the amounts are hidden; nothing about a hidden account. The default.
    case quiet
    /// As `quiet`, but a payment of a hidden account is announced too — «Платёж завтра», with
    /// neither its name nor its amount.
    case anonymous
    /// Always the name and the amount, hidden accounts and hidden amounts too.
    case always

    public static let standard = Privacy.quiet

    /// Whether a notice says an amount, given whether the amounts are hidden now.
    public func saysAmount(hidesAmounts: Bool) -> Bool {
      self == .always || !hidesAmounts
    }
  }

  public struct Notice: Hashable, Sendable, Identifiable {
    public var id: String
    public var subject: Subject
    /// The day the notice is shown on — the morning of the day before a payment; today or
    /// earlier means at once.
    public var day: DateOnly
    /// A payment of a hidden account announced without its name and amount (`Privacy.anonymous`).
    public var anonymous: Bool = false

    public init(id: String, subject: Subject, day: DateOnly, anonymous: Bool = false) {
      self.id = id
      self.subject = subject
      self.day = day
      self.anonymous = anonymous
    }

    public var kind: Kind {
      switch subject {
      case .paymentTomorrow: .payments
      case .limitNear, .limitOver: .limits
      case .summary: .summaries
      }
    }
  }

  /// - Parameters:
  ///   - reminders: the reminders of the planning step (`ReminderRules.build`): what is put off
  ///     there is not announced either.
  ///   - limits: the limits of this month (`PlanningSnapshot.limits`).
  ///   - summaries: the summaries ready today (`SummaryScheduler.ready`).
  ///   - posted: ids already shown; a notice shown once is not shown again.
  ///   - hiddenPayments: payments of hidden accounts: not announced (`quiet`), announced
  ///     without name and amount (`anonymous`) or as any other (`always`), as `privacy` says.
  public static func notices(
    today: DateOnly, reminders: [Reminder], limits: [LimitLine], summaries: [SummaryID],
    posted: Set<String>, kinds: Set<Kind> = Set(Kind.allCases), hiddenPayments: Set<UUID> = [],
    privacy: Privacy = .standard
  ) -> [Notice] {
    var notices: [Notice] = []
    if kinds.contains(.payments) {
      for reminder in reminders where reminder.kind == .payment {
        guard let due = reminder.due, let payment = reminder.subjectId, due > today else {
          continue
        }
        let hidden = hiddenPayments.contains(payment)
        if hidden, privacy == .quiet { continue }
        notices.append(
          Notice(
            id: reminder.id, subject: .paymentTomorrow(paymentId: payment, due: due),
            day: due.adding(days: -1), anonymous: hidden && privacy == .anonymous))
      }
    }
    if kinds.contains(.limits) {
      for line in limits {
        let budget = line.budget.id.uuidString.lowercased()
        let month = line.month.iso
        switch line.status {
        case .ok:
          continue
        case .warning:
          notices.append(
            Notice(
              id: "limit:\(budget):\(month):near",
              subject: .limitNear(budgetId: line.budget.id, month: line.month), day: today))
        case .over:
          notices.append(
            Notice(
              id: "limit:\(budget):\(month):over",
              subject: .limitOver(budgetId: line.budget.id, month: line.month), day: today))
        }
      }
    }
    if kinds.contains(.summaries) {
      for summary in summaries {
        notices.append(Notice(id: "summary:\(summary)", subject: .summary(summary), day: today))
      }
    }
    return notices.filter { !posted.contains($0.id) }
  }

  /// The ids worth remembering as posted: the ones still announced by the data at hand plus
  /// those just posted. Everything else is forgotten, so the setting does not grow for ever.
  /// A limit overspent last month, or a payment paid, is not news again: its id names a month
  /// or a due date that does not come back.
  public static func posted(
    keeping stored: Set<String>, adding new: Set<String>, active: Set<String>
  ) -> Set<String> {
    stored.intersection(active).union(new)
  }

  // MARK: - Permission

  /// What the system says about notifications for the app.
  public enum Permission: Hashable, Sendable {
    case undetermined
    case allowed
    case denied
  }

  public enum Step: Hashable, Sendable {
    /// Nothing to say, or nobody to say it to.
    case nothing
    /// There is something to say for the first time: the app explains in its own words what
    /// it would notify about, and only then lets the system ask.
    case explain
    case post
  }

  /// Permission is asked when there is first something to say, never at launch, and after an
  /// explanation: `explained` is set once the owner saw it, whatever was answered, so a «Not
  /// now» is not asked again by the app.
  public static func step(
    notices: [Notice], permission: Permission, explained: Bool
  ) -> Step {
    guard !notices.isEmpty else { return .nothing }
    switch permission {
    case .allowed: return .post
    case .denied: return .nothing
    case .undetermined: return explained ? .nothing : .explain
    }
  }
}
