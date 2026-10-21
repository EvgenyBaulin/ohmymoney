import Foundation
import GRDB

/// How the app writes an instant and reads one back: UTC text `YYYY-MM-DD HH:MM:SS.SSS`, the
/// format of every build so far and of the schema's contract, to the millisecond.
///
/// An instant is written as the last millisecond that reads back no later than it — never
/// rounded up. GRDB's own writer rounds, so a moment in the second half of a millisecond was
/// kept up to half a millisecond later than it happened, and a balance worked out at that
/// moment — right after an operation, a transfer or a count was written with the same «now» —
/// did not see it yet. With every stored moment read back at or before the moment it was
/// written for, whatever happened by an instant is in what is read as of that instant, for any
/// clock and any number of writes and reads sharing one «now».
///
/// «Reads back no later» is taken to the bit: a `Date` holds today's moments to about a tenth
/// of a microsecond, and one that lies a hair below a whole millisecond — seconds since 1970
/// plus a number of milliseconds, say — is written as the millisecond before, not the one it
/// looks like. Moments the app makes itself are whole seconds, the last millisecond of a day,
/// or a moment of the clock, and all keep their millisecond.
///
/// A text reads as exactly the instant a write of the millisecond it names starts from, so a
/// value already stored — rounded by an older build or cut by this one — is written back to the
/// very same text when its row is saved again. Nothing stored is ever rewritten on its own.
///
/// Query bounds go through the same rule, so the database compares moments to the millisecond
/// on both sides: a bound inside a millisecond takes in the whole millisecond it is in.
enum StoredInstant {
  /// The text of the millisecond `date` is written as (`millisecond(of:)`); NULL for `nil`.
  static func databaseValue(_ date: Date?) -> DatabaseValue {
    guard let date else { return .null }
    guard let millisecond = millisecond(of: date) else { return date.databaseValue }
    // The instant of a whole millisecond lies within a hair of it, so GRDB's formatter, which
    // rounds, names exactly that millisecond — in the calendar GRDB reads it back with.
    return instant(ofMillisecond: millisecond).databaseValue
  }

  /// The instant `value` holds, or `nil` for NULL and for a value that is no instant. A text
  /// names a millisecond at most — GRDB reads no finer — and reads as exactly
  /// `instant(ofMillisecond:)` of it; a number of seconds keeps its fraction.
  static func date(from value: DatabaseValue) -> Date? {
    guard let date = Date.fromDatabaseValue(value) else { return nil }
    guard case .string = value.storage, let (second, fraction) = split(date) else { return date }
    return instant(ofMillisecond: second * 1000 + Int64((fraction * 1000).rounded()))
  }

  /// The millisecond since the reference date that `date` is written as: the last one whose
  /// instant is not after `date`. `nil` for a moment no count of milliseconds holds.
  static func millisecond(of date: Date) -> Int64? {
    guard let (second, fraction) = split(date) else { return nil }
    // The fraction is exact, its thousandfold within a hair of it: the millisecond found is the
    // right one or its neighbour, and a step settles which.
    var millisecond = second * 1000 + Int64((fraction * 1000).rounded(.down))
    while instant(ofMillisecond: millisecond + 1) <= date { millisecond += 1 }
    while instant(ofMillisecond: millisecond) > date { millisecond -= 1 }
    return millisecond
  }

  /// The instant a whole millisecond since the reference date stands for.
  static func instant(ofMillisecond millisecond: Int64) -> Date {
    Date(timeIntervalSinceReferenceDate: Double(millisecond) / 1000)
  }

  /// The whole seconds since the reference date, rounded down, and the fraction left over,
  /// from 0 up to 1. Split first, so the fraction is exact. `nil` for a moment more than ten
  /// thousand years from 2001, where GRDB writes no calendar date anyway; within them a `Date`
  /// tells every millisecond from the next.
  private static func split(_ date: Date) -> (Int64, Double)? {
    let interval = date.timeIntervalSinceReferenceDate
    let second = interval.rounded(.down)
    guard second.isFinite, abs(second) < 3.2e11 else { return nil }
    return (Int64(second), interval - second)
  }
}
