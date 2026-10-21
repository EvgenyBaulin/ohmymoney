import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation

/// What a reminder is about. Keys are stable (`reminders.kind.<name>`): the app looks the
/// words up by them.
public enum ReminderKind: String, CaseIterable, Hashable, Sendable {
  /// A scheduled payment or subscription is due.
  case payment
  /// The trial of a subscription ends: the last days to cancel it for free.
  case trialEnds
  /// A subscription changes its price.
  case priceChange
  /// The monthly payment of a debt I owe is due.
  case debtPayment
  /// It is time to reconcile the accounts.
  case reconciliation

  public var key: String { "reminders.kind." + rawValue }
}

/// How pressing a reminder is; the list shows the most pressing first.
public enum ReminderUrgency: Int, CaseIterable, Comparable, Hashable, Sendable {
  case overdue
  case today
  case soon

  public static func < (lhs: ReminderUrgency, rhs: ReminderUrgency) -> Bool {
    lhs.rawValue < rhs.rawValue
  }

  /// Before today is overdue, today is today, anything later is soon.
  public init(due: DateOnly, today: DateOnly) {
    if due < today {
      self = .overdue
    } else if due == today {
      self = .today
    } else {
      self = .soon
    }
  }
}

/// One reminder of the pipeline's last step (payments, debts, reconciliation).
///
/// The id names the subject **and** the occasion — `pay:<payment>:<due>`,
/// `trial:<payment>:<date>`, `price:<payment>:<date>`, `debt:<debt>:<due>`,
/// `reconcile:<day of the last one | none>`, UUIDs lowercased. Putting a reminder off
/// stores its id (`PlanningSettings.dismissedReminders`), so it stays away until the
/// occasion changes — the next due date, the next reconciliation — and then comes back
/// by itself, without a timer.
public struct Reminder: Identifiable, Hashable, Sendable {
  public var id: String
  public var kind: ReminderKind
  /// The day it is about; `nil` only for the very first reconciliation.
  public var due: DateOnly?
  /// The payment, the debt or the last reconciliation it is about.
  public var subjectId: UUID?
  public var urgency: ReminderUrgency

  public init(
    id: String, kind: ReminderKind, due: DateOnly?, subjectId: UUID?, urgency: ReminderUrgency
  ) {
    self.id = id
    self.kind = kind
    self.due = due
    self.subjectId = subjectId
    self.urgency = urgency
  }
}

/// Builds the reminders of scheduled payments, subscriptions, debts and reconciliation.
public enum ReminderRules {
  /// Days ahead a payment, a trial or a debt is reminded of when it sets no days itself.
  public static let defaultDaysBefore = 3
  /// Days ahead a price change of a subscription is announced. A row dated today is the
  /// price today, as `SubscriptionMath.upcomingPriceChange` reads it — already in force, and
  /// what an edit of the amount writes — so only rows after today are announced.
  public static let priceChangeDaysAhead = 7

  /// Every reminder for `today`, overdue first, then today's, then the coming ones; inside
  /// each by date. Reminders put off by the owner are left out. `matches` are the due dates
  /// ordinary operations paid (`ScheduledMatching`); without them they are worked out here.
  public static func build(
    book: PlanningBook, debts: [Debt], ledger: Ledger, today: DateOnly,
    matches: ScheduledMatches? = nil
  ) -> [Reminder] {
    let dismissed = book.settings.dismissedReminders
    return all(book: book, debts: debts, ledger: ledger, today: today, matches: matches)
      .filter { !dismissed.contains($0.id) }
  }

  /// Every reminder for `today`, the ones put off included, in the same order.
  public static func all(
    book: PlanningBook, debts: [Debt], ledger: Ledger, today: DateOnly,
    matches: ScheduledMatches? = nil
  ) -> [Reminder] {
    let matches =
      matches
      ?? ScheduledMatching.matches(
        book: book, ledger: ledger, today: today,
        rejections: book.settings.scheduledMatchRejections)
    var reminders: [Reminder] = []
    reminders += scheduled(book: book, today: today, matches: matches)
    reminders += debtPayments(
      debts: debts, journal: book.debtEntries, ledger: ledger, today: today)
    if let reconciliation = reconciliation(book: book, today: today) {
      reminders.append(reconciliation)
    }
    return reminders.sorted(by: precedes)
  }

  /// The ids put off after × on `id`. A put-off id stays while its reminder still reminds —
  /// however old the date in it: a payment unpaid for weeks, a reconciliation due since last
  /// month — and goes once it does not (the due date paid, a reconciliation made), which
  /// keeps the setting from growing for ever. `active` is `all(...)` of the data at hand;
  /// without it (no data yet) nothing is forgotten.
  public static func dismissed(
    adding id: String, to stored: Set<String>, active: Set<String>?
  ) -> Set<String> {
    guard let active else { return stored.union([id]) }
    return stored.intersection(active).union([id])
  }

  // MARK: - Scheduled payments and subscriptions

