import CoreKit
import Foundation

/// A day the key rate of the Bank of Russia changed, and the rate from that day, in percent:
/// 16 is 16 %. Rates are `Decimal`, read from text without binary floating point.
public struct KeyRateChange: Codable, Hashable, Sendable {
  public var effectiveOn: DateOnly
  public var ratePercent: Decimal

  public init(effectiveOn: DateOnly, ratePercent: Decimal) {
    self.effectiveOn = effectiveOn
    self.ratePercent = ratePercent
  }
}

/// One point of the step line the chart draws: the rate in 1/10000 of a percent (160 000 is
/// 16 %), so the chart takes whole numbers and counts nothing.
public struct KeyRatePoint: Hashable, Sendable, Identifiable {
  public var day: DateOnly
  public var rateE4: Int64
  public var id: String { "\(day.iso):\(rateE4)" }

  public init(day: DateOnly, rateE4: Int64) {
    self.day = day
    self.rateE4 = rateE4
  }
}

/// How far the rate fell between two days.
public struct KeyRateDrop: Hashable, Sendable {
  public var from: Decimal
  public var to: Decimal
  public var since: DateOnly
  /// Percentage points, positive for a fall.
  public var points: Decimal { from - to }

  public init(from: Decimal, to: Decimal, since: DateOnly) {
    self.from = from
    self.to = to
    self.since = since
  }
}

/// The key rate over time: one row for each day it changed, oldest first. The app carries a
/// table (`builtIn`, renewed with each release); with the open sources on, the rows read from the
/// page of the Bank of Russia are merged over it, and a row of the page wins for its day.
public struct KeyRateTable: Hashable, Sendable {
  /// Oldest first, one row a day, and never two rows in a row with the same rate.
  public let changes: [KeyRateChange]

  public init(changes: [KeyRateChange]) {
    var byDay: [DateOnly: KeyRateChange] = [:]
    for change in changes { byDay[change.effectiveOn] = change }
    var kept: [KeyRateChange] = []
    for change in byDay.values.sorted(by: { $0.effectiveOn < $1.effectiveOn }) {
      if kept.last?.ratePercent == change.ratePercent { continue }
      kept.append(change)
    }
    self.changes = kept
  }

  /// What the app carries. Checked against the Bank of Russia's decisions up to 19.12.2025
  /// (16 %); a later decision is known only from the page, when the owner reads it.
  public static let builtIn = KeyRateTable(
    changes: [
      (2023, 12, 18, "16"), (2024, 7, 26, "18"), (2024, 9, 13, "19"), (2024, 10, 25, "21"),
      (2025, 6, 6, "20"), (2025, 7, 25, "18"), (2025, 9, 12, "17"), (2025, 10, 24, "16.5"),
      (2025, 12, 19, "16"),
    ].compactMap { row in
      Decimal(string: row.3, locale: Locale(identifier: "en_US_POSIX")).map {
        KeyRateChange(
          effectiveOn: DateOnly(year: row.0, month: row.1, day: row.2), ratePercent: $0)
      }
    })

  /// The newest row.
  public var latest: KeyRateChange? { changes.last }

  /// The rate in force on `day`; `nil` before the first row.
  public func rate(on day: DateOnly) -> Decimal? { row(on: day)?.ratePercent }

  private func row(on day: DateOnly) -> KeyRateChange? {
    changes.last { $0.effectiveOn <= day }
  }

  /// This table with `fetched` rows laid over it.
  public func merged(with fetched: [KeyRateChange]) -> KeyRateTable {
    KeyRateTable(changes: changes + fetched)
  }

  /// The fall of the rate over the `days` before `day`, `nil` when the rate did not fall or the
  /// table does not reach back that far.
  public func drop(overDays days: Int, to day: DateOnly) -> KeyRateDrop? {
    let before = day.adding(days: -days)
    guard let then = row(on: before), let now = row(on: day), now.ratePercent < then.ratePercent
    else { return nil }
    let since = changes.first { $0.effectiveOn > before && $0.effectiveOn <= day }?.effectiveOn
    return KeyRateDrop(
      from: then.ratePercent, to: now.ratePercent, since: since ?? day)
  }

  /// The step line from `start` through `end`: the rate in force at the start, a point on each
  /// day it changed, and the last point at `end` with the rate then. A rate never moves between
  /// two decisions, so the chart draws steps, not slopes.
  public func points(from start: DateOnly, through end: DateOnly) -> [KeyRatePoint] {
    guard start <= end, let first = rate(on: start) else { return [] }
    var result = [KeyRatePoint(day: start, rateE4: Self.e4(first))]
    for change in changes where change.effectiveOn > start && change.effectiveOn <= end {
      // The old rate up to the day before, then the new one: a step.
      if let previous = result.last {
        result.append(
          KeyRatePoint(day: change.effectiveOn, rateE4: previous.rateE4))
      }
      result.append(KeyRatePoint(day: change.effectiveOn, rateE4: Self.e4(change.ratePercent)))
    }
    if let last = result.last, last.day < end {
      result.append(KeyRatePoint(day: end, rateE4: last.rateE4))
    }
    return result
  }

  static func e4(_ percent: Decimal) -> Int64 {
    var scaled = percent * 10_000
    var rounded = Decimal()
    NSDecimalRound(&rounded, &scaled, 0, .plain)
    return Int64(truncating: NSDecimalNumber(decimal: rounded))
  }
}
