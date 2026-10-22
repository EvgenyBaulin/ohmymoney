import CoreKit
import Foundation

/// What a description rule found: the kind of the operation and the captured fields by name.
struct StatementReading {
  var kind: StatementOperationKind
  var fields: [String: String]
}

/// A profile's description rules with their patterns compiled once per parse run. Compiled
/// expressions are never stored in a shared static: the set lives as long as one parse and
/// is not shared between threads.
struct StatementRuleSet {
  private let compiled: [(rule: StatementDescriptionRule, regex: NSRegularExpression)]

  init(_ rules: [StatementDescriptionRule]) {
    compiled = rules.compactMap { rule in
      guard let regex = try? NSRegularExpression(pattern: rule.pattern, options: [.caseInsensitive])
      else { return nil }
      return (rule, regex)
    }
  }

  /// The first rule that fits, or `nil`. `text` is already whitespace-collapsed.
  func read(_ text: String, isIncome: Bool, hasCard: Bool) -> StatementReading? {
    let whole = NSRange(text.startIndex..., in: text)
    for (rule, regex) in compiled {
      switch rule.direction {
      case .income where !isIncome: continue
      case .expense where isIncome: continue
      default: break
      }
      switch rule.card {
      case .present where !hasCard: continue
      case .absent where hasCard: continue
      default: break
      }
      guard let match = regex.firstMatch(in: text, options: [], range: whole) else { continue }
      var fields: [String: String] = [:]
      for (offset, name) in rule.groups.enumerated() where !name.isEmpty {
        let range = match.range(at: offset + 1)
        guard range.location != NSNotFound, let swiftRange = Range(range, in: text) else {
          continue
        }
        let value = StatementText.collapse(String(text[swiftRange]))
        if !value.isEmpty { fields[name] = value }
      }
      return StatementReading(kind: rule.kind, fields: fields)
    }
    return nil
  }
}

/// Cleaning of the place a purchase was made at, so the same shop compares equal across
/// statements and formats.
public enum StatementMerchant {
  private static let prefixes = ["оплата в ", "y.m*", "ym*", "cp*", "ip ", "ооо ", "ooo "]

  /// Three-letter country codes banks append to a place after the city.
  private static let countries: Set<String> = [
    "RUS", "USA", "GBR", "DEU", "FRA", "ITA", "ESP", "TUR", "ARE", "GEO", "ARM", "KAZ", "BLR",
    "THA", "CHN", "CYP", "SRB", "MNE", "EGY", "IND", "VNM", "IDN", "LKA", "UZB", "KGZ", "AZE",
    "ISR", "GRC", "CZE", "POL", "FIN", "EST", "LVA", "LTU", "NLD", "CHE", "AUT", "PRT", "HUN",
    "BGR", "MDA", "TJK", "JPN", "KOR", "MYS", "SGP", "HKG", "MEX", "BRA", "CAN", "SWE", "NOR",
  ]

  /// The two-letter forms some card lines use.
  private static let countries2: Set<String> = [
    "RU", "US", "GB", "DE", "FR", "IT", "ES", "TR", "AE", "GE", "AM", "KZ", "BY", "TH", "CN",
    "CY", "RS", "ME", "EG", "IN", "VN", "ID", "UZ", "KG", "AZ", "IL", "GR", "CZ", "PL", "FI",
    "EE", "LV", "LT", "NL", "CH", "AT", "PT", "HU", "BG", "MD", "JP", "KR",
  ]

  /// Takes off the bank's wrapping: a leading «Оплата в», the payment-service marks `Y.M*`,
  /// `YM*`, `CP*`, the legal-form prefixes `IP `, `ООО `, the point number at the end
  /// (`FUEL 12345_INT` → `FUEL`) and the city-and-country tail (`… MOSCOW RUS`). The result is
  /// for showing and comparing; it never becomes shorter than one word.
  public static func clean(_ text: String) -> String {
    var value = StatementText.collapse(text)
    var stripped = true
    while stripped {
      stripped = false
      for prefix in prefixes
      where value.lowercased().hasPrefix(prefix) && value.count > prefix.count {
        value = StatementText.collapse(String(value.dropFirst(prefix.count)))
        stripped = true
      }
    }
    var words = value.split(separator: " ").map(String.init)
    // Country and city.
    if words.count >= 3, let last = words.last,
      countries.contains(last) || countries2.contains(last),
      isUpperWord(words[words.count - 2])
    {
      words.removeLast(2)
      if words.count >= 2, words[words.count - 1] == "G" { words.removeLast() }
    }
    // «G CITY»: the bank's letter for «city» in front of an upper-case place name.
    if words.count >= 3, words[words.count - 2] == "G", isUpperWord(words[words.count - 1]) {
      words.removeLast(2)
    }
    // Point number.
    while words.count >= 2, let last = words.last, isPointNumber(last) {
      words.removeLast()
    }
    return words.joined(separator: " ")
  }

