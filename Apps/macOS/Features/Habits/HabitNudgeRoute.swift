import AppCore
import Foundation

/// Whatever can deliver the reminder of the evening, «Запишите траты за день», as a notification
/// of the Mac. The notifications of the app plug in here: they set `HabitNudgeRoute.deliverer`
/// once at launch, and from then on the reminder is theirs.
///
/// The contract:
/// * `schedule(_:)` is called after every recount with the reminder due today, or `nil` when
///   none is due (today has an entry, or nothing was ever typed, or the evening is switched off);
///   `nil` takes back a reminder scheduled before. The same reminder comes again and again — it
///   is keyed by its day (`HabitNudge.id`), so scheduling it twice must not show it twice.
/// * It returns whether the reminder will be delivered: `false` — no permission, notifications
///   off — and «Стоит посмотреть» says it in the line of the evening instead.
@MainActor
protocol HabitNudgeDelivering: AnyObject {
  func schedule(_ nudge: HabitNudge?) -> Bool
}

/// The point the reminder of the evening goes through. Until something delivers notifications,
/// nothing is set, and the reminder is a line of «Стоит посмотреть» — the question of the evening
/// says «Запишите траты за день — или сегодня трат не было?».
@MainActor
enum HabitNudgeRoute {
  /// The deliverer of notifications, when the app has one.
  static weak var deliverer: (any HabitNudgeDelivering)?
  /// The last answer of the deliverer: the reminder goes as a notification.
  private(set) static var delivers = false

  /// The reminder last routed, for a deliverer whose settings changed.
  private(set) static var lastAsked: HabitNudge?

  /// Hands the reminder due now to the deliverer; without one, the line of the evening carries it.
  static func route(_ nudge: HabitNudge?) {
    lastAsked = nudge
    guard let deliverer else {
      delivers = false
      return
    }
    delivers = deliverer.schedule(nudge)
  }

  /// The reminder due for the data of a snapshot, as this Mac sets the evening; `nil` when the
  /// evening is switched off.
  static func nudge(for snapshot: DataSnapshot, defaults: UserDefaults = .standard) -> HabitNudge? {
    guard HabitNotesOnMac.eveningEnabled(defaults) else { return nil }
    return HabitNotes.nudge(
      entryDays: HabitNotesOnMac.entryDays(snapshot), today: snapshot.today,
      hour: HabitNotesOnMac.eveningHour(defaults), calendar: snapshot.ledger.calendar)
  }
}
