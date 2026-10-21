import Foundation

/// A calendar day without a time zone attached. Day and month boundaries are resolved
/// by `CalendarContext`, which carries the time zone explicitly — the core never reads
/// the system time zone on its own.
public struct DateOnly: Hashable, Sendable, Codable, Comparable, CustomStringConvertible {
  public let year: Int
  public let month: Int
  public let day: Int

  public init(year: Int, month: Int, day: Int) {
    self.year = year
    self.month = month
    self.day = day
  }

  /// Parses an ISO 8601 calendar date (`2026-09-17`).
  public init?(iso: String) {
    let parts = iso.split(separator: "-")
    guard parts.count == 3,
      let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
      (1...12).contains(month), (1...31).contains(day)
    else { return nil }
    self.init(year: year, month: month, day: day)
  }

  public var iso: String {
    String(format: "%04d-%02d-%02d", year, month, day)
  }

  public var description: String { iso }

  public var monthKey: MonthKey { MonthKey(year: year, month: month) }

  public static func < (lhs: DateOnly, rhs: DateOnly) -> Bool {
    (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    guard let parsed = DateOnly(iso: try container.decode(String.self)) else {
      throw CoreError.invalidDate
    }
    self = parsed
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(iso)
  }
}

/// A calendar month. Months always start on the 1st.
public struct MonthKey: Hashable, Sendable, Codable, Comparable, CustomStringConvertible {
  public let year: Int
  public let month: Int

  public init(year: Int, month: Int) {
    self.year = year
    self.month = month
  }

  public init?(iso: String) {
    let parts = iso.split(separator: "-")
    guard parts.count >= 2, let year = Int(parts[0]), let month = Int(parts[1]),
      (1...12).contains(month)
    else { return nil }
    self.init(year: year, month: month)
  }

  public var iso: String { String(format: "%04d-%02d", year, month) }
  public var description: String { iso }
  public var firstDay: DateOnly { DateOnly(year: year, month: month, day: 1) }

  public var previous: MonthKey {
    month == 1 ? MonthKey(year: year - 1, month: 12) : MonthKey(year: year, month: month - 1)
  }

  public var next: MonthKey {
    month == 12 ? MonthKey(year: year + 1, month: 1) : MonthKey(year: year, month: month + 1)
  }

  public static func < (lhs: MonthKey, rhs: MonthKey) -> Bool {
    (lhs.year, lhs.month) < (rhs.year, rhs.month)
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    guard let parsed = MonthKey(iso: try container.decode(String.self)) else {
      throw CoreError.invalidDate
    }
    self = parsed
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(iso)
  }
}
