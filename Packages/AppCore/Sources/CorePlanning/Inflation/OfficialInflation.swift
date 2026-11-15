import Foundation

/// The official consumer price index of Russia, month by month. The app carries the table
/// (`builtIn`) and renews it with each release; nothing is fetched. A month the table does not
/// hold has no figure: the answer is `nil`, never zero.
public struct OfficialInflation: Hashable, Sendable {
  /// One month: the index to the end of the previous month, 100 meaning no change, so 101.62
  /// is a rise of 1.62 %. Kept as `Decimal`, read from text.
  public struct Month: Hashable, Sendable {
    public var year: Int
    public var month: Int
    public var index: Decimal

    public init(year: Int, month: Int, index: Decimal) {
      self.year = year
      self.month = month
      self.index = index
    }

    fileprivate var serial: Int { year * 12 + (month - 1) }
  }

  /// Oldest first, one row a month.
  public let months: [Month]
  private let bySerial: [Int: Decimal]

  public init(months: [Month]) {
    var unique: [Int: Month] = [:]
    for m in months where (1...12).contains(m.month) { unique[m.serial] = m }
    self.months = unique.values.sorted { $0.serial < $1.serial }
    self.bySerial = unique.mapValues(\.index)
  }

  /// The newest month the table holds.
  public var latest: Month? { months.last }

  /// The change over one month in percent (1.62 is 1.62 %); `nil` when the month is not held.
  public func monthlyPercent(year: Int, month: Int) -> Decimal? {
    guard (1...12).contains(month), let index = bySerial[year * 12 + (month - 1)] else {
      return nil
    }
    return index - 100
  }

  /// The change over the twelve months ending with `month`, in percent; `nil` unless all
  /// twelve are held.
  public func yearOnYearPercent(year: Int, month: Int) -> Decimal? {
    guard (1...12).contains(month) else { return nil }
    return cumulativePercent(fromYear: year - 1, month: month, throughYear: year, month: month)
  }

  /// The change accumulated after the end of the start month through the end of the last month,
  /// in percent: the months are multiplied, not added. The same month twice is zero; a start
  /// after the end, or a month missing in between, gives `nil`.
  public func cumulativePercent(
    fromYear: Int, month fromMonth: Int, throughYear: Int, month throughMonth: Int
  ) -> Decimal? {
    guard (1...12).contains(fromMonth), (1...12).contains(throughMonth) else { return nil }
    let start = fromYear * 12 + (fromMonth - 1)
    let end = throughYear * 12 + (throughMonth - 1)
    guard start <= end else { return nil }
    var factor = Decimal(1)
    var serial = start + 1
    while serial <= end {
      guard let index = bySerial[serial] else { return nil }
      factor *= index / 100
      serial += 1
    }
    return (factor - 1) * 100
  }

  /// Rosstat, «Индексы потребительских цен на товары и услуги по Российской Федерации»
  /// (`ipc_mes_09-2026.xlsx`, sheet 01), read 15.11.2026; the last month is September 2026.
  /// Twelve indexes a row, January first.
  public static let builtIn: OfficialInflation = {
    let rows: [(Int, [String])] = [
      (2020, ["100.40", "100.33", "100.55", "100.83", "100.27", "100.22",
              "100.35", "99.96", "99.93", "100.43", "100.71", "100.83"]),
      (2021, ["100.67", "100.78", "100.66", "100.58", "100.74", "100.69",
              "100.31", "100.17", "100.60", "101.11", "100.96", "100.82"]),
      (2022, ["100.99", "101.17", "107.61", "101.56", "100.12", "99.65",
              "99.61", "99.48", "100.05", "100.18", "100.37", "100.78"]),
      (2023, ["100.84", "100.46", "100.37", "100.38", "100.31", "100.37",
              "100.63", "100.28", "100.87", "100.83", "101.11", "100.73"]),
      (2024, ["100.86", "100.68", "100.39", "100.50", "100.74", "100.64",
              "101.14", "100.20", "100.48", "100.75", "101.43", "101.32"]),
      (2025, ["101.23", "100.81", "100.65", "100.40", "100.43", "100.20",
              "100.57", "99.60", "100.34", "100.50", "100.42", "100.32"]),
      (2026, ["101.62", "100.73", "100.60", "100.14", "100.17", "100.87",
              "100.54", "99.92", "100.35"]),
    ]
    let posix = Locale(identifier: "en_US_POSIX")
    var months: [Month] = []
    for (year, values) in rows {
      for (offset, text) in values.enumerated() {
        if let index = Decimal(string: text, locale: posix) {
          months.append(Month(year: year, month: offset + 1, index: index))
        }
      }
    }
    return OfficialInflation(months: months)
  }()
}
