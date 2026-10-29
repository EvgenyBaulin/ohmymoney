import CoreAnalytics
import CoreKit
import Foundation

/// A birthday that is coming, with what the owner is ready to spend on a gift.
public struct GiftDay: Hashable, Sendable, Identifiable {
  public var personId: UUID
  public var name: String
  /// The day it falls on this time round (29 February is the 28th in a year without one).
  public var date: DateOnly
  /// Days from today: 0 on the day itself.
  public var daysLeft: Int
  /// The age the person turns, when the year of birth is known.
  public var turnsAge: Int?
  public var budgetE4: AmountE4?
  /// The reminder is due: a week before, up to the day itself.
  public var reminderDue: Bool
  public var id: String { "\(personId.uuidString):\(date.iso)" }

  public init(
    personId: UUID, name: String, date: DateOnly, daysLeft: Int, turnsAge: Int?,
    budgetE4: AmountE4?, reminderDue: Bool
  ) {
    self.personId = personId
    self.name = name
    self.date = date
    self.daysLeft = daysLeft
    self.turnsAge = turnsAge
    self.budgetE4 = budgetE4
    self.reminderDue = reminderDue
  }
}

/// The calendar of gifts: birthdays of the people, a reminder a week before, a budget for a gift.
public enum GiftCalendar {
  /// How many days before the birthday the reminder speaks.
  public static let reminderDays = 7

  /// The day a birthday falls on in `year`: a day the month does not have (the 29th of February
  /// in a common year, a 31st of April) falls on the last day of the month.
  public static func date(of birthday: Birthday, in year: Int) -> DateOnly {
    let length = MonthKey(year: year, month: birthday.month).dayCount
    return DateOnly(year: year, month: birthday.month, day: min(birthday.day, length))
  }

  /// The next time the birthday falls on, today included.
  public static func nextOccurrence(of birthday: Birthday, from today: DateOnly) -> DateOnly {
    let thisYear = date(of: birthday, in: today.year)
    return thisYear >= today ? thisYear : date(of: birthday, in: today.year + 1)
  }

  /// The birthdays within `withinDays` of `today`, the nearest first. People without a birthday
  /// and archived ones are left out.
  public static func upcoming(people: [Person], today: DateOnly, withinDays: Int = 60) -> [GiftDay] {
    var days: [GiftDay] = []
    for person in people where !person.archived {
      guard let birthday = person.birthday else { continue }
      let next = nextOccurrence(of: birthday, from: today)
      let left = today.days(to: next)
      guard left <= withinDays else { continue }
      days.append(
        GiftDay(
          personId: person.id, name: person.name, date: next, daysLeft: left,
          turnsAge: birthday.year.map { next.year - $0 }, budgetE4: person.giftBudgetE4,
          reminderDue: left <= reminderDays))
    }
    return days.sorted { left, right in
      if left.daysLeft != right.daysLeft { return left.daysLeft < right.daysLeft }
      return left.name < right.name
    }
  }

  /// The event for a gift: one day, with the person's gift budget as the budget (`nil` when none
  /// is set), repeating yearly. The owner gives it its name (the interface's «День рождения: …»).
  public static func event(for day: GiftDay, name: String) -> Event {
    Event(
      name: name, kind: .birthday, startDate: day.date, endDate: day.date,
      budgetE4: day.budgetE4, recurringYearly: true)
  }
}
