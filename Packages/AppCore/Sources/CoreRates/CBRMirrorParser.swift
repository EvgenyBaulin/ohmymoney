import CoreKit
import Foundation

/// Reader for the fallback source `https://www.cbr-xml-daily.ru/daily_json.js`, used only
/// when the Bank of Russia itself is unreachable.
///
/// The mirror republishes the same numbers as JSON: a timestamp with an offset, then a
/// `Valute` object keyed by ISO code. Its values are written as JSON numbers, so they are
/// read from the document text and handed straight to `Decimal` — no binary floating point
/// ever touches a rate. Rates carry `source = .cbrMirror`, which ranks below `.cbr` when
/// snapshots are merged.
public enum CBRMirrorParser {
  public static func parse(_ data: Data, source: RateSource = .cbrMirror) throws -> RateSnapshot {
    let document = try RawJSON.parse(data)
    guard let root = document.objectValue else {
      throw CoreError.malformedExpression(position: 0)
    }
    guard let written = root["Date"]?.stringValue else { throw CoreError.invalidDate }
    let day = try moscowDay(fromTimestamp: written)

    guard let valutes = root["Valute"]?.objectValue else {
      throw CoreError.malformedExpression(position: 0)
    }
    var rates: [CurrencyCode: Rate] = [:]
    for (key, entry) in valutes {
      guard let fields = entry.objectValue else {
        throw CoreError.malformedExpression(position: 0)
      }
      let code = fields["CharCode"]?.stringValue ?? key
      guard !code.isEmpty else { throw CoreError.malformedExpression(position: 0) }
      // As in the bank's own feed, a rate of zero or less is refused rather than applied.
      guard let rubPerNominal = fields["Value"]?.decimalValue, rubPerNominal > 0 else {
        throw CoreError.malformedExpression(position: 0)
      }
      // The value is quoted per `Nominal` units; as in the bank's feed, a nominal that is
      // missing or not a whole number fails the document instead of passing for 1.
      guard let units = fields["Nominal"]?.intValue, units > 0 else {
        throw CoreError.malformedExpression(position: 0)
      }
      let currency = CurrencyCode(code)
      rates[currency] = Rate(
        date: day, currency: currency, rubPerUnit: rubPerNominal, nominal: units, source: source)
    }
    return RateSnapshot(date: day, rates: rates, source: source)
  }

  public static func parse(_ text: String, source: RateSource = .cbrMirror) throws -> RateSnapshot {
    try parse(Data(text.utf8), source: source)
  }

  /// `2026-09-18T11:30:00+03:00` — the instant the mirror published, expressed as the Moscow
  /// day the Bank of Russia dated it. `DateFormatter` is avoided on purpose: its behaviour
  /// depends on the locale and on the platform, and this string never varies.
  static func moscowDay(fromTimestamp text: String) throws -> DateOnly {
    let trimmed = text.trimmed
    let scalars = Array(trimmed)
    guard scalars.count >= 19, scalars[4] == "-", scalars[7] == "-",
      scalars[10] == "T" || scalars[10] == " ", scalars[13] == ":", scalars[16] == ":",
      let year = Int(String(scalars[0..<4])), let month = Int(String(scalars[5..<7])),
      let day = Int(String(scalars[8..<10])), let hour = Int(String(scalars[11..<13])),
      let minute = Int(String(scalars[14..<16])), let second = Int(String(scalars[17..<19]))
    else { throw CoreError.invalidDate }

    let zone = try timeZone(fromSuffix: String(scalars[19...]))
    var parts = DateComponents()
    parts.year = year
    parts.month = month
    parts.day = day
    parts.hour = hour
    parts.minute = minute
    parts.second = second
    parts.timeZone = zone
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    guard let instant = calendar.date(from: parts) else { throw CoreError.invalidDate }
    // `Calendar` happily normalises a thirteenth month, so the components are read back and
    // compared: a timestamp that is not a real instant must be rejected, not rolled over.
    let readBack = calendar.dateComponents(
      [.year, .month, .day, .hour, .minute, .second],
      from: instant)
    guard readBack.year == year, readBack.month == month, readBack.day == day,
      readBack.hour == hour, readBack.minute == minute, readBack.second == second
    else { throw CoreError.invalidDate }
    return CalendarContext.moscow.day(of: instant)
  }

  /// `Z`, `+03:00`, `+0300` or a missing suffix, which means the Moscow zone the feed uses.
  private static func timeZone(fromSuffix suffix: String) throws -> TimeZone {
    var rest = Substring(suffix)
    while let first = rest.first, first == "." || first.isNumber {
      rest = rest.dropFirst()
    }
    if rest.isEmpty { return CalendarContext.moscow.timeZone }
    if rest == "Z" || rest == "z" { return TimeZone(secondsFromGMT: 0)! }
    let sign: Int
    switch rest.first {
    case "+": sign = 1
    case "-": sign = -1
    default: throw CoreError.invalidDate
    }
    let digits = rest.dropFirst().filter { $0.isNumber }
    guard digits.count == 4, let hours = Int(String(digits.prefix(2))),
      let minutes = Int(String(digits.suffix(2))), hours < 24, minutes < 60,
      let zone = TimeZone(secondsFromGMT: sign * (hours * 3600 + minutes * 60))
    else { throw CoreError.invalidDate }
    return zone
  }
}
