import CoreAccounting
import CoreKit
import Foundation

/// The operations the owner marked as one-off («Разовое»). The calculations that average —
/// the usual day, the per-day comparison, the leaks — leave them out; the totals of a month, the
/// limits and the comparison of totals keep them. Where the mark is stored is not this type's
/// business: the app hands in the ids, or a rule that says whether an id is marked.
public struct OneOffMarks: Sendable {
  private let test: @Sendable (UUID) -> Bool

  /// Nothing is marked.
  public static let none = OneOffMarks { _ in false }

  public init(_ test: @escaping @Sendable (UUID) -> Bool) { self.test = test }

  public init(ids: Set<UUID>) { self.test = { ids.contains($0) } }

  public func contains(_ transactionId: UUID) -> Bool { test(transactionId) }
}

/// What every calculation of «Разбор трат» counts as spending: my expenses by the ledger's
/// rule (a part for somebody else once written off, refunds taken off), without the difference
/// of a reconciliation, which is no purchase.
enum SpendingRows {
  static func countsAsSpending(_ row: LedgerRow, countCategories: Set<UUID>) -> Bool {
    !row.contribution.isZero
      && !OverviewSummary.isCountDifference(row, countCategories: countCategories)
  }

  /// The rows of the days of `range` that count as spending, in ledger order.
  static func rows(in range: DayRange, of ledger: Ledger) -> [LedgerRow] {
    let counts = ledger.dataset.planning.settings.limitlessCategoryIds
    return ledger.rows(in: range).filter { countsAsSpending($0, countCategories: counts) }
  }
}

/// A result kept until the data changes. The key says what was asked (period, dimension,
/// marks); the dataset version says which data it was asked of: a result computed for one
/// version is never shown for another. Screens compute on demand, off the main thread, and keep
/// the result here.
public final class AnalysisCache<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var version: Int?
  private var values: [String: Value] = [:]

  public init() {}

  public func value(
    for key: String, datasetVersion: Int, compute: () -> Value
  ) -> Value {
    lock.lock()
    if version != datasetVersion {
      values.removeAll()
      version = datasetVersion
    }
    if let cached = values[key] {
      lock.unlock()
      return cached
    }
    lock.unlock()
    let fresh = compute()
    lock.lock()
    if version == datasetVersion { values[key] = fresh }
    lock.unlock()
    return fresh
  }

  public var count: Int {
    lock.lock()
    defer { lock.unlock() }
    return values.count
  }
}

// MARK: - The clock of an operation

/// What an operation's moment says on the clock of the zone it was recorded in.
struct ClockReading: Hashable {
  /// The day on that clock.
  var day: DateOnly
  /// 1 = Monday … 7 = Sunday.
  var weekday: Int
  /// 0…1439.
  var minuteOfDay: Int
  /// An operation typed without a time carries the app's noon of its day
  /// (`CalendarContext.noon(of:)`): it says nothing about the hour, and is never read as 12:00.
  var hasTime: Bool
  var hour: Int { minuteOfDay / 60 }
}

/// Reads the day, the weekday and the hour of an operation in the zone it was recorded in
/// (`Transaction.timeZoneId`, set when the operation is written). An operation recorded
/// without a zone — every operation of the earlier versions — is read in `unrecordedZone`:
/// Moscow unless the owner changes it; the app may pass the zone of the Mac instead.
public struct OperationClock: Sendable {
  public var unrecordedZone: TimeZone

  public init(unrecordedZone: TimeZone = TravelDay.moscowZone) {
    self.unrecordedZone = unrecordedZone
  }

  /// A reader that keeps the zones it has met, for a pass over many operations.
  struct Reader {
    let clock: OperationClock
    private var zones: [String: TimeZone] = [:]

    init(_ clock: OperationClock) { self.clock = clock }

