import CoreKit
import Foundation

/// Small text and number helpers shared by the statement readers. Everything here is pure
/// Foundation so the whole statement reader builds on Linux as well.
public enum StatementText {
  /// Collapses every run of whitespace (including no-break and narrow no-break spaces) into
  /// one space and trims the ends. Bank texts carry stray double spaces, a leading space and
  /// line breaks inside one field.
  public static func collapse(_ text: String) -> String {
    var result = ""
    var pendingSpace = false
    for scalar in text.unicodeScalars {
      if isSpace(scalar) {
        pendingSpace = !result.isEmpty
      } else {
        if pendingSpace { result.append(" ") }
        pendingSpace = false
        result.unicodeScalars.append(scalar)
      }
    }
    return result
  }

  static func isSpace(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x20, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0xA0, 0x202F, 0x2009, 0x200A, 0x2007: return true
    default: return false
    }
  }

  /// Folds a phrase repeated back to back into one copy: «КИОН Оплата услуг КИОН Оплата
  /// услуг» becomes «КИОН Оплата услуг». Banks duplicate a service name or a message when
  /// they build a long payment text. Comparison ignores case; the first copy is kept.
  public static func collapsingRepeatedPhrase(_ text: String) -> String {
    let words = collapse(text).split(separator: " ").map(String.init)
    guard words.count >= 2 else { return words.joined(separator: " ") }
    let folded = words.map { $0.lowercased() }
    // The longest repeated block wins, so «a b a b» folds to «a b», not to «a b a b».
    var length = words.count / 2
    while length >= 1 {
      var start = 0
      while start + 2 * length <= words.count {
        if Array(folded[start..<start + length])
          == Array(folded[start + length..<start + 2 * length])
        {
          var kept = words
          kept.removeSubrange((start + length)..<(start + 2 * length))
          return collapsingRepeatedPhrase(kept.joined(separator: " "))
        }
        start += 1
      }
      length -= 1
    }
    return words.joined(separator: " ")
  }

  /// Digits of `text` only.
  public static func digits(_ text: String) -> String {
    String(text.unicodeScalars.filter { $0.value >= 0x30 && $0.value <= 0x39 }.map(Character.init))
  }

  /// A phone number reduced to its last ten digits, so «+7 937 914-45-50», «89379144550» and
  /// «79379144550» are one number. Fewer than ten digits stay as they are.
  public static func phoneKey(_ text: String) -> String {
    let all = digits(text)
    return all.count > 10 ? String(all.suffix(10)) : all
  }

  /// A stable 64-bit FNV-1a hash as sixteen hex digits. Not cryptographic and not meant to
  /// be: it only keeps raw bank text out of the stored duplicate key.
  public static func fnv1a(_ text: String) -> String {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in text.utf8 {
      hash ^= UInt64(byte)
      hash = hash &* 0x0000_0100_0000_01B3
    }
    let hex = String(hash, radix: 16)
    return String(repeating: "0", count: 16 - hex.count) + hex
  }
}

/// Reads the money written in bank statements.
public enum StatementAmount {
  private static let signs: [Unicode.Scalar: Bool] = [
    "+": false, "-": true, "\u{2212}": true, "\u{2013}": true, "\u{2014}": true,
  ]

  /// «-3 014.00 ₽», «2 208,50», «-1786,0», «+ 4,88 ₽», «– 5 000 ₽», «162,5». Blanks of every
  /// kind and the currency marks `₽ $ €` are ignored; the sign may be `+ - − – —` with blanks
  /// after it. A lone `.` or `,` is the decimal separator whatever digits follow it (a
  /// statement never groups thousands with a comma), a separator written twice groups
  /// thousands. Anything else — letters, two numbers, no digits — is `nil`, never a guess.
  public static func parse(_ text: String) -> AmountE4? {
    var negative = false
    var sawSign = false
    var body = ""
    for scalar in text.unicodeScalars {
      if StatementText.isSpace(scalar) { continue }
      if let isMinus = signs[scalar], body.isEmpty, !sawSign {
        negative = isMinus
        sawSign = true
        continue
      }
      switch scalar {
      case "₽", "$", "€": continue
      case "0"..."9", ".", ",": body.unicodeScalars.append(scalar)
      default: return nil
      }
    }
    guard !body.isEmpty, let decimal = DecimalMath.parse(body) else { return nil }
    return try? AmountE4(decimal: negative ? -decimal : decimal)
  }

  /// The currency a mark stands for; `nil` for text that is not a known mark.
  public static func currency(forMark mark: String) -> CurrencyCode? {
    switch mark.trimmingCharacters(in: .whitespaces) {
    case "₽", "руб", "руб.", "RUB": return .rub
    case "$", "USD": return .usd
    case "€", "EUR": return .eur
    default: return nil
    }
  }

  /// Repairs the typical slips of character recognition inside one amount field and returns
  /// the amount only if the repaired text reads as a number: `O`/`о` for 0, `l`/`I`/`|` for 1,
  /// `S` for 5, a trailing `Р`/`P` for the rouble sign, and a blank torn in front of the
  /// decimal point («3 014 .00»). A lost minus sign cannot be repaired and is not guessed.
  public static func parseRepairingRecognition(_ text: String) -> AmountE4? {
    if let direct = parse(text) { return direct }
    var repaired = ""
    for scalar in text.unicodeScalars {
      switch scalar {
      case "O", "o", "О", "о": repaired.append("0")
      case "l", "I", "|": repaired.append("1")
      case "S": repaired.append("5")
      case "Р", "P": repaired.append("₽")
      default: repaired.unicodeScalars.append(scalar)
      }
    }
    // Blanks in front of a separator are noise, blanks between digit groups are thousands.
    var tight = ""
    var pending = ""
    for character in repaired {
      if character == " " {
        pending.append(character)
      } else {
        if (character == "." || character == ",") == false { tight += pending }
        pending = ""
        tight.append(character)
      }
    }
    return parse(tight)
  }
}