  private static func isUpperWord(_ word: String) -> Bool {
    !word.isEmpty
      && word.unicodeScalars.allSatisfy { $0.properties.isUppercase || $0 == "-" || $0 == "." }
  }

  private static func isPointNumber(_ word: String) -> Bool {
    var body = Substring(word)
    if body.first == "#" || body.first == "№" { body = body.dropFirst() }
    guard body.count >= 3, let first = body.first, first.isASCII, first.isNumber else {
      return false
    }
    return body.allSatisfy { ($0.isASCII && ($0.isNumber || $0.isUppercase)) || $0 == "_" }
  }
}

/// Reads a month named in a wording («Кэшбэк за сентябрь»).
public enum StatementMonthName {
  private static let stems = [
    "январ", "феврал", "март", "апрел", "ма", "июн", "июл", "август", "сентябр", "октябр",
    "ноябр", "декабр",
  ]

  /// 1...12, or `nil` if the word is no Russian month name.
  public static func number(of word: String) -> Int? {
    let lower = word.lowercased()
    for (index, stem) in stems.enumerated() {
      if stem == "ма" {
        if lower == "май" || lower == "мая" || lower == "мае" { return index + 1 }
      } else if lower.hasPrefix(stem) {
        return index + 1
      }
    }
    return nil
  }
}

/// A day, and an optional time, written the way Russian banks write them.
enum StatementDateText {
  /// `dd.MM.yyyy` → a day; `nil` for anything that is not a real date.
  static func day(_ text: String) -> DateOnly? {
    let parts = text.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3, parts[0].count == 2, parts[1].count == 2, parts[2].count == 4,
      let d = Int(parts[0]), let m = Int(parts[1]), let y = Int(parts[2])
    else { return nil }
    let date = DateOnly(year: y, month: m, day: d)
    return StatementCivil.isValid(date) ? date : nil
  }

  /// `HH:mm` → minute of the day.
  static func minute(_ text: String) -> Int? {
    let parts = text.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 2, parts[0].count == 2, parts[1].count == 2, let h = Int(parts[0]),
      let m = Int(parts[1]), h < 24, m < 60
    else { return nil }
    return h * 60 + m
  }

  /// `dd.MM.yyyy HH:mm` or `dd.MM.yyyy`.
  static func moment(_ text: String) -> StatementMoment? {
    let words = text.split(whereSeparator: { $0 == " " || $0 == "\u{00A0}" }).map(String.init)
    guard let first = words.first, let day = day(first) else { return nil }
    if words.count == 1 { return StatementMoment(day: day) }
    guard words.count == 2, let minute = minute(words[1]) else { return nil }
    return StatementMoment(day: day, minuteOfDay: minute)
  }
}

extension ImportedOperation {
  /// Applies what a description rule found to the operation.
  mutating func apply(_ reading: StatementReading) {
    kind = reading.kind
    let fields = reading.fields
    if let name = fields["name"] {
      counterparty.name = StatementText.collapsingRepeatedPhrase(name)
    }
    if let phone = fields["phone"] { counterparty.phone = phone }
    if let bank = fields["bank"] { counterparty.bankName = bank }
    if let contract = fields["contract"] { counterparty.contractRef = contract }
    if let mask = fields["cardMask"] { counterparty.cardMask = mask }
    if let text = fields["message"] {
      message = StatementText.collapsingRepeatedPhrase(text)
    }
    if let merchantText = fields["merchant"] {
      merchant = StatementMerchant.clean(StatementText.collapsingRepeatedPhrase(merchantText))
    }
    if let month = fields["month"] { cashbackMonth = StatementMonthName.number(of: month) }
  }
}
