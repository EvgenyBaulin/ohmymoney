import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation

/// The month helpers of a debt's schedule: when it began, whether a month has a payment, the
/// payment day of a month. Which dues are paid — each payment closing the earliest one still
/// unpaid — is `DebtDues`, which every screen reads (`DebtLine.dues`); what is here answers
/// about one month alone.
public enum DebtSchedule {

  /// The day of the next payment as one month tells it — this month's day until a payment is
  /// dated in it, then next month's —, or `nil` for a debt without a payment day and for a
  /// closed one. The screens read `DebtDueState.firstUnpaid` instead, which sees every month
  /// since the debt began.
  ///
  /// * The payment day is clipped to the length of the month: a debt paid on the 31st is due
  ///   on 30 September and on 28 (29) February.
  /// * Once this month's payment is made, the next one is next month's.
  /// * A payment not made yet stays on this month's day even after that day has passed: it
  ///   is overdue, not skipped, so the reminder keeps pointing at it.
  /// * A payment day before the debt began (`start`, the earliest day of its journal:
  ///   `start(of:calendar:)`) owed nothing: a phone bought in parts on the 15th, paid on the
  ///   5th, first owes on the 5th of the next month. A loan that began on its payment day
  ///   owes that day; something bought on credit on its payment day first owes a month later.
  /// * A payment made in the month the debt began, when that month owed nothing, has nothing
  ///   to pay but the first due: the phone paid on 25 September next owes on 5 November.
  ///
  /// `paidThisMonth` is whether this month's payment is made — `isPaid(_:for:startsOn:…)`,
  /// which knows that rule for the first month that owes.
  public static func nextPaymentDate(
    of debt: Debt, today: DateOnly, paidThisMonth: Bool, calendar: CalendarContext,
    startsOn start: DateOnly? = nil
  ) -> DateOnly? {
    guard !debt.closed, let paymentDay = debt.paymentDay, paymentDay >= 1 else { return nil }
    func payday(_ month: MonthKey) -> DateOnly {
      DateOnly(
        year: month.year, month: month.month,
        day: min(paymentDay, calendar.daysInMonth(month)))
    }
    let current = today.monthKey
    if let start, let first = firstMonth(of: debt, startsOn: start, calendar: calendar),
      current < first
    {
      // Nothing is owed before the first month; what was paid in the month the debt began
      // pays the first due.
      return payday(paidThisMonth && current == start.monthKey ? first.next : first)
    }
    return payday(paidThisMonth ? current.next : current)
  }

  /// The first month a debt owes: the month it began, or the next one when the payment day of
  /// that month came before the start. `nil` for a debt without a payment day. The rule lives
  /// in `DebtStart`, which the forecast of the month shares.
  public static func firstMonth(
    of debt: Debt, startsOn start: DateOnly, calendar: CalendarContext
  ) -> MonthKey? {
    DebtStart.firstMonth(of: debt, startsOn: start, calendar: calendar)
  }

  /// Whether the payment of `month` is made: a payment dated in that month (`paidIn`, the
  /// month rule of `isPaid(_:in:paidByOperation:journal:)`) — or, for the first month a debt
  /// owes when the month it began owed nothing, one dated in the month it began. Every screen
  /// that asks whether a month of a debt is paid asks here, so the Debts screen, the 7-day
  /// card, the reminders, the planned month and the free sum agree.
  public static func isPaid(
    _ debt: Debt, for month: MonthKey, startsOn start: DateOnly?, calendar: CalendarContext,
    paidIn: (MonthKey) -> Bool
  ) -> Bool {
    DebtStart.isPaid(debt, for: month, startsOn: start, calendar: calendar, paidIn: paidIn)
  }

  /// The day a debt began: the earliest day of its own journal — a line's date, else the day
  /// of its moment; `nil` for a journal with neither (`DebtStart.day(of:calendar:)`, the rule
  /// the forecast of the month shares).
  public static func start(
    of journal: some Sequence<DebtEntry>, calendar: CalendarContext
  ) -> DateOnly? {
    DebtStart.day(of: journal, calendar: calendar)
  }

  /// Was the debt paid in the calendar month of `today`?
  ///
  /// It was when an operation dated in that month points at the debt (`debt_id`) — the rule
  /// the forecast uses for planned payments (`PlannedPayments`) — or when the journal has a
  /// `payment` line dated in that month, which covers a payment recorded on the card alone.
  /// The whole month counts, a payment entered ahead with a later date included. An
  /// «Offset» is not a payment: its operation points at the debt too, but its journal line
  /// is an `offset`, so it is left out.
  public static func isPaid(
    _ debt: Debt, inMonthOf today: DateOnly, ledger: Ledger, journal: [DebtEntry]
  ) -> Bool {
    isPaid(
      debt.id, in: today.monthKey,
      paidByOperation: debtsPaid(in: today.monthKey, ledger: ledger, journal: journal),
      journal: journal)
  }

  /// The debts an operation dated in `month` points at, found once for the whole section.
  /// Operations the journal has an `offset` line for («Offset») or a `borrowed` line for
  /// (money taken or lent more through the entry line) are not payments and are skipped.
  /// Payments typed in the entry line may have no journal line at all and still count.
  static func debtsPaid(in month: MonthKey, ledger: Ledger, journal: [DebtEntry]) -> Set<UUID> {
    let offsets = notPayments(journal)
    var paid: Set<UUID> = []
    for row in ledger.rows(in: Period.month(month).range) {
      guard let debtId = row.debtId, !offsets.contains(row.transactionId) else { continue }
      paid.insert(debtId)
    }
    return paid
  }

  /// The operations that point at a debt without paying it: the journal wrote them as an
  /// `offset` or as more `borrowed`.
  public static func notPayments(_ journal: [DebtEntry]) -> Set<UUID> {
    DebtRules.notPayments(journal)
  }

  static func isPaid(
    _ debtId: UUID, in month: MonthKey, paidByOperation: Set<UUID>, journal: [DebtEntry]
  ) -> Bool {
    paidByOperation.contains(debtId)
      || journal.contains { entry in
        entry.debtId == debtId && entry.kind == .payment && entry.date?.monthKey == month
      }
  }
}
