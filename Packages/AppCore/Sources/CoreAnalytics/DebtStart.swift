import CoreKit
import Foundation

/// When a debt began and which of its monthly dues it owes — the one rule the forecast of the
/// month (`PlannedPayments`) and every planning screen (`DebtSchedule` in CorePlanning, which
/// forwards here) share, so the forecast never expects a payment the Debts screen, the planned
/// month, the free sum and the reminders do not.
///
/// A debt begins on the earliest day of its own journal. A payment day before that owed
/// nothing: a loan taken on the 15th, paid on the 5th, first owes on the 5th of the next month;
/// a loan taken on its payment day owes that day. Something bought on credit pays its first
/// instalment a month after the purchase: bought on its payment day, it first owes a month
/// later, or the purchase day would stay one due unpaid for the whole term. A payment made in
/// the month the debt began, when that month owed nothing, pays the first due.
public enum DebtStart {
  /// The day a debt began: the earliest day of its own journal — a line's date, else the day
  /// of its moment; `nil` for a journal with neither.
  public static func day(
    of journal: some Sequence<DebtEntry>, calendar: CalendarContext
  ) -> DateOnly? {
    journal.compactMap { entry in entry.date ?? entry.occurredAt.map { calendar.day(of: $0) } }
      .min()
  }

  /// The day each debt of `journal` began, the journal read once.
  public static func days(
    of journal: [DebtEntry], calendar: CalendarContext
  ) -> [UUID: DateOnly] {
    Dictionary(grouping: journal, by: \.debtId).compactMapValues { lines in
      day(of: lines, calendar: calendar)
    }
  }

  /// Whether a due on `due` is owed at all: it is not when it came before the debt began. A
  /// debt with nothing to say when it began (`start == nil`) owes every due.
  public static func owes(due: DateOnly, startsOn start: DateOnly?) -> Bool {
    start.map { due >= $0 } ?? true
  }

  /// The first month a debt owes: the month it began, or the next one when the payment day of
  /// that month came before the start — or, for something bought on credit, fell on it. `nil`
  /// for a debt without a payment day.
  public static func firstMonth(
    of debt: Debt, startsOn start: DateOnly, calendar: CalendarContext
  ) -> MonthKey? {
    guard let day = debt.paymentDay, day >= 1 else { return nil }
    let began = start.monthKey
    let payday = DateOnly(
      year: began.year, month: began.month, day: min(day, calendar.daysInMonth(began)))
    let owesNextMonth = debt.origin == .purchase ? payday <= start : payday < start
    return owesNextMonth ? began.next : began
  }

  /// Whether the payment of `month` is made: a payment dated in that month (`paidIn`) — or,
  /// for the first month a debt owes when the month it began owed nothing, one dated in the
  /// month it began.
  public static func isPaid(
    _ debt: Debt, for month: MonthKey, startsOn start: DateOnly?, calendar: CalendarContext,
    paidIn: (MonthKey) -> Bool
  ) -> Bool {
    if paidIn(month) { return true }
    guard let start, let first = firstMonth(of: debt, startsOn: start, calendar: calendar),
      month == first, first != start.monthKey
    else { return false }
    return paidIn(start.monthKey)
  }
}
