import Foundation

/// Rubles for one unit of a currency on one day.
public struct DayRate: Hashable, Sendable {
  public var day: DateOnly
  /// Rubles for ONE unit, the nominal already applied (100 KZT are quoted, one is kept here).
  public var perUnit: Decimal

  public init(day: DateOnly, perUnit: Decimal) {
    self.day = day
    self.perUnit = perUnit
  }
}

/// The rates of the Bank of Russia by day, for the rules that convert a figure for display or
/// prefill one — with the rates passed in, so they need no access to the cache. Built from
/// the rate for one unit (`Rate.perUnit`), never from the rate as quoted per nominal.
public struct DayRates: Hashable, Sendable {
  private let series: [CurrencyCode: [DayRate]]

  /// Each currency's rates are sorted by day here; the order they come in does not matter.
  public init(series: [CurrencyCode: [DayRate]]) {
    self.series = series.mapValues { $0.sorted { $0.day < $1.day } }
  }

  public static let empty = DayRates(series: [:])

  /// Rubles for one unit on `day`: 1 for the ruble; otherwise the rate of the nearest day on
  /// or before it; before every rate known, the first one — a day earlier than the cache is
  /// best served by the closest rate there is; `nil` when the currency has none.
  public func perUnit(_ currency: CurrencyCode, on day: DateOnly) -> Decimal? {
    guard currency != .rub else { return 1 }
    guard let rates = series[currency], let first = rates.first else { return nil }
    var low = 0
    var high = rates.count
    // The first index whose day is after `day`.
    while low < high {
      let middle = (low + high) / 2
      if rates[middle].day <= day { low = middle + 1 } else { high = middle }
    }
    return low == 0 ? first.perUnit : rates[low - 1].perUnit
  }
}