    mutating func reading(of instant: Date, zoneId: String?) -> ClockReading {
      let zone: TimeZone
      if let zoneId {
        if let known = zones[zoneId] {
          zone = known
        } else if let made = TimeZone(identifier: zoneId) {
          zones[zoneId] = made
          zone = made
        } else {
          zone = clock.unrecordedZone
        }
      } else {
        zone = clock.unrecordedZone
      }
      let utc = Int(instant.timeIntervalSince1970.rounded(.down))
      let local = utc + zone.secondsFromGMT(for: instant)
      let days = local >= 0 ? local / 86_400 : -((-local + 86_399) / 86_400)
      let seconds = local - days * 86_400
      let day = DateOnly(dayNumber: days)
      return ClockReading(
        day: day, weekday: day.weekday, minuteOfDay: seconds / 60,
        hasTime: seconds != 12 * 3_600)
    }
  }
}

// MARK: - The weekend

/// When the weekend is: from a weekday and a time to a weekday and a time, the end included.
/// 1 = Monday … 7 = Sunday. The default is Friday 18:00 through Sunday 23:59; a window may run
/// over the end of the week (Thursday 20:00 through Monday 06:00).
public struct WeekendWindow: Hashable, Sendable {
  public static let settingsKey = "analytics.weekend"

  public var startWeekday: Int
  public var start: TimeOfDay
  public var endWeekday: Int
  public var end: TimeOfDay

  public static let standard = WeekendWindow(
    startWeekday: 5, start: TimeOfDay(hour: 18, minute: 0),
    endWeekday: 7, end: TimeOfDay(hour: 23, minute: 59))

  public init(startWeekday: Int, start: TimeOfDay, endWeekday: Int, end: TimeOfDay) {
    self.startWeekday = min(max(startWeekday, 1), 7)
    self.start = start
    self.endWeekday = min(max(endWeekday, 1), 7)
    self.end = end
  }

  private static let day = 1_440
  private var startMinute: Int { (startWeekday - 1) * Self.day + start.hour * 60 + start.minute }
  private var endMinute: Int { (endWeekday - 1) * Self.day + end.hour * 60 + end.minute }

  /// Whether the minute of that weekday is inside the weekend.
  public func contains(weekday: Int, minuteOfDay: Int) -> Bool {
    let t = (weekday - 1) * Self.day + minuteOfDay
    return startMinute <= endMinute
      ? (startMinute...endMinute).contains(t) : (t >= startMinute || t <= endMinute)
  }

  /// Whether all of that weekday, midnight to midnight, is inside the weekend. An operation
  /// without a time knows only its day: it is weekend when the whole day is, never when the
  /// weekend only begins or ends in it — the day is not guessed.
  public func coversWholeDay(weekday: Int) -> Bool {
    let first = (weekday - 1) * Self.day
    let last = first + Self.day - 1
    return startMinute <= endMinute
      ? (startMinute <= first && last <= endMinute) : (startMinute <= first || last <= endMinute)
  }

  /// How the window is kept in the settings: `5@18:00-7@23:59`.
  public var storedValue: String {
    func clock(_ time: TimeOfDay) -> String { String(format: "%02d:%02d", time.hour, time.minute) }
    return "\(startWeekday)@\(clock(start))-\(endWeekday)@\(clock(end))"
  }

  public init?(storedValue: String) {
    let halves = storedValue.split(separator: "-")
    guard halves.count == 2 else { return nil }
    func side(_ text: Substring) -> (Int, TimeOfDay)? {
      let parts = text.split(separator: "@")
      guard parts.count == 2, let weekday = Int(parts[0]), (1...7).contains(weekday) else {
        return nil
      }
      let clock = parts[1].split(separator: ":")
      guard clock.count == 2, let hour = Int(clock[0]), let minute = Int(clock[1]),
        (0...23).contains(hour), (0...59).contains(minute)
      else { return nil }
      return (weekday, TimeOfDay(hour: hour, minute: minute))
    }
    guard let from = side(halves[0]), let to = side(halves[1]) else { return nil }
    self.init(startWeekday: from.0, start: from.1, endWeekday: to.0, end: to.1)
  }

  /// Whether an operation read on its clock falls in the weekend.
  func isWeekend(_ reading: ClockReading) -> Bool {
    reading.hasTime
      ? contains(weekday: reading.weekday, minuteOfDay: reading.minuteOfDay)
      : coversWholeDay(weekday: reading.weekday)
  }
}
