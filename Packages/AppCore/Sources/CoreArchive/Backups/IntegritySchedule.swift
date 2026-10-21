import Foundation

/// When the database is checked by itself: once a week, quietly. «Проверить сейчас» is outside
/// the schedule and moves it — the next check comes a week after the last, whichever it was.
public enum IntegritySchedule {
  /// A week, in seconds.
  public static let interval: TimeInterval = 7 * 24 * 3600

  /// Whether the weekly check is due: never done, or a week or more ago. A check dated in the
  /// future (the clock was set back) is due: its date means nothing, and the check that follows
  /// is dated now.
  public static func isDue(lastCheck: Date?, now: Date) -> Bool {
    guard let lastCheck else { return true }
    if lastCheck > now { return true }
    return now.timeIntervalSince(lastCheck) >= interval
  }
}
