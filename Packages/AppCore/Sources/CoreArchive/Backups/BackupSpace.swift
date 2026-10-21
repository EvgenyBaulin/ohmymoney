import Foundation

/// Free space on the disk the copies lie on, and what «Освободить место» may remove.
///
/// Nothing here deletes: the plan is computed once, shown, and removed only after the owner
/// agrees — exactly the list that was shown.
public enum BackupSpace {
  /// The warning appears when less than this is free — a gigabyte as Finder counts it.
  public static let lowThresholdBytes: Int64 = 1_000_000_000

  /// Free space below the threshold. Exactly the threshold is enough.
  public static func isLow(freeBytes: Int64) -> Bool {
    freeBytes < lowThresholdBytes
  }

  /// What the button would remove, in the order it would.
  public struct Plan: Equatable, Sendable {
    public var removals: [BackupEntry]
    public var bytes: Int64 { removals.reduce(0) { $0 + $1.bytes } }
    /// The free space would still be under the threshold after the removals.
    public var staysLow: Bool
    public var isEmpty: Bool { removals.isEmpty }

    public init(removals: [BackupEntry], staysLow: Bool) {
      self.removals = removals
      self.staysLow = staysLow
    }
  }

  /// The oldest copies «after a change» first, then the daily copies older than a year, oldest
  /// first — only as many as are needed to bring the free space up to the threshold. A copy
  /// written before an update, before a restore or before an import is never on the list; nor is
  /// the newest copy, one that did not pass its check, or one with an unverified copy newer.
  public static func freeUp(
    entries: [BackupEntry], freeBytes: Int64, now: Date, calendar: Calendar = .current
  ) -> Plan {
    guard isLow(freeBytes: freeBytes) else { return Plan(removals: [], staysLow: false) }
    let newestFirst = entries.sorted(by: BackupThinning.newer)
    var blocked = Set<String>()
    var sawUnverified = false
    for entry in newestFirst {
      if sawUnverified { blocked.insert(entry.id) }
      if !entry.isVerified { sawUnverified = true }
    }
    let newest = newestFirst.first?.id
    let today = calendar.startOfDay(for: now)
    func allowed(_ entry: BackupEntry) -> Bool {
      entry.isVerified && !blocked.contains(entry.id) && entry.id != newest
    }
    let changes = newestFirst.reversed().filter { $0.kind == .change && allowed($0) }
    let oldDailies = newestFirst.reversed().filter { entry in
      guard entry.kind == .daily, allowed(entry) else { return false }
      let age =
        calendar.dateComponents([.day], from: calendar.startOfDay(for: entry.moment), to: today)
        .day ?? 0
      return age > BackupThinning.weeklyDays
    }
    var removals: [BackupEntry] = []
    var freed: Int64 = 0
    for entry in changes + oldDailies {
      if freeBytes + freed >= lowThresholdBytes { break }
      removals.append(entry)
      freed += entry.bytes
    }
    return Plan(removals: removals, staysLow: freeBytes + freed < lowThresholdBytes)
  }

  /// «Удалить старше года» for the copies written before updates: the ones older than a year,
  /// the newest of them left alone.
  public static func beforeUpdateOlderThanAYear(
    entries: [BackupEntry], now: Date, calendar: Calendar = .current
  ) -> [BackupEntry] {
    let updates = entries.filter { $0.kind == .beforeUpdate }.sorted(by: BackupThinning.newer)
    let today = calendar.startOfDay(for: now)
    return updates.dropFirst().filter { entry in
      let age =
        calendar.dateComponents([.day], from: calendar.startOfDay(for: entry.moment), to: today)
        .day ?? 0
      return age > BackupThinning.weeklyDays
    }.reversed()
  }

  /// The next 03:00 local time after `moment`: when a running app takes the copy of the new day.
  public static func nextDailyRun(after moment: Date, calendar: Calendar = .current) -> Date {
    let next = calendar.nextDate(
      after: moment, matching: DateComponents(hour: 3, minute: 0, second: 0),
      matchingPolicy: .nextTime)
    return next ?? moment.addingTimeInterval(24 * 3600)
  }
}
