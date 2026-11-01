import AppCore
import AppDatabase
import Foundation

/// What this Mac keeps of the habits — the switch and the hour of the evening — and the lines of
/// «Стоит посмотреть» they give. The rest lives in the database (`HabitData`).
@MainActor
enum HabitNotesOnMac {
  /// «Вечером спрашивать о тратах за день»: on until the owner turns it off.
  static let eveningEnabledKey = "habits.evening.enabled"
  /// The hour of the evening, 0–23.
  static let eveningHourKey = "habits.evening.hour"

  static func eveningEnabled(_ defaults: UserDefaults) -> Bool {
    defaults.object(forKey: eveningEnabledKey) == nil
      ? true : defaults.bool(forKey: eveningEnabledKey)
  }

  static func eveningHour(_ defaults: UserDefaults) -> Int {
    guard defaults.object(forKey: eveningHourKey) != nil else {
      return HabitNotes.defaultEveningHour
    }
    return min(max(defaults.integer(forKey: eveningHourKey), 0), 23)
  }

  /// The days of entry of the data the snapshot was built from: the whole ledger, hidden
  /// accounts included — the streak is the owner's, not a list of accounts.
  static func entryDays(_ snapshot: DataSnapshot) -> Set<DateOnly> {
    let dataset = snapshot.ledger.dataset
    return HabitEntryDays.days(
      dataset.entries, noSpend: dataset.habits.markedDays, calendar: snapshot.ledger.calendar)
  }

  /// The lines for the card, with what this Mac remembers: the evening, the lines put away, and
  /// whether the reminder goes as a notification (`HabitNudgeRoute`) — then the question does not
  /// repeat it.
  static func notes(
    of snapshot: DataSnapshot, defaults: UserDefaults = .standard, now: Date = Date()
  ) -> [HabitNote] {
    HabitNotes.list(
      entryDays: entryDays(snapshot), settings: snapshot.ledger.dataset.habits.settings,
      today: snapshot.today, now: now, calendar: snapshot.ledger.calendar,
      eveningHour: eveningHour(defaults), eveningEnabled: eveningEnabled(defaults),
      remind: !HabitNudgeRoute.delivers,
      dismissed: DebtReminderMarks.read(from: defaults).dismissed)
  }
}

/// The writes of the habits. A day marked «трат не было» is not an operation and not a step of
/// ⌘Z: the mark is taken back the same way it was given.
@MainActor
struct HabitActions {
  let deps: AppDependencies

  init(_ deps: AppDependencies) { self.deps = deps }

  /// «Трат не было»: the day counts in the streak. Returns whether the mark is there now.
  @discardableResult
  func markNoSpend(_ day: DateOnly) -> Bool {
    guard let habits = deps.environment.habits else { return false }
    do {
      try habits.markNoSpend(day, at: Date())
      AppLog.info("habits.noSpend", .db, "a day was marked without spending", [])
      return true
    } catch {
      AppLog.error(
        "habits.noSpendFailed", .db, "a day could not be marked without spending",
        [LogPair("error", .error(error))])
      return false
    }
  }

  /// Saves the setting of the days missed.
  @discardableResult
  func save(_ settings: HabitSettings) -> Bool {
    guard let habits = deps.environment.habits else { return false }
    return (try? habits.save(settings)) != nil
  }
}
