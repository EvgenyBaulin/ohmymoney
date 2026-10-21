import Foundation

/// Numbers as the app writes them, in every language: a comma between the thousands and a
/// point before the fraction — «1,234,567.89». Built here by hand rather than by a
/// `NumberFormatter`, so a Russian Mac, an English one and a build on another platform write
/// exactly the same text. The words around a number — a currency, «млн», the space before «%» —
/// belong to the interface; this only writes the number.
public enum NumberText {
  /// The typographic minus (U+2212) the interface writes before a negative number.
  public static let minus = "\u{2212}"

  /// Digits with a comma between every three from the right: "1234567" becomes "1,234,567".
  /// Anything but ASCII digits is returned as it is.
  public static func grouped(_ digits: String) -> String {
    guard digits.count > 3, digits.allSatisfy({ $0 >= "0" && $0 <= "9" }) else { return digits }
    var result = ""
    result.reserveCapacity(digits.count + digits.count / 3)
    for (offset, digit) in digits.enumerated() {
      if offset > 0 && (digits.count - offset) % 3 == 0 { result.append(",") }
      result.append(digit)
    }
    return result
  }

  /// An amount the way every list writes it: a whole amount without a fraction, anything else
  /// with at least the two digits of kopecks and up to the four the amount is stored with —
  /// «250», «1,234.50», «4.625», «0.0001». Exact: nothing is rounded.
  public static func amount(
    _ amount: AmountE4, grouping: Bool = true, minus: String = NumberText.minus
  ) -> String {
    let magnitude = amount.raw.magnitude
    let units = UInt64(AmountE4.unitsPerWhole)
    let whole = String(magnitude / units)
    var text = grouping ? grouped(whole) : whole
    let fraction = magnitude % units
    if fraction != 0 {
      let padded = String(repeating: "0", count: 4 - String(fraction).count) + String(fraction)
      text += "." + trimmingZeros(padded, keeping: 2)
    }
    return amount.raw < 0 ? minus + text : text
  }

  /// A whole number with its thousands grouped: «1,250», «−3,400».
  public static func integer(
    _ value: Int64, grouping: Bool = true, minus: String = NumberText.minus
  ) -> String {
    let digits = String(value.magnitude)
    let text = grouping ? grouped(digits) : digits
    return value < 0 ? minus + text : text
  }

  /// A number rounded half away from zero to at most `fractionDigits.upperBound` digits and
  /// written with at least `fractionDigits.lowerBound`: 33.333 with `1...1` is «33.3», 83.1250
  /// with `0...4` is «83.125», 12 with `2...2` is «12.00». The sign is that of the rounded
  /// number, so −0.04 with one digit is «0.0», never «−0.0».
  public static func decimal(
    _ value: Decimal, fractionDigits: ClosedRange<Int> = 0...4, grouping: Bool = true,
    minus: String = NumberText.minus
  ) -> String {
    let rounded = DecimalMath.round(value, scale: fractionDigits.upperBound)
    return written(rounded, keeping: fractionDigits.lowerBound, grouping: grouping, minus: minus)
  }

  /// Every digit of the number, nothing rounded: the text a field shows for a rate, so that
  /// reading it back gives the very same rate. «81.4321», «0.1854».
  public static func plain(
    _ value: Decimal, grouping: Bool = false, minus: String = "-"
  ) -> String {
    written(value, keeping: 0, grouping: grouping, minus: minus)
  }

  private static func written(
    _ value: Decimal, keeping minimumFraction: Int, grouping: Bool, minus: String
  ) -> String {
    guard !value.isNaN else { return "0" }
    let negative = value < 0
    let digits = plainDigits(negative ? -value : value)
    let parts = digits.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
    let whole = parts.first.map(String.init).flatMap { $0.isEmpty ? nil : $0 } ?? "0"
    var fraction = parts.count > 1 ? String(parts[1]) : ""
    if fraction.count < minimumFraction {
      fraction += String(repeating: "0", count: minimumFraction - fraction.count)
    }
    fraction = trimmingZeros(fraction, keeping: minimumFraction)
    var text = grouping ? grouped(whole) : whole
    if !fraction.isEmpty { text += "." + fraction }
    let isZero = whole.allSatisfy { $0 == "0" } && fraction.allSatisfy { $0 == "0" }
    return negative && !isZero ? minus + text : text
  }

  /// A sentence with counts written into it by a format — «Удалить 1 250 операций?» — with each
  /// of those counts written the way the app writes numbers: «Удалить 1,250 операций?». The
  /// plural form of the sentence is chosen by the count, so the count goes into the format as a
  /// number, and a format groups it the way the language does — a space in Russian, a comma in
  /// English — or not at all. A run of digits that is not one of the counts, or that is part of
  /// a longer number («12.1250», «1250,5»), stays as it is.
  public static func groupingCounts(_ counts: [Int64], in text: String) -> String {
    let wanted = Set(counts.filter { $0.magnitude >= 1_000 }.map { String($0.magnitude) })
    guard !wanted.isEmpty else { return text }
    let characters = Array(text)
    func isDigit(_ index: Int) -> Bool {
      characters.indices.contains(index) && characters[index] >= "0" && characters[index] <= "9"
    }
    func isSeparator(_ index: Int) -> Bool {
      characters.indices.contains(index) && (characters[index] == "." || characters[index] == ",")
    }
    // What a format of either language puts between the thousands.
    func groupsThousands(_ index: Int) -> Bool {
      guard characters.indices.contains(index),
        [",", "\u{00A0}", "\u{202F}"].contains(characters[index])
      else { return false }
      return isDigit(index + 1) && isDigit(index + 2) && isDigit(index + 3) && !isDigit(index + 4)
    }
    var result = ""
    result.reserveCapacity(characters.count + 4)
    var index = 0
    while index < characters.count {
      guard isDigit(index) else {
        result.append(characters[index])
        index += 1
        continue
      }
      var end = index
      var digits = ""
      while isDigit(end) {
        digits.append(characters[end])
        end += 1
      }
      while groupsThousands(end) {
        digits += String(characters[(end + 1)...(end + 3)])
        end += 4
      }
      let partOfANumber =
        (isSeparator(index - 1) && isDigit(index - 2)) || (isSeparator(end) && isDigit(end + 1))
      result +=
        wanted.contains(digits) && !partOfANumber
        ? grouped(digits) : String(characters[index..<end])
      index = end
    }
    return result
  }

  /// Trailing zeros of a fraction dropped, down to `keeping` digits.
  private static func trimmingZeros(_ fraction: String, keeping: Int) -> String {
    var characters = Array(fraction)
    while characters.count > keeping, characters.last == "0" { characters.removeLast() }
    return String(characters)
  }

  /// The digits of a non-negative decimal with a point, never in exponent notation.
  private static func plainDigits(_ value: Decimal) -> String {
    let description = value.description
    guard description.contains("e") || description.contains("E") else { return description }
    return NSDecimalNumber(decimal: value).stringValue
  }
}
