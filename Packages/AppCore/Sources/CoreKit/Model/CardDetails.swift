import Foundation

/// What the owner may keep about a card besides its name: the last four digits that let a bank text find the card, and — if the owner wants
/// them — the rest of its data.
///
/// The security code is **never** kept: there is no field for it here, in the database, in the
/// archive or in the CSV, and nothing may add one. The full number is the owner's to enter and
/// is never written to the log (`LogPrivacy` allows identifiers and counters only).
///
/// Stored form, one nullable column each on `cards`: `last4`, `number`, `holder`, `expiry`
/// (`YYYY-MM`), `network`.
public struct CardDetails: Hashable, Sendable, Codable {
  public enum Network: String, Hashable, Sendable, Codable, CaseIterable {
    case mir
    case visa
    case mastercard
    case maestro
    case unionpay
    case amex
  }

  public enum Problem: Hashable, Sendable {
    /// Not four digits.
    case badLast4
    /// Not 12 to 19 digits, or the check digit does not fit.
    case badNumber
    /// The last four digits disagree with the number.
    case last4DoesNotMatchNumber
    case badExpiry
  }

  /// Four digits. When `number` is set they are its last four.
  public var last4: String?
  /// Digits only, 12 to 19 of them.
  public var number: String?
  public var holder: String?
  public var expiry: MonthKey?
  public var network: Network?

  public init(
    last4: String? = nil, number: String? = nil, holder: String? = nil, expiry: MonthKey? = nil,
    network: Network? = nil
  ) {
    self.number = number.map(Self.digits)
    self.last4 = last4 ?? self.number.map { String($0.suffix(4)) }
    self.holder = holder
    self.expiry = expiry
    self.network = network ?? self.number.flatMap(Self.network(of:))
  }

  /// What is wrong with it; empty when it can be kept.
  public var problems: [Problem] {
    var found: [Problem] = []
    if let last4, !(last4.count == 4 && last4.allSatisfy(\.isASCIIDigit)) {
      found.append(.badLast4)
    }
    if let number {
      if !Self.isValid(number: number) {
        found.append(.badNumber)
      } else if let last4, number.suffix(4) != last4 {
        found.append(.last4DoesNotMatchNumber)
      }
    }
    if let expiry, !(1...12).contains(expiry.month) || !(2000...2100).contains(expiry.year) {
      found.append(.badExpiry)
    }
    return found
  }

  /// The card has run out on `day`: the month printed on it is over.
  public func isExpired(on day: DateOnly) -> Bool {
    guard let expiry else { return false }
    return day.monthKey > expiry
  }

  /// «•••• 3230» — the only form of the number a list or a log line may show.
  public var masked: String? {
    last4.map { "•••• " + $0 }
  }

  // MARK: - Reading what the owner types

  /// Only the digits of a typed number: «2200 7012 3456 7890» is 2200701234567890.
  public static func digits(_ text: String) -> String {
    String(text.filter(\.isASCIIDigit))
  }

  /// «05/28», «5/2028», «05.28», «2028-05» → May 2028; nil for anything else.
  public static func expiry(from text: String) -> MonthKey? {
    let parts = text.split(whereSeparator: { "/.-– ".contains($0) }).map(String.init)
    guard parts.count == 2, let first = Int(parts[0]), let second = Int(parts[1]) else {
      return nil
    }
    let (month, year): (Int, Int)
    if parts[0].count == 4 {
      (month, year) = (second, first)
    } else {
      (month, year) = (first, parts[1].count <= 2 ? 2000 + second : second)
    }
    guard (1...12).contains(month), (2000...2100).contains(year) else { return nil }
    return MonthKey(year: year, month: month)
  }

  // MARK: - Number

  /// Twelve to nineteen digits and a right check digit (Luhn): a slip of a finger is found at
  /// once instead of keeping a number no bank has.
  public static func isValid(number: String) -> Bool {
    guard (12...19).contains(number.count), number.allSatisfy(\.isASCIIDigit) else { return false }
    var sum = 0
    for (offset, character) in number.reversed().enumerated() {
      var digit = Int(String(character)) ?? 0
      if offset % 2 == 1 {
        digit *= 2
        if digit > 9 { digit -= 9 }
      }
      sum += digit
    }
    return sum % 10 == 0
  }

  /// The payment system by the first digits of the number.
  public static func network(of number: String) -> Network? {
    let digits = digits(number)
    func prefix(_ length: Int) -> Int? { Int(digits.prefix(length)) }
    guard digits.count >= 12, let first = prefix(1) else { return nil }
    if let four = prefix(4), (2200...2204).contains(four) { return .mir }
    if let four = prefix(4), (2221...2720).contains(four) { return .mastercard }
    if let two = prefix(2), [34, 37].contains(two) { return .amex }
    if let two = prefix(2), two == 62 { return .unionpay }
    if let two = prefix(2), (51...55).contains(two) { return .mastercard }
    if let two = prefix(2), two == 50 || (56...69).contains(two) { return .maestro }
    if first == 4 { return .visa }
    return nil
  }
}

extension Character {
  fileprivate var isASCIIDigit: Bool { self >= "0" && self <= "9" }
}