/// Calendar arithmetic that needs no calendar object: the statements carry local dates and
/// times of the bank, and the time zone belongs to the bank profile, not to the machine.
enum StatementCivil {
  /// Days since 1970-01-01 of a proleptic Gregorian date (Hinnant's algorithm).
  static func dayNumber(_ date: DateOnly) -> Int {
    let y = date.month <= 2 ? date.year - 1 : date.year
    let era = (y >= 0 ? y : y - 399) / 400
    let yoe = y - era * 400
    let mp = (date.month + 9) % 12
    let doy = (153 * mp + 2) / 5 + date.day - 1
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
    return era * 146_097 + doe - 719_468
  }

  static func date(dayNumber z0: Int) -> DateOnly {
    let z = z0 + 719_468
    let era = (z >= 0 ? z : z - 146_096) / 146_097
    let doe = z - era * 146_097
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
    let y = yoe + era * 400
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
    let mp = (5 * doy + 2) / 153
    let d = doy - (153 * mp + 2) / 5 + 1
    let m = mp < 10 ? mp + 3 : mp - 9
    return DateOnly(year: m <= 2 ? y + 1 : y, month: m, day: d)
  }

  static func isValid(_ date: DateOnly) -> Bool {
    guard (1...12).contains(date.month), date.day >= 1, date.year >= 1900, date.year <= 2200
    else { return false }
    return Self.date(dayNumber: dayNumber(date)) == date
  }
}

/// Decodes the bytes of a statement file. Banks send UTF-8 (with or without a byte-order
/// mark); an older export may be windows-1251, which is tried only when the bytes are not
/// valid UTF-8 and is reported so the preview can say so.
public enum StatementTextDecoder {
  public struct Decoded: Sendable, Equatable {
    public var text: String
    public var usedLegacyEncoding: Bool
  }

  public static func decode(_ data: Data) -> Decoded {
    var bytes = [UInt8](data)
    if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF {
      bytes.removeFirst(3)
    }
    if let text = String(validating: bytes, as: UTF8.self) {
      return Decoded(text: text, usedLegacyEncoding: false)
    }
    var scalars = String.UnicodeScalarView()
    for byte in bytes {
      scalars.append(Unicode.Scalar(cp1251Table[Int(byte)]) ?? Unicode.Scalar(0xFFFD)!)
    }
    return Decoded(text: String(scalars), usedLegacyEncoding: true)
  }

  /// windows-1251 beyond ASCII (bytes 0x80...0xFF). `CoreCSV` stands on `CoreKit` alone, so
  /// the table is repeated here instead of depending on the rates target.
  private static let cp1251Table: [UInt32] = {
    var table = (0..<128).map { UInt32($0) }
    table += [
      0x0402, 0x0403, 0x201A, 0x0453, 0x201E, 0x2026, 0x2020, 0x2021,
      0x20AC, 0x2030, 0x0409, 0x2039, 0x040A, 0x040C, 0x040B, 0x040F,
      0x0452, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
      0xFFFD, 0x2122, 0x0459, 0x203A, 0x045A, 0x045C, 0x045B, 0x045F,
      0x00A0, 0x040E, 0x045E, 0x0408, 0x00A4, 0x0490, 0x00A6, 0x00A7,
      0x0401, 0x00A9, 0x0404, 0x00AB, 0x00AC, 0x00AD, 0x00AE, 0x0407,
      0x00B0, 0x00B1, 0x0406, 0x0456, 0x0491, 0x00B5, 0x00B6, 0x00B7,
      0x0451, 0x2116, 0x0454, 0x00BB, 0x0458, 0x0405, 0x0455, 0x0457,
    ]
    table += (0x0410...0x044F).map { UInt32($0) }
    return table
  }()
}

/// Splits delimited text (`;` for the banks seen so far) into rows of fields. Quotes open a
/// quoted field only at the start of a field, so a stray `"` inside an unquoted value (an
/// inch mark in a shop name) stays text. `\n`, `\r\n` and `\r` all end a row, blank rows are
/// dropped, and a doubled quote inside a quoted field is one quote.
public enum StatementDelimitedReader {
  public static func rows(in text: String, delimiter: Unicode.Scalar) -> [[String]] {
    var rows: [[String]] = []
    var row: [String] = []
    var field = String.UnicodeScalarView()
    var inQuotes = false
    var fieldStarted = false
    var wasQuoted = false
    var scalars = text.unicodeScalars[...]

    func endField() {
      row.append(String(field))
      field = String.UnicodeScalarView()
      fieldStarted = false
      wasQuoted = false
    }
    func endRow() {
      if row.isEmpty && field.isEmpty && !wasQuoted { return }
      endField()
      rows.append(row)
      row = []
    }

    while let scalar = scalars.popFirst() {
      if inQuotes {
        if scalar == "\"" {
          if scalars.first == "\"" {
            scalars.removeFirst()
            field.append("\"")
          } else {
            inQuotes = false
          }
        } else {
          field.append(scalar)
        }
        continue
      }
      switch scalar {
      case "\"" where !fieldStarted:
        inQuotes = true
        wasQuoted = true
        fieldStarted = true
      case delimiter:
        endField()
      case "\n":
        endRow()
      case "\r":
        if scalars.first == "\n" { scalars.removeFirst() }
        endRow()
      default:
        fieldStarted = true
        field.append(scalar)
      }
    }
    if !field.isEmpty || !row.isEmpty || wasQuoted { endRow() }
    return rows
  }
}
