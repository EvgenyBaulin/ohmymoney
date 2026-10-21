import CoreKit
import Foundation

/// Formats `CoreKit` value types into the plain strings a CSV export writes: decimal
/// amounts with a dot, ISO 8601 dates and instants, `true`/`false` booleans, and an empty
/// string — never the word "null" — for anything absent. No function here ever produces
/// or accepts a floating-point number: money and rates stay exact `Decimal` values all
/// the way to the file.
public enum CSVValue {
  /// The empty CSV field: how every absent value is written.
  public static let empty = ""

  // MARK: - Amounts

  /// A money amount as a decimal string with a dot, no thousands separator and no
  /// exponent: "1234.5678", "-3.5", "0".
  public static func string(amount value: AmountE4) -> String {
    string(decimal: value.decimal)
  }

  public static func string(amount value: AmountE4?) -> String {
    value.map { string(amount: $0) } ?? empty
  }

  /// Same rendering as `string(amount:)`, for bare decimals such as exchange rates and
  /// interest rates. `NSDecimalNumber.stringValue` always renders in plain notation.
  public static func string(decimal value: Decimal) -> String {
    NSDecimalNumber(decimal: value).stringValue
  }

  public static func string(decimal value: Decimal?) -> String {
    value.map { string(decimal: $0) } ?? empty
  }

  // MARK: - Dates

  /// A calendar day as `2026-09-17`.
  public static func string(day value: DateOnly) -> String { value.iso }

  public static func string(day value: DateOnly?) -> String {
    value.map { string(day: $0) } ?? empty
  }

  /// A calendar month as `2026-09`.
  public static func string(month value: MonthKey) -> String { value.iso }

  public static func string(month value: MonthKey?) -> String {
    value.map { string(month: $0) } ?? empty
  }

  /// An instant in time as `2026-09-17T14:03:00Z`, always UTC, one-second precision.
  public static func string(instant value: Date) -> String {
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(secondsFromGMT: 0)!
    let parts = utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: value)
    return String(
      format: "%04d-%02d-%02dT%02d:%02d:%02dZ",
      parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1,
      parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
  }

  public static func string(instant value: Date?) -> String {
    value.map { string(instant: $0) } ?? empty
  }

  /// The instant `string(instant:)` wrote — `2026-09-17T14:03:00Z` — read back; `nil` for
  /// anything else.
  public static func instant(_ text: String) -> Date? {
    let characters = Array(text)
    guard characters.count == 20, characters[4] == "-", characters[7] == "-",
      characters[10] == "T", characters[13] == ":", characters[16] == ":", characters[19] == "Z"
    else { return nil }
    func number(_ range: Range<Int>) -> Int? { Int(String(characters[range])) }
    guard let year = number(0..<4), let month = number(5..<7), let day = number(8..<10),
      let hour = number(11..<13), let minute = number(14..<16), let second = number(17..<19),
      (1...12).contains(month), (1...31).contains(day), (0...23).contains(hour),
      (0...59).contains(minute), (0...60).contains(second)
    else { return nil }
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(secondsFromGMT: 0)!
    return utc.date(
      from: DateComponents(
        year: year, month: month, day: day, hour: hour, minute: minute, second: second))
  }

  // MARK: - Booleans

  /// `true` or `false` — never `1`/`0`, which `pandas.read_csv` would read back as a
  /// number instead of a boolean.
  public static func string(bool value: Bool) -> String { value ? "true" : "false" }

  /// `true`, `false`, or the empty field when there is no value to say.
  public static func string(bool value: Bool?) -> String {
    value.map { string(bool: $0) } ?? empty
  }

  // MARK: - Plain values

  public static func string(_ value: String?) -> String { value ?? empty }
  public static func string(_ value: UUID?) -> String { value.map(\.uuidString) ?? empty }
  public static func string(_ value: Int?) -> String { value.map(String.init) ?? empty }

  /// Joins a list of strings the way the SQL schema stores it — newline separated — so a
  /// CSV cell round-trips through `CSVWriter`'s quoting without losing an entry.
  public static func string(joining values: [String]) -> String { values.joined(separator: "\n") }
}
