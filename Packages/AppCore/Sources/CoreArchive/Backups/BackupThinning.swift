import Foundation

/// One copy of the database as the rules of keeping and freeing space see it: when it was taken,
/// why, whether it passed its check and how much it takes on disk (the file and the folder of
/// readable files beside it). The app builds these from the names of its copies; the rules
/// themselves know nothing of files.
public struct BackupEntry: Hashable, Sendable, Identifiable {
  public enum Kind: Hashable, Sendable {
    /// Taken after a change of the data.
    case change
    /// The copy of the day, with a readable folder beside it.
    case daily
    /// Written before the schema was migrated: never thinned, never deleted by itself.
    case beforeUpdate
    case beforeRestore
    case beforeImport
    /// Taken before the repair of the database removed orphan rows.
    case beforeRepair
  }

  public var id: String
  public var moment: Date
  public var kind: Kind
  /// Passed its check after it was written. A copy that failed it is marked and is not counted.
  public var isVerified: Bool
  public var bytes: Int64

  public init(id: String, moment: Date, kind: Kind, isVerified: Bool = true, bytes: Int64 = 0) {
    self.id = id
    self.moment = moment
    self.kind = kind
    self.isVerified = isVerified
    self.bytes = bytes
  }
}

/// How many copies are kept as time passes: today every copy; the last week one a day; up to a
/// year one a week; older one a month. Of the copies of a day, week or month the latest stays.
///
/// The copies of the day (`.daily`) are thinned among themselves, on a track of their own, and
/// the others (after a change, before a restore, an import or a repair) among themselves: a copy
/// after a change made in the evening must not take the place of the copy of the day, which is
/// the one with a readable version beside it and the one that reaches the chosen folder.
///
/// Three things are never deleted: a copy written before an update, a copy that did not pass its
/// check, and any copy while a newer one has not been verified — the older one may be the last
/// good state. The newest copy always stays, since nothing newer stands in its bucket.
public enum BackupThinning {
  /// The days after today that are kept one a day.
  public static let dailyDays = 7
  /// The days after which copies are kept one a month rather than one a week.
  public static let weeklyDays = 365

  /// The copies the rule would delete now, oldest first.
  public static func deletions(
    of entries: [BackupEntry], now: Date, calendar: Calendar = .current
  ) -> [BackupEntry] {
    let newestFirst = entries.sorted(by: newer)
    // A copy may go only when every copy newer than it is verified.
    var blocked = Set<String>()
    var sawUnverified = false
    for entry in newestFirst {
      if sawUnverified { blocked.insert(entry.id) }
      if !entry.isVerified { sawUnverified = true }
    }
    let today = calendar.startOfDay(for: now)
    var seen = Set<Slot>()
    var doomed: [BackupEntry] = []
    for entry in newestFirst
    where entry.kind != .beforeUpdate && entry.isVerified {
      guard let bucket = bucket(of: entry.moment, today: today, calendar: calendar) else {
        continue
      }
      if seen.insert(Slot(daily: entry.kind == .daily, bucket: bucket)).inserted { continue }
      if !blocked.contains(entry.id) { doomed.append(entry) }
    }
    return doomed.reversed()
  }

  /// Newest first; of one moment, the later name.
  static func newer(_ left: BackupEntry, _ right: BackupEntry) -> Bool {
    if left.moment != right.moment { return left.moment > right.moment }
    return left.id > right.id
  }

  /// The place a copy competes for: the bucket of time, on the track of the copies of the day or
  /// of the others.
  struct Slot: Hashable {
    var daily: Bool
    var bucket: Bucket
  }

  /// The slot of time a copy falls in. Today has none: every copy of today is kept.
  enum Bucket: Hashable {
    case day(Date)
    case week(year: Int, week: Int)
    case month(year: Int, month: Int)
  }

  static func bucket(of moment: Date, today: Date, calendar: Calendar) -> Bucket? {
    let day = calendar.startOfDay(for: moment)
    let age = calendar.dateComponents([.day], from: day, to: today).day ?? 0
    if age <= 0 { return nil }
    if age <= dailyDays { return .day(day) }
    if age <= weeklyDays {
      let parts = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: day)
      return .week(year: parts.yearForWeekOfYear ?? 0, week: parts.weekOfYear ?? 0)
    }
    let parts = calendar.dateComponents([.year, .month], from: day)
    return .month(year: parts.year ?? 0, month: parts.month ?? 0)
  }
}
