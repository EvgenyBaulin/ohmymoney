import AppCore
import Foundation

/// The birthdays of the people on the days a calendar shows: a mark on the day, and under the
/// grid «День рождения Маши, бюджет 5 000 ₽» with a button that makes the event.
enum CalendarBirthdays {
  /// The birthdays that fall on `days`, by day, in the order of the names. A birthday of the
  /// 29th of February falls on the 28th in a year without one (`GiftCalendar.date`). People
  /// without a birthday and archived ones are left out.
  static func gifts(
    people: [Person], on days: [DateOnly], today: DateOnly
  ) -> [DateOnly: [GiftDay]] {
    let shown = Set(days)
    let years = Set(days.map(\.year))
    var found: [DateOnly: [GiftDay]] = [:]
    for person in people where !person.archived {
      guard let birthday = person.birthday else { continue }
      for year in years {
        let date = GiftCalendar.date(of: birthday, in: year)
        guard shown.contains(date) else { continue }
        let left = today.days(to: date)
        found[date, default: []].append(
          GiftDay(
            personId: person.id, name: person.name, date: date, daysLeft: left,
            turnsAge: birthday.year.map { year - $0 }, budgetE4: person.giftBudgetE4,
            reminderDue: left >= 0 && left <= GiftCalendar.reminderDays))
      }
    }
    return found.mapValues { $0.sorted { $0.name < $1.name } }
  }

  /// The button «Создать событие с бюджетом» is offered for today and the days ahead, until the
  /// event of that name exists.
  @MainActor static func offersEvent(
    for day: GiftDay, events: [Event], _ environment: AppEnvironment
  )
    -> Bool
  {
    day.daysLeft >= 0 && !PurchaseHookActions.hasEvent(for: day, events: events, environment)
  }
}
