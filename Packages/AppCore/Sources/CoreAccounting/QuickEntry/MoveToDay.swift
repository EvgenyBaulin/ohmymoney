import CoreKit
import Foundation

/// What dragging an operation to another day of the spending calendar does: the time of day stays, and everything an edit checks is checked again — the
/// reconciliation before it, the debt, the rate of the Bank of Russia for the new day. The
/// app runs those checks and writes the move as one step, undone by one ⌘Z; this is the part that
/// needs no database.
public struct MovePlan: Hashable, Sendable {
  public var fromDay: DateOnly
  public var toDay: DateOnly
  /// The same clock time on the new day, in the zone the operation was recorded in.
  public var occurredAt: Date
  /// The operation changes its month: monthly limits, the month of an income and the reports
  /// move with it.
  public var changesMonth: Bool
  /// The operation is in a foreign currency and its rate is the bank's, not one typed by hand:
  /// the rate of the new day replaces it. A rate typed by hand or imported stays.
  public var needsRateOfNewDay: Bool
  /// The new day is after today: the owner is asked whether to write it as it is or plan it.
  public var isAhead: Bool
}

public enum MoveToDay {
  /// The move, or nil when the operation is already on that day.
  public static func plan(
    for transaction: Transaction, to day: DateOnly, today: DateOnly, calendar: CalendarContext
  ) -> MovePlan? {
    let from = calendar.day(of: transaction.occurredAt, recordedIn: transaction.timeZoneId)
    guard from != day else { return nil }
    let clock = calendar.timeOfDay(transaction.occurredAt, recordedIn: transaction.timeZoneId)
    let zone = CalendarContext(timeZone: calendar.zone(recordedIn: transaction.timeZoneId))
    let protectedRate = transaction.rateSource?.isProtected ?? false
    return MovePlan(
      fromDay: from, toDay: day,
      occurredAt: zone.moment(day, hour: clock.hour, minute: clock.minute),
      changesMonth: from.monthKey != day.monthKey,
      needsRateOfNewDay: transaction.currency != .rub && !protectedRate,
      isAhead: day > today)
  }
}
