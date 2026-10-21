import CoreKit
import Foundation

/// Reader for the daily XML of the Bank of Russia
/// (`https://www.cbr.ru/scripts/XML_daily.asp?date_req=dd/MM/yyyy`).
///
/// The document is a flat list of `Valute` elements inside a `ValCurs` root whose `Date`
/// attribute carries the publication day in `dd.MM.yyyy`, read in the Moscow time zone where
/// the bank publishes. Values use a decimal comma and are quoted per `Nominal` units — 1, 10
/// or 100 — which is why `Rate` keeps `rubPerUnit` and `nominal` exactly as written and
/// divides only in `Rate.perUnit`.
///
/// Downloading lives in the app layer (`RatesFetching`); this type only turns bytes into a
/// `RateSnapshot`, so it stays testable without a network.
///
/// A document that is broken as a whole — not XML, another root, no date — fails. One
/// currency that is broken in it — a value or a nominal that cannot be read, a unit rate
/// that contradicts them — is left out of the day and named in `Reading.rejected`, for the
/// journal: a past day's document never changes, and refusing all of it would leave every
/// currency of that day without a rate for good. A document with nothing usable fails.
public enum CBRDocumentParser {
  static let rootElement = "ValCurs"

  /// What one document gave: the rates it holds, and the currencies left out as broken.
  public struct Reading: Sendable, Equatable {
    public let snapshot: RateSnapshot
    public let rejected: [CurrencyCode]
  }

  public static func parse(_ data: Data, source: RateSource = .cbr) throws -> RateSnapshot {
    try read(data, source: source).snapshot
  }

  public static func parse(_ text: String, source: RateSource = .cbr) throws -> RateSnapshot {
    try read(text, source: source).snapshot
  }

  public static func read(_ data: Data, source: RateSource = .cbr) throws -> Reading {
    try read(decode(data), source: source)
  }

  public static func read(_ text: String, source: RateSource = .cbr) throws -> Reading {
    var scanner = XMLTagScanner(text)
    var stack: [String] = []
    var day: DateOnly?
    var rates: [CurrencyCode: Rate] = [:]
    var rejected: [CurrencyCode] = []
    var record = ValuteRecord()
    var field: String?
    var buffer = ""

    while let event = try scanner.next() {
      switch event {
      case .start(let name, let attributes, let isSelfClosing):
        if stack.isEmpty {
          guard name == rootElement else {
            throw CoreError.malformedExpression(position: scanner.position)
          }
          guard let written = attributes["Date"] else {
            throw CoreError.invalidDate
          }
          day = try documentDay(written)
        } else if name == "Valute" {
          record = ValuteRecord()
        } else if stack.count >= 2 {
          field = name
          buffer = ""
        }
        if isSelfClosing {
          if let closing = field, closing == name {
            record.set(field: closing, value: "")
            field = nil
          }
        } else {
          stack.append(name)
        }

      case .text(let chunk):
        if field != nil { buffer += chunk }

      case .end(let name):
        guard let open = stack.popLast(), open == name else {
          throw CoreError.malformedExpression(position: scanner.position)
        }
        if let closing = field, closing == name {
          record.set(field: closing, value: buffer.trimmed)
          field = nil
          buffer = ""
        } else if name == "Valute" {
          guard let publicationDay = day else { throw CoreError.invalidDate }
          do {
            if let rate = try record.rate(on: publicationDay, source: source, at: scanner.position)
            {
              rates[rate.currency] = rate
            }
          } catch {
            rejected.append(CurrencyCode(record.charCode ?? ""))
          }
          record = ValuteRecord()
        }
      }
    }

    guard stack.isEmpty else { throw CoreError.malformedExpression(position: scanner.position) }
    guard let publicationDay = day else { throw CoreError.invalidDate }
    guard !rates.isEmpty || rejected.isEmpty else {
      throw CoreError.malformedExpression(position: scanner.position)
    }
    return Reading(
      snapshot: RateSnapshot(date: publicationDay, rates: rates, source: source),
      rejected: rejected)
  }

  // MARK: - Encoding

  /// Turns the response bytes into text. The feed declares `windows-1251`; the declaration
  /// itself is ASCII, so it can be read before the encoding is known. Anything else is
  /// treated as UTF-8 when the bytes are valid UTF-8, and as windows-1251 otherwise.
  static func decode(_ data: Data) -> String {
    if data.starts(with: [0xEF, 0xBB, 0xBF]) {
      return String(decoding: data.dropFirst(3), as: UTF8.self)
    }
    let declared = declaredEncoding(in: data)
    if let declared, declared.contains("1251") {
      return CP1251.decode(data)
    }
    if let utf8 = String(data: data, encoding: .utf8) {
      return utf8
    }
    return CP1251.decode(data)
  }

