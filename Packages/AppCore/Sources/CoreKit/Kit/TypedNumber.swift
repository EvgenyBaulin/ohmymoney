import Foundation

/// A number as a person types it as an amount of money: in the entry line, in a formula, in an
/// amount field. Rates, interest and shares are read by `DecimalMath.parse`, where a lone
/// separator is always the decimal one («83,125» is a rate of 83.125); so is everything the
/// Bank of Russia sends.
///
/// Which of `,` and `.` is which:
/// - a single `,` groups thousands only when one to three digits stand before it, the first
///   of them not a zero, and exactly three after it: «1,500» is 1 500, «12,345» is 12 345,
///   «100,200» is 100 200. Any other single `,` is decimal: «1,5», «1,50», «250,00»,
///   «1500,5» (1 500.5), «0,500» (0.5);
/// - a single `.` is always decimal: «1.500» is 1.5;
/// - a separator written twice or more groups thousands: «1,234,567», «1.234.567»;
/// - with both kinds, the rightmost is decimal and the other groups: «1.234,56» and
///   «1,234.56» are both 1 234.56.
///
/// A separator that groups thousands has a digit before it and exactly three digits after
/// it; «1,2.3» is refused, not read as 12.3. A space groups thousands on the same terms and
/// only before the decimal part: «1 234,56» is 1 234.56, «1 5» is refused. Spaces around the
/// number are trimmed. A leading sign is read; the formula around a number is the business of
/// the expression evaluator, and so is the `k` of thousands.
///
/// One exception: in front of the `k` of thousands a lone comma is always the decimal one —
/// «1,500к» is 1.5 thousand, 1 500, never a million and a half (`read(_:loneCommaIsDecimal:)`,
/// which the expression evaluator asks for such a number). Two commas still group thousands
/// there, and with both kinds the rightmost is decimal, as everywhere.
public enum TypedNumber {
  /// What a typed number says, and how the app writes it back.
  public struct Reading: Hashable, Sendable {
    public let isNegative: Bool
    /// The digits before the decimal separator, grouping and leading zeros dropped: "0" at least.
    public let integerDigits: String
    /// The digits after the decimal separator exactly as typed, trailing zeros included:
    /// «250,00» keeps "00". Empty for a whole number.
    public let fractionDigits: String
    /// The number itself. `read` gives a reading only for digits a `Decimal` holds, so this is
    /// never a stand-in for a number that could not be read.
    public let value: Decimal

    /// The number written the one way the app writes numbers: a comma between the thousands,
    /// a point before the fraction, the digits of the fraction as typed — «1500,5» becomes
    /// «1,500.5», «1.234,56» becomes «1,234.56», «250,00» becomes «250.00». Read again by
    /// `TypedNumber`, it is the same number. The sign is the ASCII hyphen-minus, so the text
    /// can be typed on and read back as it is; a zero has none, as nowhere in the app does —
    /// «-0,00» becomes «0.00».
    public var canonical: String {
      let grouped = NumberText.grouped(integerDigits)
      let body = fractionDigits.isEmpty ? grouped : grouped + "." + fractionDigits
      return isNegative && !value.isZero ? "-" + body : body
    }
  }

  /// The value of a typed number, or nil for text that is not one number.
  public static func parse(_ text: String) -> Decimal? {
    read(text)?.value
  }

  /// A typed number taken apart, or nil for text that is not one number.
  /// Digits a `Decimal` does not hold — more than a few hundred of them — are not a number
  /// either (`isTooLarge` tells which of the two it is).
  ///
  /// `loneCommaIsDecimal`: the number stands in front of the `k` of thousands, where a single
  /// comma is the decimal one whatever the digits around it — «1,500» of «1,500к» is 1.5.
  public static func read(_ text: String, loneCommaIsDecimal: Bool = false) -> Reading? {
    guard let digits = taken(apart: text, loneCommaIsDecimal: loneCommaIsDecimal),
      let magnitude = decimalValue(
        of: digits.integer + (digits.fraction.isEmpty ? "" : "." + digits.fraction))
    else { return nil }
    return Reading(
      isNegative: digits.isNegative, integerDigits: digits.integer,
      fractionDigits: digits.fraction, value: digits.isNegative ? -magnitude : magnitude)
  }

  /// The sign and the digits of a typed number, grouping and leading zeros dropped, or nil for
  /// text that is not one number.
  private static func taken(
    apart text: String, loneCommaIsDecimal: Bool = false
  ) -> (
    isNegative: Bool, integer: String, fraction: String
  )? {
    var characters = Array(text.trimmingCharacters(in: .whitespacesAndNewlines))
    var isNegative = false
    if let sign = characters.first, sign == "-" || sign == "+" || sign == "\u{2212}" {
      isNegative = sign != "+"
      characters.removeFirst()
    }
    guard let unspaced = droppingThousandSpaces(characters) else { return nil }
    guard !unspaced.isEmpty, unspaced.allSatisfy({ isASCIIDigit($0) || isSeparator($0) }),
      unspaced.contains(where: isASCIIDigit)
    else { return nil }
    let decimal: Int?
    switch decimalSeparator(in: unspaced, loneCommaIsDecimal: loneCommaIsDecimal) {
    case .noDecimal: decimal = nil
    case .at(let index): decimal = index
    case .refused: return nil
    }
    var integer = ""
    var fraction = ""
    for (index, character) in unspaced.enumerated() {
      if index == decimal { continue }
      if isSeparator(character) {
        // Any other separator groups thousands, so it stands before the decimal one.
        guard decimal.map({ index < $0 }) ?? true, index > 0, isASCIIDigit(unspaced[index - 1]),
          startsGroupOfThree(unspaced, at: index)
        else { return nil }
        continue
      }
      if let decimal, index > decimal {
        fraction.append(character)
      } else {
        integer.append(character)
      }
    }
    let trimmed = integer.drop { $0 == "0" }
    return (isNegative, trimmed.isEmpty ? "0" : String(trimmed), fraction)
  }

