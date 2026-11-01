import AppCore
import AppDatabase
import Foundation

/// After every recount: the badges the history earned and the database does not hold yet are
/// written, and the reminder of the evening goes to whatever delivers it. Writing is kept out of
/// the recount itself: the snapshot is built from data and never writes. A badge is written once
/// — nothing at all is written when nothing is new, so the write that follows a badge does not
/// start an endless chain of recounts — and never taken back.
@MainActor
enum HabitAwards {
  /// The badges `snapshot` earns that its data does not hold yet.
  static func new(in snapshot: DataSnapshot, now: Date = Date()) -> [HabitBadge] {
    let dataset = snapshot.ledger.dataset
    let earned = HabitBadges.earned(
      entryDays: HabitNotesOnMac.entryDays(snapshot),
      reconciliations: dataset.planning.reconciliations, today: snapshot.today, at: now)
    return HabitBadges.new(earned, stored: dataset.habits.badges)
  }

  /// Writes the new badges and routes the reminder. A set of synthetic data earns its own badges in
  /// its own database, as every write of it does.
  static func check(_ snapshot: DataSnapshot?, environment: AppEnvironment) {
    guard let snapshot, environment.state == .ready else { return }
    HabitNudgeRoute.route(HabitNudgeRoute.nudge(for: snapshot))
    let fresh = new(in: snapshot)
    guard !fresh.isEmpty, let habits = environment.habits else { return }
    do {
      let written = try habits.award(fresh)
      if written > 0 {
        AppLog.info(
          "habits.badges", .db, "badges were earned", [LogPair("count", .count(written))])
      }
    } catch {
      AppLog.error(
        "habits.badgesFailed", .db, "badges could not be written",
        [LogPair("error", .error(error))])
    }
  }
}