  /// Lowercased value of `encoding="…"` in the XML declaration, if the document has one.
  private static func declaredEncoding(in data: Data) -> String? {
    let prefix = Array(data.prefix(256)).map { CP1251.scalar(for: $0) }
    let header = String(String.UnicodeScalarView(prefix)).lowercased()
    guard let marker = header.range(of: "encoding=") else { return nil }
    let rest = header[marker.upperBound...]
    guard let quote = rest.first, quote == "\"" || quote == "'" else { return nil }
    let body = rest.dropFirst()
    guard let end = body.firstIndex(of: quote) else { return nil }
    return String(body[body.startIndex..<end])
  }

  // MARK: - Date

  /// `dd.MM.yyyy` as published, validated against the Moscow calendar so that a day the
  /// month does not have is rejected instead of silently wrapping.
  static func documentDay(_ written: String) throws -> DateOnly {
    let parts = written.trimmed.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3, parts[0].count == 2, parts[1].count == 2, parts[2].count == 4,
      let dayNumber = Int(parts[0]), let month = Int(parts[1]), let year = Int(parts[2])
    else { throw CoreError.invalidDate }
    let day = DateOnly(year: year, month: month, day: dayNumber)
    let calendar = CalendarContext.moscow
    guard calendar.day(of: calendar.startOfDay(day)) == day else { throw CoreError.invalidDate }
    return day
  }
}

/// One `Valute` element while it is still being read.
private struct ValuteRecord {
  var charCode: String?
  var nominal: String?
  var value: String?
  var unitRate: String?

  mutating func set(field: String, value text: String) {
    switch field {
    case "CharCode": charCode = text
    case "Nominal": nominal = text
    case "Value": value = text
    case "VunitRate": unitRate = text
    default: break
    }
  }

  /// Builds the rate, or returns `nil` when the element carried no code. An element with a
  /// code but a broken number is an error: the document leaves that currency out and names
  /// it, never skips it quietly.
  func rate(on day: DateOnly, source: RateSource, at position: Int) throws -> Rate? {
    guard let charCode, !charCode.isEmpty else { return nil }
    guard let value, let rubPerNominal = DecimalMath.parse(value) else {
      throw CoreError.malformedExpression(position: position)
    }
    // A rate of zero or less is not a rate: taken at face value it would silently turn
    // every amount in that currency into nothing.
    guard rubPerNominal > 0 else { throw CoreError.malformedExpression(position: position) }
    // `Value` is quoted per `Nominal` units. A nominal that is missing or not a whole number
    // is refused like a broken value: read as 1, a rate per 100 yen would pass for a rate
    // per yen.
    guard let nominal, let units = Int(nominal), units > 0 else {
      throw CoreError.malformedExpression(position: position)
    }
    let rate = Rate(
      date: day, currency: CurrencyCode(charCode), rubPerUnit: rubPerNominal, nominal: units,
      source: source)
    if let unitRate {
      try CBRRateCheck.verify(perUnit: rate.perUnit, against: unitRate, at: position)
    }
    return rate
  }
}

/// Cross-check of `Value` / `Nominal` against the `VunitRate` the feed also publishes.
enum CBRRateCheck {
  /// `VunitRate` is the per-unit rate rounded to however many digits the feed decided to
  /// print, so the comparison rounds to the same number of digits and tolerates one unit in
  /// the last printed place. A wider gap means the two numbers disagree and the document is
  /// not trustworthy.
  static func verify(perUnit: Decimal, against written: String, at position: Int) throws {
    guard let declared = DecimalMath.parse(written) else {
      throw CoreError.malformedExpression(position: position)
    }
    let scale = fractionDigits(of: written)
    let rounded = DecimalMath.round(perUnit, scale: scale)
    let tolerance = Decimal(sign: .plus, exponent: -scale, significand: 1)
    guard (rounded - declared).magnitude <= tolerance else {
      throw CoreError.malformedExpression(position: position)
    }
  }

  static func fractionDigits(of written: String) -> Int {
    guard let separator = written.lastIndex(where: { $0 == "," || $0 == "." }) else { return 0 }
    return written[written.index(after: separator)...].filter { $0.isNumber }.count
  }
}

extension String {
  /// Trimming without `Foundation.CharacterSet`, which differs subtly across platforms.
  var trimmed: String {
    var view = Substring(self)
    while let first = view.first, first.isWhitespace || first.isNewline {
      view = view.dropFirst()
    }
    while let last = view.last, last.isWhitespace || last.isNewline {
      view = view.dropLast()
    }
    return String(view)
  }
}
