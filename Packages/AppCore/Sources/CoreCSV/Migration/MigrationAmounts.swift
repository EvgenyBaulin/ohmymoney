import CoreKit
import Foundation

/// Reads the amounts other applications write: `-1 234,56`, `1,234.56`, `(1 234,56)`,
/// `1234.5 RUB`, `$12.50`, `−350 ₽`. A comma followed by exactly three digits and nothing else
/// groups thousands (`1,500` is one thousand five hundred, as in the entry line); any other
/// lone separator is decimal; with both written, the rightmost is decimal. Brackets mean a
/// negative sum, as accountants write it. Anything else — two numbers, words around a number
/// that are not a currency — is `nil`, never a guess.
public enum MigrationAmounts {
  public struct Reading: Sendable, Hashable {
    public var amount: AmountE4
    /// The currency the cell itself names (`$`, `₽`, `USD`), if it names one.
    public var currency: CurrencyCode?
  }

  public static func parse(_ raw: String) -> Reading? {
    var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, text.count <= 40 else { return nil }
    var negative = false
    if text.hasPrefix("("), text.hasSuffix(")") {
      negative = true
      text = String(text.dropFirst().dropLast())
    }
    // «руб.»: the dot of an abbreviation is not a decimal point.
    if text.hasSuffix("."), text.dropLast().last?.isLetter == true { text.removeLast() }
    // The currency: a symbol anywhere, or a word of letters before or after the number.
    var currency: CurrencyCode?
    var number = ""
    var letters = ""
    for character in text {
      if let mark = symbols[character] {
        currency = mark
        continue
      }
      if character.isLetter {
        letters.append(character)
        continue
      }
      if character == "-" || character == "\u{2212}" || character == "\u{2013}" {
        guard number.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        negative.toggle()
        continue
      }
      if character == "+" { continue }
      guard
        character.isASCII
          ? (character.isNumber || character == "." || character == ",")
            || character == " " : character.isWhitespace
      else { return nil }
      number.append(character.isWhitespace ? " " : character)
    }
    if !letters.isEmpty {
      guard let named = word(letters) else { return nil }
      currency = named
    }
    let compact = number.filter { $0 != " " }
    guard compact.contains(where: \.isNumber) else { return nil }
    // A blank inside the digits groups thousands only where a group of three follows.
    let groups = number.split(separator: " ")
    if groups.count > 1 {
      for group in groups.dropFirst() {
        let digitsBeforeSeparator = group.prefix { $0.isNumber }
        guard digitsBeforeSeparator.count == 3 else { return nil }
      }
    }
    guard let decimal = decimal(compact) else { return nil }
    guard let amount = try? AmountE4(decimal: negative ? -decimal : decimal) else { return nil }
    return Reading(amount: amount, currency: currency)
  }

  /// The separator that groups thousands, if one does: one written twice, or the first of two
  /// different ones.
  private static func groupingSeparator(of text: String) -> Character? {
    if text.filter({ $0 == "," }).count > 1 { return "," }
    if text.filter({ $0 == "." }).count > 1 { return "." }
    guard let comma = text.firstIndex(of: ","), let dot = text.firstIndex(of: ".") else {
      return nil
    }
    return comma < dot ? "," : "."
  }

  private static func decimal(_ text: String) -> Decimal? {
    // A separator that groups thousands is followed by exactly three digits each time it is
    // written: «1.250.000» is a number, «01.02.2024» is a date.
    if let grouping = groupingSeparator(of: text) {
      let decimalMark: Character = grouping == "," ? "." : ","
      let whole = text.split(separator: decimalMark, omittingEmptySubsequences: false)[0]
      let groups = whole.split(separator: grouping, omittingEmptySubsequences: false)
      guard groups.count > 1, (1...3).contains(groups[0].count),
        groups.dropFirst().allSatisfy({ $0.count == 3 })
      else { return nil }
    }
    let commas = text.filter { $0 == "," }.count
    let dots = text.filter { $0 == "." }.count
    var normalised = text
    if commas == 1, dots == 0 {
      let parts = text.split(separator: ",", omittingEmptySubsequences: false)
      if parts.count == 2, parts[1].count == 3, (1...3).contains(parts[0].count) {
        normalised = String(parts[0]) + String(parts[1])
      } else {
        normalised = text.replacingOccurrences(of: ",", with: ".")
      }
    } else if commas > 0, dots > 0 {
      let lastComma = text.lastIndex(of: ",")!
      let lastDot = text.lastIndex(of: ".")!
      if lastComma > lastDot {
        normalised = text.replacingOccurrences(of: ".", with: "").replacingOccurrences(
          of: ",", with: ".")
      } else {
        normalised = text.replacingOccurrences(of: ",", with: "")
      }
    } else if commas > 1 {
      normalised = text.replacingOccurrences(of: ",", with: "")
    } else if dots > 1 {
      normalised = text.replacingOccurrences(of: ".", with: "")
    }
    let pieces = normalised.split(separator: ".", omittingEmptySubsequences: false)
    guard pieces.count <= 2, pieces.allSatisfy({ $0.allSatisfy(\.isNumber) }),
      !(pieces.first?.isEmpty ?? true) || pieces.count == 2
    else { return nil }
    return Decimal(string: normalised, locale: Locale(identifier: "en_US_POSIX"))
  }

  private static let symbols: [Character: CurrencyCode] = [
    "₽": .rub, "$": .usd, "€": .eur, "£": CurrencyCode("GBP"), "₸": CurrencyCode("KZT"),
    "₴": CurrencyCode("UAH"), "₺": CurrencyCode("TRY"), "₾": CurrencyCode("GEL"),
    "֏": CurrencyCode("AMD"), "¥": CurrencyCode("CNY"),
  ]

  /// A word that names a currency: an ISO code or the Russian «руб».
  public static func word(_ text: String) -> CurrencyCode? {
    let folded = NameKey.fold(text).trimmingCharacters(in: CharacterSet(charactersIn: "."))
    switch folded {
    case "р", "руб", "рубль", "рубля", "рублей", "rub", "rur": return .rub
    case "usd", "долл": return .usd
    case "eur", "евро": return .eur
    default:
      let upper = text.uppercased()
      guard upper.count == 3, upper.allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }
      return CurrencyCode(upper)
    }
  }
}
