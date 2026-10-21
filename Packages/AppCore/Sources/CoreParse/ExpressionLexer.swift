import CoreKit
import Foundation

/// One token of an arithmetic expression together with the offset of its first character.
/// The offset is what `CoreError.malformedExpression(position:)` reports, so the entry
/// field can underline the exact character that broke the formula.
struct ExpressionToken: Equatable {
  enum Kind: Equatable {
    /// A number, and the same number as an exact fraction when it fits one.
    case number(Decimal, exact: ExactFraction?)
    case plus
    case minus
    case times
    case divide
    case openParen
    case closeParen
  }

  let kind: Kind
  let position: Int
  /// The offset just past the token.
  let end: Int
  /// A number written the way the app writes numbers, its `k` kept as typed: «1500,5» is
  /// «1,500.5», «2,5к» is «2.5к». Empty for everything but a number.
  var canonical = ""
}

/// Turns the characters of an expression into tokens.
///
/// Numbers accept both decimal separators and every thousand separator a person may type:
/// a plain space, a non-breaking space, a thin space, `.` or `,`. Which separator is the
/// decimal one is decided by `TypedNumber`, the rule of amounts typed by hand: `1,250.50` and
/// `1.250,50` both mean 1250.5, `1,500` is 1500 and `1,5` is 1.5. A trailing `k` / `к`
/// multiplies by a thousand: `2k` and `2к` are 2000, and a lone comma in front of it is always
/// decimal — `1,500к` is 1500, not a million and a half.
///
/// `x` or `х` (Latin or Cyrillic, either case) with a digit right before and right after it is
/// the sign of multiplication: `250x2` is 500. With a space on either side it is a letter.
enum ExpressionLexer {
  /// Spaces that may sit inside a number as a thousand separator.
  static let spaces: Set<Character> = [
    " ", "\u{00A0}", "\u{202F}", "\u{2009}", "\t", "\n", "\r",
  ]
  /// `k` and its Russian twin `к`, both cases.
  static let thousandSuffixes: Set<Character> = ["k", "K", "к", "К"]
  static let decimalSeparators: Set<Character> = [".", ","]
  /// `x`/`х` in either case: a multiplication sign when glued to digits on both sides.
  static let timesLetters: Set<Character> = ["x", "X", "\u{0445}", "\u{0425}"]

  /// Whether the character at `index` is a letter `x`/`х` with a digit right before and right
  /// after it: «250x2», «2,5х400».
  static func isGluedTimes(_ characters: [Character], at index: Int) -> Bool {
    guard characters.indices.contains(index), timesLetters.contains(characters[index]),
      index > 0, index + 1 < characters.count
    else { return false }
    return isDigit(characters[index - 1]) && isDigit(characters[index + 1])
  }

  /// Whether the text holds a letter `x`/`х` glued to digits on both sides.
  static func hasGluedTimes(_ text: String) -> Bool {
    let characters = Array(text)
    return characters.indices.contains { isGluedTimes(characters, at: $0) }
  }

  static func isDigit(_ character: Character) -> Bool {
    character >= "0" && character <= "9"
  }

  static func isSpace(_ character: Character) -> Bool {
    spaces.contains(character) || character.isWhitespace
  }

  static func operatorKind(_ character: Character) -> ExpressionToken.Kind? {
    switch character {
    case "+": return .plus
    // U+2212 minus sign, U+2013 en dash, U+2014 em dash — all typed instead of a hyphen.
    case "-", "\u{2212}", "\u{2013}", "\u{2014}": return .minus
    case "*", "\u{00D7}", "\u{22C5}", "\u{00B7}": return .times
    case "/", "\u{00F7}", "\u{2215}": return .divide
    case "(": return .openParen
    case ")": return .closeParen
    default: return nil
    }
  }

  /// How the numbers of a formula are read: as amounts typed by hand (`TypedNumber`, the `k` of
  /// thousands) or as rates (`DecimalMath.parse`: a lone separator is the decimal one, no `k`).
  enum NumberRule {
    case amount
    case rate
  }

  static func tokenize(
    _ characters: [Character], numbers rule: NumberRule = .amount
  ) throws -> [ExpressionToken] {
    var tokens: [ExpressionToken] = []
    var index = 0
    while index < characters.count {
      let character = characters[index]
      if isSpace(character) {
        index += 1
        continue
      }
      let startsNumber =
        isDigit(character)
        || (decimalSeparators.contains(character) && index + 1 < characters.count
          && isDigit(characters[index + 1]))
      if startsNumber {
        let scanned =
          rule == .amount
          ? try scanNumber(characters, from: index) : try scanRate(characters, from: index)
        tokens.append(
          ExpressionToken(
            kind: .number(scanned.value, exact: scanned.exact), position: index,
            end: scanned.end, canonical: scanned.canonical))
        index = scanned.end
        continue
      }
      if isGluedTimes(characters, at: index) {
        tokens.append(ExpressionToken(kind: .times, position: index, end: index + 1))
        index += 1
        continue
      }
      guard let kind = operatorKind(character) else {
        throw CoreError.malformedExpression(position: index)
      }
      tokens.append(ExpressionToken(kind: kind, position: index, end: index + 1))
      index += 1
    }
    return tokens
  }

