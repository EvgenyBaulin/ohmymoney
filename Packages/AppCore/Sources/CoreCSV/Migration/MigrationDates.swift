import CoreKit
import Foundation

/// Reads the dates other applications write: `2023-05-01`, `2023-05-01 14:05:00`,
/// `2023-05-01T14:05:00Z`, `01.05.2023`, `01.05.23 14:05`, `1/5/2023 2:05 PM`. A date
/// written day and month with slashes or dashes is ambiguous; the order is decided for the whole
/// column at once (`order(for:)`), never line by line, so 03/04 and 13/04 do not end up in
/// different months.
public enum MigrationDates {
  public enum Order: String, Sendable, Codable, Hashable {
    case dayFirst
    case monthFirst
  }

  /// The order the values of a column agree on: a first number above 12 means day first, a
  /// second one above 12 month first; with no telling value, day first (as Russian files are).
  public static func order(for values: [String]) -> Order {
    var dayFirst = 0
    var monthFirst = 0
    for value in values {
      let numbers = leadingNumbers(value)
      guard numbers.count >= 3, numbers[0].count <= 2 else { continue }
      if let first = Int(numbers[0]), let second = Int(numbers[1]) {
        if first > 12, second <= 12 { dayFirst += 1 }
        if second > 12, first <= 12 { monthFirst += 1 }
      }
    }
    return monthFirst > dayFirst ? .monthFirst : .dayFirst
  }

  public static func parse(_ raw: String, order: Order) -> StatementMoment? {
    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, text.count <= 40 else { return nil }
    let numbers = leadingNumbers(text)
    guard numbers.count >= 3 else { return nil }
    // Letters other than a time marker or the `T` and `Z` of ISO make it not a date.
    let lower = text.lowercased()
    for scalar in lower.unicodeScalars where CharacterSet.letters.contains(scalar) {
      guard "tzapm".unicodeScalars.contains(scalar) else { return nil }
    }
    var year: Int
    var month: Int
    var day: Int
    if numbers[0].count == 4 {
      guard let y = Int(numbers[0]), let m = Int(numbers[1]), let d = Int(numbers[2]) else {
        return nil
      }
      (year, month, day) = (y, m, d)
    } else {
      guard numbers[0].count <= 2, numbers[1].count <= 2,
        numbers[2].count == 4 || numbers[2].count == 2,
        let a = Int(numbers[0]), let b = Int(numbers[1]), let y = Int(numbers[2])
      else { return nil }
      year = numbers[2].count == 2 ? 2000 + y : y
      // Dots are always day first; slashes and dashes follow the column.
      let dotted = text.contains(".")
      (day, month) = dotted || order == .dayFirst ? (a, b) : (b, a)
    }
    let date = DateOnly(year: year, month: month, day: day)
    guard StatementCivil.isValid(date) else { return nil }
    var minute: Int?
    if numbers.count >= 5, let hour = Int(numbers[3]), let minutes = Int(numbers[4]),
      (0..<24).contains(hour), (0..<60).contains(minutes)
    {
      var h = hour
      if lower.contains("pm"), h < 12 { h += 12 }
      if lower.contains("am"), h == 12 { h = 0 }
      minute = h * 60 + minutes
    }
    return StatementMoment(day: date, minuteOfDay: minute)
  }

  /// The runs of digits of the text, in order: `01.05.2023 14:05` → 01, 05, 2023, 14, 05.
  static func leadingNumbers(_ text: String) -> [String] {
    var result: [String] = []
    var current = ""
    for character in text {
      if character.isASCII, character.isNumber {
        current.append(character)
      } else if !current.isEmpty {
        result.append(current)
        current = ""
      }
    }
    if !current.isEmpty { result.append(current) }
    return result
  }
}