  /// The first due date from `next_date` on that nothing paid, while it is within the days
  /// the payment is reminded ahead. «Mark as paid» writes `sched:<payment>:<due>` and moves
  /// `next_date` on; if the move did not happen, the operation still says the due date is
  /// paid, and so does an ordinary operation that matches it — the next one is reminded then.
  private static func scheduled(
    book: PlanningBook, today: DateOnly, matches: ScheduledMatches
  ) -> [Reminder] {
    let pricesByPayment = Dictionary(grouping: book.prices, by: \.paymentId)

    var reminders: [Reminder] = []
    for payment in book.scheduled where payment.active {
      let ahead = max(0, payment.remindDaysBefore ?? defaultDaysBefore)
      let horizon = today.adding(days: ahead)
      let paymentId = payment.id.uuidString.lowercased()

      let unpaid = payment.nextDate.flatMap { next in
        Recurrence.occurrences(
          from: next, through: horizon, rule: RecurrenceRule(payment: payment),
          end: payment.endDate, limit: ScheduledMatching.duesPerPayment
        ).first { !matches.isPaid(payment.id, $0) }
      }
      if let due = unpaid {
        reminders.append(
          Reminder(
            id: "pay:\(paymentId):\(due.iso)", kind: .payment, due: due, subjectId: payment.id,
            urgency: ReminderUrgency(due: due, today: today)))
      }

      // A trial that already ended can no longer be cancelled for free: nothing to remind.
      if let trialEnd = payment.trialEnd, trialEnd >= today, trialEnd <= horizon {
        reminders.append(
          Reminder(
            id: "trial:\(paymentId):\(trialEnd.iso)", kind: .trialEnds, due: trialEnd,
            subjectId: payment.id, urgency: ReminderUrgency(due: trialEnd, today: today)))
      }

      let prices = (pricesByPayment[payment.id] ?? []).sorted { $0.date < $1.date }
      let lastAnnounced = today.adding(days: priceChangeDaysAhead)
      for price in prices where price.date > today && price.date <= lastAnnounced {
        // Compared with the price just before it: two changes in one week are two
        // reminders, and a row that repeats the price changes nothing.
        let before = prices.last { $0.date < price.date }?.amountE4 ?? payment.amountE4
        guard price.amountE4 != before else { continue }
        reminders.append(
          Reminder(
            id: "price:\(paymentId):\(price.date.iso)", kind: .priceChange, due: price.date,
            subjectId: payment.id, urgency: ReminderUrgency(due: price.date, today: today)))
      }
    }
    return reminders
  }

  // MARK: - Debts

  /// The monthly payment of an open debt I owe, on its payment day — the 31st is the last
  /// day of a shorter month: the earliest due nothing paid yet (`DebtDueState.firstUnpaid` —
  /// each payment closes the earliest due still unpaid, counted from the start of the debt),
  /// overdue ones of earlier months included, while it is within the days the debt is reminded
  /// ahead. A debt with nothing left on it reminds of nothing.
  private static func debtPayments(
    debts: [Debt], journal: [DebtEntry], ledger: Ledger, today: DateOnly
  ) -> [Reminder] {
    let owed = debts.filter { !$0.closed && $0.direction == .iOwe }
    let states = DebtDues.states(debts: owed, ledger: ledger, journal: journal, today: today)
    var reminders: [Reminder] = []
    for debt in owed {
      guard let due = states[debt.id]?.firstUnpaid else { continue }
      let ahead = max(0, debt.remindDaysBefore ?? defaultDaysBefore)
      guard due <= today.adding(days: ahead) else { continue }
      reminders.append(
        Reminder(
          id: "debt:\(debt.id.uuidString.lowercased()):\(due.iso)", kind: .debtPayment, due: due,
          subjectId: debt.id, urgency: ReminderUrgency(due: due, today: today)))
    }
    return reminders
  }

  // MARK: - Reconciliation

  /// Due before the first reconciliation, and once more than `reconcileEveryDays` days have
  /// passed since the one the reminder counts from (`AccountReconciliation.reminderAnchor`) —
  /// from the day after that, which is its due date.
  private static func reconciliation(book: PlanningBook, today: DateOnly) -> Reminder? {
    let last = AccountReconciliation.reminderAnchor(book: book)
    let everyDays = book.settings.reconcileEveryDays
    guard AccountReconciliation.isDue(book: book, today: today, everyDays: everyDays) else {
      return nil
    }
    guard let last else {
      return Reminder(
        id: "reconcile:none", kind: .reconciliation, due: nil, subjectId: nil, urgency: .today)
    }
    let due = last.date.adding(days: everyDays + 1)
    return Reminder(
      id: "reconcile:\(last.date.iso)", kind: .reconciliation, due: due, subjectId: last.id,
      urgency: ReminderUrgency(due: due, today: today))
  }

  // MARK: - Order

  /// Urgency, then date (a reminder without one last), then kind, then id — never the order
  /// the records happened to come in.
  private static func precedes(_ left: Reminder, _ right: Reminder) -> Bool {
    if left.urgency != right.urgency { return left.urgency < right.urgency }
    switch (left.due, right.due) {
    case (let first?, let second?) where first != second: return first < second
    case (.some, .none): return true
    case (.none, .some): return false
    default: break
    }
    let kinds = ReminderKind.allCases
    let leftKind = kinds.firstIndex(of: left.kind) ?? 0
    let rightKind = kinds.firstIndex(of: right.kind) ?? 0
    if leftKind != rightKind { return leftKind < rightKind }
    return left.id < right.id
  }
}