  /// The digits as a `Decimal`, or nil when there are more than it holds.
  private static func decimalValue(of digits: String) -> Decimal? {
    Decimal(string: digits, locale: Locale(identifier: "en_US_POSIX"))
  }

  /// Whether the text is written as one number, but one with more whole digits than a
  /// `Decimal` holds — hundreds of nines. `read` refuses it; this tells it from a typo, so the
  /// entry line can say the amount is too large rather than that it does not read.
  public static func isTooLarge(_ text: String, loneCommaIsDecimal: Bool = false) -> Bool {
    guard let digits = taken(apart: text, loneCommaIsDecimal: loneCommaIsDecimal) else {
      return false
    }
    return decimalValue(of: digits.integer) == nil
  }

  /// Whether the text is one number with a point before exactly three digits and one to three
  /// digits, the first not a zero, before it — «1.500», «15.000». It reads as 1.5 and 15, while
  /// a reader used to a point between the thousands sees 1 500 and 15 000, so the entry line
  /// shows what such a number comes to before Enter. A `k` of thousands behind it changes
  /// nothing: «1.500k» is 1 500 and may be taken for a million and a half. A leading zero
  /// («0.500», «01.500») or a longer first part («1500.500») leaves no doubt; a comma before
  /// three digits groups them already.
  public static func mayBeTakenForThousands(_ text: String) -> Bool {
    var body = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
    if let last = body.last, thousandSuffixes.contains(last) { body = body.dropLast() }
    guard let reading = read(String(body)), reading.fractionDigits.count == 3 else {
      return false
    }
    // Told by the digits as typed: the reading has dropped the zeros in front already.
    if let sign = body.first, sign == "-" || sign == "+" || sign == "\u{2212}" {
      body = body.dropFirst()
    }
    guard let point = body.firstIndex(of: ".") else { return false }
    let before = body[..<point]
    let after = body[body.index(after: point)...]
    return (1...3).contains(before.count) && before.first != "0"
      && before.allSatisfy(isASCIIDigit) && after.count == 3 && after.allSatisfy(isASCIIDigit)
  }

  /// The `k` of thousands and its Russian twin, both cases, as the formula reads them.
  private static let thousandSuffixes: Set<Character> = ["k", "K", "\u{043A}", "\u{041A}"]

  /// The characters with the spaces that group thousands taken out, or nil when a space does
  /// not group them: it must follow a digit, stand before three digits and no fourth, and come
  /// before any `,` or `.` — «1,5 120» is not one number.
  private static func droppingThousandSpaces(_ characters: [Character]) -> [Character]? {
    var kept: [Character] = []
    kept.reserveCapacity(characters.count)
    var sawSeparator = false
    for (index, character) in characters.enumerated() {
      if isSeparator(character) { sawSeparator = true }
      guard character.isWhitespace else {
        kept.append(character)
        continue
      }
      guard !sawSeparator, index > 0, isASCIIDigit(characters[index - 1]),
        startsGroupOfThree(characters, at: index)
      else { return nil }
    }
    return kept
  }

  private enum DecimalSeparator {
    /// Every separator groups thousands, or there is none.
    case noDecimal
    case at(Int)
    /// Both kinds are written and the rightmost kind more than once: no decimal separator
    /// can be told.
    case refused
  }

  /// Which separator, if any, is the decimal one. `loneCommaIsDecimal`: a single comma is,
  /// whatever the digits around it (a number in front of the `k` of thousands).
  private static func decimalSeparator(
    in characters: [Character], loneCommaIsDecimal: Bool = false
  ) -> DecimalSeparator {
    let commas = characters.indices.filter { characters[$0] == "," }
    let dots = characters.indices.filter { characters[$0] == "." }
    if commas.isEmpty && dots.isEmpty { return .noDecimal }
    if dots.isEmpty {
      guard commas.count == 1 else { return .noDecimal }
      if loneCommaIsDecimal { return .at(commas[0]) }
      return commaGroupsThousands(characters, at: commas[0]) ? .noDecimal : .at(commas[0])
    }
    if commas.isEmpty { return dots.count == 1 ? .at(dots[0]) : .noDecimal }
    // Both kinds: the rightmost is decimal, and it is written only once.
    let last = max(commas[commas.count - 1], dots[dots.count - 1])
    let sameKind = characters[last] == "," ? commas : dots
    return sameKind.count == 1 ? .at(last) : .refused
  }

  /// A lone comma groups thousands when one to three digits, the first not a zero, stand
  /// before it and exactly three after it.
  private static func commaGroupsThousands(_ characters: [Character], at index: Int) -> Bool {
    let before = characters[..<index]
    guard (1...3).contains(before.count), before.first != "0" else { return false }
    return characters.count == index + 4 && startsGroupOfThree(characters, at: index)
  }

  private static func isSeparator(_ character: Character) -> Bool {
    character == "." || character == ","
  }

  private static func isASCIIDigit(_ character: Character) -> Bool {
    character >= "0" && character <= "9"
  }

  /// Exactly three digits follow the character at `index`, and no fourth.
  private static func startsGroupOfThree(_ characters: [Character], at index: Int) -> Bool {
    guard index + 3 < characters.count else { return false }
    for offset in 1...3 where !isASCIIDigit(characters[index + offset]) { return false }
    let after = index + 4
    return after == characters.count || !isASCIIDigit(characters[after])
  }
}
