import CoreAnalytics
import CoreKit
import Foundation

/// «Свободно на эту неделю: 9 400 ₽»: the free sum to the end of the month divided by the
/// weeks that are left of it. Only a way of looking at the month — the month stays the base of
/// payments, limits and reports.
///
/// The week begins on the first day of the week of the calendar (`firstWeekday`: 1 = Monday …
/// 7 = Sunday, as `DateOnly.weekday` counts): Monday by default, what the Russian calendar of
/// the app uses. The week of today counts as one week even when only a day of it is left, and a
/// week that begins in the month and ends after it counts as one too.
public struct WeekBudget: Hashable, Sendable {
  /// The first day of the week of today (may lie in the month before).
  public var weekStart: DateOnly
  /// The last day of it that belongs to the month.
  public var weekEnd: DateOnly
  /// Weeks left in the month, today's included; at least 1.
  public var weeksLeft: Int
  /// The free sum to the end of the month it was divided from.
  public var freeToMonthEnd: AmountE4
  /// freeToMonthEnd ÷ weeksLeft, rounded half away from zero.
  public var perWeek: AmountE4

  public var today: DateOnly
  /// Days of this week that are left in the month, today's included.
  public var daysLeftInWeek: Int { today.days(to: weekEnd) + 1 }

  /// The free sum is below zero: the week has nothing to give, the month is overspent.
  public var isOverspent: Bool { freeToMonthEnd.isNegative }

  public static func compute(
    freeToMonthEnd: AmountE4, today: DateOnly, firstWeekday: Int = 1
  ) -> WeekBudget {
    let start = weekStart(of: today, firstWeekday: firstWeekday)
    let monthEnd = today.monthKey.lastDay
    let end = min(start.adding(days: 6), monthEnd)
    // Weeks begin on every seventh day from the end of today's week.
    var weeks = 1
    var next = start.adding(days: 7)
    while next <= monthEnd {
      weeks += 1
      next = next.adding(days: 7)
    }
    return WeekBudget(
      weekStart: start, weekEnd: end, weeksLeft: weeks, freeToMonthEnd: freeToMonthEnd,
      perWeek: SavingsMath.divide(freeToMonthEnd, by: weeks), today: today)
  }

  /// The first day of the week `day` is in.
  public static func weekStart(of day: DateOnly, firstWeekday: Int) -> DateOnly {
    let first = min(max(firstWeekday, 1), 7)
    return day.adding(days: -((day.weekday - first + 7) % 7))
  }
}
