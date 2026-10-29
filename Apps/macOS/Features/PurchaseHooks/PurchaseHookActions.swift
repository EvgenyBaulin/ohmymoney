import AppCore
import Foundation

extension Notification.Name {
  /// Asks the main window to open the list of wishes (object `"wishes"`) or the refunds waited
  /// for (object `"refunds"`).
  static let openPurchaseList = Notification.Name("openPurchaseList")
}

/// What the lines of «Стоит посмотреть» and the calendar of gifts write: the answer to «Не
/// пожалели?» and the event of a birthday.
@MainActor
enum PurchaseHookActions {
  /// The answer put on the operation (`RegretSchedule.recording`): one write, one step of ⌘Z.
  @discardableResult
  static func answerRegret(
    _ answer: PurchaseRegret, transactionId: UUID, deps: AppDependencies
  ) -> Bool {
    guard var entry = deps.store.entry(id: transactionId) else { return false }
    entry.transaction = RegretSchedule.recording(
      answer, on: entry.transaction, today: deps.environment.today)
    return deps.store.save(entry)
  }

  /// The name of the event a birthday makes: «День рождения: Маша».
  static func eventName(for day: GiftDay, _ environment: AppEnvironment) -> String {
    PurchaseHookText.f("look.purchase.eventName", environment, day.name)
  }

  /// The event of a birthday with the gift budget as its budget (`GiftCalendar.event`), through
  /// the same action the form of an event uses. `false` when it was not written — an event of that
  /// name on that day exists already.
  @discardableResult
  static func createEvent(for day: GiftDay, deps: AppDependencies) -> Bool {
    let event = GiftCalendar.event(for: day, name: eventName(for: day, deps.environment))
    return PlanningActions(deps).save(event)
  }

  /// Whether a live event of the birthday's name covers its day: the button «Создать событие» is
  /// not offered twice.
  static func hasEvent(for day: GiftDay, events: [Event], _ environment: AppEnvironment) -> Bool {
    let name = eventName(for: day, environment)
    return events.contains { event in
      !event.archived && event.startDate <= day.date && day.date <= event.endDate
        && event.name.compare(name, options: [.caseInsensitive]) == .orderedSame
    }
  }
}
