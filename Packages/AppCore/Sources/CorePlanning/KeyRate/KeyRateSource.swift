import CoreKit
import Foundation

/// Reads the table of the key rate of the Bank of Russia (the page «Ключевая ставка Банка
/// России»): rows of a day «14.11.2025» and a rate «16,00». A row that cannot be read is skipped;
/// a page with nothing readable gives an empty list, which callers treat as «could not update»,
/// never as «the rate did not change».
public struct KeyRatePageParser: Sendable {
  public init() {}

  /// The days the rate changed, oldest first: a row with the rate of the row before it is no
  /// change.
  public func parse(_ data: Data) -> [KeyRateChange] {
    guard let text = String(data: data, encoding: .utf8) else { return [] }
    var rows: [KeyRateChange] = []
    for row in text.components(separatedBy: "<tr").dropFirst() {
      let cells = row.components(separatedBy: "<td").dropFirst().map { cell -> String in
        let body = cell.drop { $0 != ">" }.dropFirst()
        return String(body.prefix { $0 != "<" }).trimmingCharacters(in: .whitespacesAndNewlines)
      }
      guard cells.count >= 2, let change = Self.row(day: cells[0], rate: cells[1]) else {
        continue
      }
      rows.append(change)
    }
    return KeyRateTable(changes: rows).changes
  }

  /// «14.11.2025» and «16,50» as a row; `nil` for anything else or a rate that is not a sane
  /// percent.
  static func row(day: String, rate: String) -> KeyRateChange? {
    let parts = day.split(separator: ".").compactMap { Int($0) }
    let text = rate.replacingOccurrences(of: ",", with: ".")
      .replacingOccurrences(of: "\u{00A0}", with: "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard parts.count == 3, (1...31).contains(parts[0]), (1...12).contains(parts[1]),
      (1991..<2200).contains(parts[2]),
      let percent = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")),
      percent > 0, percent < 100
    else { return nil }
    return KeyRateChange(
      effectiveOn: DateOnly(year: parts[2], month: parts[1], day: parts[0]), ratePercent: percent)
  }
}

/// Once a day at most: the rows of the last attempt with the day it was made, kept so a restart
/// does not ask again. A failed attempt is kept too (empty `changes`) so the page is not hammered.
public struct KeyRateCache: Codable, Hashable, Sendable {
  public var day: DateOnly
  public var changes: [KeyRateChange]

  public init(day: DateOnly, changes: [KeyRateChange]) {
    self.day = day
    self.changes = changes
  }

  public static func isDue(_ cache: KeyRateCache?, today: DateOnly) -> Bool {
    guard let cache else { return true }
    return cache.day != today
  }
}
