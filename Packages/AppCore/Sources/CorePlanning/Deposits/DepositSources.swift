import CoreKit
import Foundation

/// The figure the Bank of Russia publishes on https://www.cbr.ru/statistics/avgprocstav/: the
/// average of the highest rates on rouble deposits of the ten banks that take the most deposits
/// of individuals, for a ten-day period. It is a mark of the market, not a rate of any bank.
public struct CentralBankIndicator: Codable, Hashable, Sendable {
  public var ratePercent: Decimal
  /// 1, 2 or 3: the first, second or last ten days of the month.
  public var decade: Int
  public var month: Int
  public var year: Int

  public init(ratePercent: Decimal, decade: Int, month: Int, year: Int) {
    self.ratePercent = ratePercent
    self.decade = decade
    self.month = month
    self.year = year
  }

  /// The first day of the period; the third decade runs to the end of the month.
  public var periodStart: DateOnly {
    Self.start(decade: decade, month: month, year: year) ?? DateOnly(year: year, month: 1, day: 1)
  }

  public static func start(decade: Int, month: Int, year: Int) -> DateOnly? {
    guard (1...3).contains(decade), (1...12).contains(month), year > 1990, year < 2200 else {
      return nil
    }
    return DateOnly(year: year, month: month, day: [1, 11, 21][decade - 1])
  }
}

/// Reads the table of ten-day periods of that page: rows of «II.10.2026» and «13,0550». A row
/// that cannot be read is skipped; a page with nothing readable gives an empty list, which callers
/// treat as «could not update».
public struct CentralBankDepositParser: Sendable {
  public init() {}

  /// Every readable row, the newest period first.
  public func parse(_ data: Data) -> [CentralBankIndicator] {
    guard let text = String(data: data, encoding: .utf8),
      let open = text.range(of: "<table class=\"data\"")
    else { return [] }
    let table = text[open.upperBound...].components(separatedBy: "</table>")[0]
    var rows: [CentralBankIndicator] = []
    for row in table.components(separatedBy: "<tr").dropFirst() {
      let cells = row.components(separatedBy: "<td").dropFirst().map { cell -> String in
        let body = cell.drop { $0 != ">" }.dropFirst()
        return String(body.prefix { $0 != "<" }).trimmingCharacters(in: .whitespacesAndNewlines)
      }
      guard cells.count >= 2, let row = Self.row(period: cells[0], rate: cells[1]) else { continue }
      rows.append(row)
    }
    return rows.sorted { $0.periodStart > $1.periodStart }
  }

  /// The newest period of the page.
  public func latest(_ data: Data) -> CentralBankIndicator? { parse(data).first }

  static func row(period: String, rate: String) -> CentralBankIndicator? {
    let parts = period.split(separator: ".").map(String.init)
    guard parts.count == 3, let decade = ["I": 1, "II": 2, "III": 3][parts[0]],
      let month = Int(parts[1]), let year = Int(parts[2]),
      CentralBankIndicator.start(decade: decade, month: month, year: year) != nil,
      let percent = Decimal(
        string: rate.replacingOccurrences(of: ",", with: "."),
        locale: Locale(identifier: "en_US_POSIX")),
      percent > 0, percent < 100
    else { return nil }
    return CentralBankIndicator(ratePercent: percent, decade: decade, month: month, year: year)
  }
}

/// The last answer of the Bank of Russia with its day; `indicator` is `nil` for a failed attempt,
/// kept so the page is not asked again the same day.
public struct CentralBankCache: Codable, Hashable, Sendable {
  public var day: DateOnly
  public var indicator: CentralBankIndicator?

  public init(day: DateOnly, indicator: CentralBankIndicator?) {
    self.day = day
    self.indicator = indicator
  }

  public static func isDue(_ cache: CentralBankCache?, today: DateOnly) -> Bool {
    guard let cache else { return true }
    return cache.day != today
  }
}

/// Two sources naming different rates for one bank.
public struct DepositDiscrepancy: Hashable, Sendable {
  public var bankName: String
  public var lower: DepositShowcaseEntry
  public var higher: DepositShowcaseEntry

  /// In percentage points, always positive.
  public var difference: Decimal { (higher.ratePercent ?? 0) - (lower.ratePercent ?? 0) }
}

extension DepositShowcase {
  /// Rates of the same bank differ by more than this many percentage points: worth a look.
  public static let discrepancyThreshold = Decimal(string: "0.1")!

  /// Banks for which two different sources name rates that differ by more than the threshold,
  /// by `bankKey`. Per source and bank the best rate counts (a bank has several products, and two
  /// products of one source are no disagreement); entries without a rate, and ones whose terms do
  /// not meet, are not compared. For a bank with more than two sources the widest gap is kept.
  public static func discrepancies(
    _ entries: [DepositShowcaseEntry]
  ) -> [String: DepositDiscrepancy] {
    var best: [String: [String: DepositShowcaseEntry]] = [:]
    for entry in entries {
      guard let rate = entry.ratePercent else { continue }
      let bank = bankKey(entry.bankName)
      let source = sourceKey(entry.origin)
      if let old = best[bank]?[source]?.ratePercent, old >= rate { continue }
      best[bank, default: [:]][source] = entry
    }
    var found: [String: DepositDiscrepancy] = [:]
    for (bank, sources) in best {
      let list = sources.sorted { $0.key < $1.key }.map(\.value)
      for (index, left) in list.enumerated() {
        for right in list.dropFirst(index + 1) {
          guard termsMeet(left, right), let a = left.ratePercent, let b = right.ratePercent,
            abs(a - b) > discrepancyThreshold
          else { continue }
          let pair = DepositDiscrepancy(
            bankName: left.bankName, lower: a < b ? left : right, higher: a < b ? right : left)
          if pair.difference > (found[bank]?.difference ?? 0) { found[bank] = pair }
        }
      }
    }
    return found
  }

  private static func sourceKey(_ origin: DepositShowcaseEntry.Origin) -> String {
    switch origin {
    case .builtIn: "builtIn"
    case .bankiRu: "bankiRu"
    case .centralBank: "centralBank"
    case .aggregator(let name): "aggregator:\(name)"
    case .own: "own"
    }
  }

  /// Whether the term ranges of two entries share a month; an unstated bound is open.
  private static func termsMeet(_ a: DepositShowcaseEntry, _ b: DepositShowcaseEntry) -> Bool {
    let low = max(a.termMinMonths ?? 0, b.termMinMonths ?? 0)
    let high = min(a.termMaxMonths ?? .max, b.termMaxMonths ?? .max)
    return low <= high
  }
}
