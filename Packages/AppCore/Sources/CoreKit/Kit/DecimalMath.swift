import Foundation

/// Decimal helpers shared by every platform. Kept in one place so rounding behaves
/// identically in the app, in the reports and in the future Windows port.
public enum DecimalMath {
  /// Rounds half away from zero and converts to `Int64`, rejecting anything out of range.
  public static func int64(rounding value: Decimal) throws -> Int64 {
    var source = value
    var rounded = Decimal()
    NSDecimalRound(&rounded, &source, 0, .plain)
    guard rounded <= Decimal(Int64.max), rounded >= Decimal(Int64.min) else {
      throw CoreError.amountOutOfRange
    }
    guard let result = Int64(plainDescription(of: rounded)) else {
      throw CoreError.amountOutOfRange
    }
    return result
  }

  /// Rounds to a number of fraction digits, half away from zero.
  public static func round(_ value: Decimal, scale: Int) -> Decimal {
    round(value, scale: scale, mode: .plain)
  }

  /// Rounds to a number of fraction digits the way `mode` says. For `.down` and `.up` the value
  /// should not be below zero: they mean toward and away from zero only there, and the caller
  /// rounds a magnitude and keeps the sign (`CashbackRounding`).
  public static func round(
    _ value: Decimal, scale: Int, mode: NSDecimalNumber.RoundingMode
  ) -> Decimal {
    var source = value
    var rounded = Decimal()
    NSDecimalRound(&rounded, &source, scale, mode)
    return rounded
  }

  /// Parses a decimal written with either decimal separator, ignoring spaces used
  /// as thousand separators: "1 250,50" and "1,250.50" both mean 1250.5. This is the reading
  /// of rates, interest, shares and of what the Bank of Russia sends; an amount of money typed
  /// by hand is read by `TypedNumber`, where «1,500» is 1 500.
  ///
  /// A space inside the number is a thousand separator only: a digit before it, exactly
  /// three digits after it, and the decimal part not started yet — the rule the entry line
  /// follows too (`TypedNumber`). Any other space is a typo and the text is refused:
  /// "1 5" typed into a field is not 15, and "1,5 120" is not 1.512. Spaces around the
  /// number are trimmed.
  ///
  /// Which of `.` and `,` is the decimal separator: when both are written,
  /// the rightmost; a separator written twice or more groups thousands ("1,250,000"); a lone
  /// one is decimal, whichever it is — "1,250" is 1.25, as "1,25" is. A separator that groups
  /// thousands obeys the space's rule: a digit before it, exactly three digits after it, so
  /// "1,2.3" is refused, not read as 12.3.
  public static func parse(_ text: String) -> Decimal? {
    let characters = Array(text.trimmingCharacters(in: .whitespacesAndNewlines))
    let lastSeparator = characters.lastIndex(where: isSeparator)
    var cleaned: [Character] = []
    cleaned.reserveCapacity(characters.count)
    for (index, character) in characters.enumerated() {
      guard character.isWhitespace else {
        cleaned.append(character)
        continue
      }
      guard index > 0, isASCIIDigit(characters[index - 1]),
        startsGroupOfThree(characters, separatorAt: index),
        lastSeparator.map({ index < $0 }) ?? true
      else { return nil }
    }
    guard !cleaned.isEmpty, let pointed = pointed(cleaned) else { return nil }
    // Foundation stops at the first invalid character, so "1..2" would parse as 1.
    // Validate the shape ourselves before handing the string over.
    //
    // Only the ten ASCII digits count. `Character.isNumber` also answers `true` for
    // superscripts, fractions and the digits of other scripts ("1²", "2٢", "½"), which
    // Foundation then reads only up to the first of them: "1²" came back as 1 and "2٢"
    // as 2 — garbage turning into a different, plausible-looking amount instead of being
    // refused.
    var digits = 0
    var dots = 0
    for (index, character) in pointed.enumerated() {
      if character.isASCII && character.isNumber {
        digits += 1
      } else if character == "." {
        dots += 1
      } else if (character == "-" || character == "+") && index == 0 {
        continue
      } else {
        return nil
      }
    }
    guard digits > 0, dots <= 1 else { return nil }
    return Decimal(string: pointed, locale: Locale(identifier: "en_US_POSIX"))
  }

  /// The number with its thousand separators dropped and its decimal separator turned into a
  /// point, or nil when a separator that must group thousands does not.
  private static func pointed(_ characters: [Character]) -> String? {
    let commas = characters.filter { $0 == "," }.count
    let dots = characters.filter { $0 == "." }.count
    let decimal: Character?
    if commas > 0 && dots > 0 {
      decimal = characters.last(where: isSeparator)
    } else if commas + dots == 1 {
      decimal = characters.first(where: isSeparator)
    } else {
      decimal = nil
    }
    if let decimal, characters.filter({ $0 == decimal }).count > 1 { return nil }
    var pointed = ""
    pointed.reserveCapacity(characters.count)
    for (index, character) in characters.enumerated() {
      if character == decimal {
        pointed.append(".")
      } else if isSeparator(character) {
        guard index > 0, isASCIIDigit(characters[index - 1]),
          startsGroupOfThree(characters, separatorAt: index)
        else { return nil }
      } else {
        pointed.append(character)
      }
    }
    return pointed
  }

  private static func isSeparator(_ character: Character) -> Bool {
    character == "." || character == ","
  }

  private static func isASCIIDigit(_ character: Character) -> Bool {
    character >= "0" && character <= "9"
  }

  /// Exactly three digits follow the separator at `index`, and no fourth.
  private static func startsGroupOfThree(_ characters: [Character], separatorAt index: Int) -> Bool
  {
    guard index + 3 < characters.count else { return false }
    for offset in 1...3 where !isASCIIDigit(characters[index + offset]) { return false }
    let after = index + 4
    return after == characters.count || !isASCIIDigit(characters[after])
  }

  /// `Decimal.description` without exponent notation, safe to feed to `Int64.init`.
  private static func plainDescription(of value: Decimal) -> String {
    let description = value.description
    guard description.contains("e") || description.contains("E") else { return description }
    return NSDecimalNumber(decimal: value).stringValue
  }
}