  /// Reads one number of a rate formula starting at `start`: the digits, separators and
  /// grouping spaces an amount takes, read by the rule of rates — «83,125» is 83.125. A `k`
  /// after it is no suffix here: it is left to fail as the character it is.
  private static func scanRate(
    _ characters: [Character], from start: Int
  ) throws -> (value: Decimal, exact: ExactFraction?, end: Int, canonical: String) {
    let (digits, end) = scanDigits(characters, from: start)
    guard let value = DecimalMath.parse(digits) else {
      throw CoreError.malformedExpression(position: start)
    }
    let written = NumberText.plain(value)
    let halves = written.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
    let exact = ExactFraction(
      integerDigits: String(halves[0]),
      fractionDigits: halves.count > 1 ? String(halves[1]) : "")
    return (value, exact, end, written)
  }

  /// The digits, separators and grouping spaces of one number from `start`, the spaces left
  /// out, and the offset just past them.
  private static func scanDigits(
    _ characters: [Character], from start: Int
  ) -> (digits: String, end: Int) {
    var index = start
    var digits = ""
    // Spaces group thousands before the decimal part only. Once a `.` or `,` has been read,
    // a space and three digits start the next number: «1,5 120» is 1.5 and 120, not 1.512.
    var sawSeparator = false
    while index < characters.count {
      let character = characters[index]
      if isDigit(character) {
        digits.append(character)
        index += 1
      } else if decimalSeparators.contains(character), index + 1 < characters.count,
        isDigit(characters[index + 1])
      {
        digits.append(character)
        sawSeparator = true
        index += 1
      } else if !sawSeparator, isSpace(character),
        startsGroupOfThree(characters, separatorAt: index)
      {
        index += 1
      } else {
        break
      }
    }
    return (digits, index)
  }

  /// Reads one number starting at `start` and returns it with the offset just past it and
  /// its canonical text.
  private static func scanNumber(
    _ characters: [Character], from start: Int
  ) throws -> (value: Decimal, exact: ExactFraction?, end: Int, canonical: String) {
    let (digits, scanned) = scanDigits(characters, from: start)
    var index = scanned

    var multiplier = Decimal(1)
    var suffix = ""
    if index < characters.count, thousandSuffixes.contains(characters[index]) {
      let next = index + 1 < characters.count ? characters[index + 1] : nil
      let glued = next.map { $0.isLetter || isDigit($0) } ?? false
      if !glued {
        multiplier = Decimal(1000)
        suffix = String(characters[index])
        index += 1
      }
    }

    // In front of the `k` of thousands a lone comma is the decimal one: «1,500к» is 1.5k.
    let thousands = !suffix.isEmpty
    guard let reading = TypedNumber.read(digits, loneCommaIsDecimal: thousands) else {
      // Hundreds of digits are a number too large to be an amount, not a typo.
      if TypedNumber.isTooLarge(digits, loneCommaIsDecimal: thousands) {
        throw CoreError.amountOutOfRange
      }
      throw CoreError.malformedExpression(position: start)
    }
    var exact = ExactFraction(
      integerDigits: reading.integerDigits, fractionDigits: reading.fractionDigits,
      multiplier: suffix.isEmpty ? 1 : 1_000)
    if reading.isNegative { exact = exact?.negated() }
    return (
      reading.value * multiplier, exact, index,
      canonicalText(of: reading, thousands: thousands) + suffix
    )
  }

  /// The number written the way the app writes numbers. In front of the `k` of thousands a
  /// whole number with a single comma between its thousands would read back as a fraction —
  /// «1,234к» is 1.234k —, so there it is written without the comma: «1234к».
  private static func canonicalText(of reading: TypedNumber.Reading, thousands: Bool) -> String {
    let canonical = reading.canonical
    guard thousands, reading.fractionDigits.isEmpty,
      canonical.filter({ $0 == "," }).count == 1
    else { return canonical }
    return canonical.replacingOccurrences(of: ",", with: "")
  }

  /// A space belongs to a number only when exactly three digits follow it, the way
  /// thousands are grouped: `1 250,50` is one number, `250 300` is 250300, but `1 25` is not.
  private static func startsGroupOfThree(
    _ characters: [Character], separatorAt index: Int
  ) -> Bool {
    guard index + 3 < characters.count else { return false }
    for offset in 1...3 where !isDigit(characters[index + offset]) { return false }
    let after = index + 4
    guard after < characters.count else { return true }
    return !isDigit(characters[after])
  }
}
