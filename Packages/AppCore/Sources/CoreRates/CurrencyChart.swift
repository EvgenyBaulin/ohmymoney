import CoreKit
import Foundation

/// The tile «График валюты»: a pair of currencies over a week, a month or a year, from the rates
/// of the Bank of Russia the app keeps anyway. The days asked are few — one per day of a week,
/// about every third day of a month, one a month of a year — and each is the bank's daily table,
/// cached like every other day. Nothing but those tables goes to the network.
public enum CurrencyChartPeriod: String, CaseIterable, Sendable, Codable {
  case week, month, year
}

/// «USD/RUB»: how many units of `quote` one unit of `base` costs.
public struct CurrencyPair: Hashable, Sendable, Codable, CustomStringConvertible {
  public var base: CurrencyCode
  public var quote: CurrencyCode

  public init(base: CurrencyCode, quote: CurrencyCode) {
    self.base = base
    self.quote = quote
  }

  /// «USD/RUB»; nil for anything else or a pair of one currency.
  public init?(_ text: String) {
    let codes = text.split(separator: "/").map { String($0).trimmingCharacters(in: .whitespaces) }
    guard codes.count == 2, codes[0].count == 3, codes[1].count == 3, codes[0] != codes[1] else {
      return nil
    }
    self.init(base: CurrencyCode(codes[0].uppercased()), quote: CurrencyCode(codes[1].uppercased()))
  }

  public var description: String { "\(base)/\(quote)" }
}

/// One point: the rate of the pair on a day, in 1/10000 of the quote.
public struct CurrencyChartPoint: Hashable, Sendable, Identifiable {
  public var day: DateOnly
  public var rateE4: Int64
  public var id: String { day.iso }

  public init(day: DateOnly, rateE4: Int64) {
    self.day = day
    self.rateE4 = rateE4
  }
}

public enum CurrencyChart {
  /// The pairs offered: USD/RUB and EUR/RUB, then each currency of the accounts against the
  /// default currency (and against the ruble when the default is another), in that order, each
  /// once.
  public static func pairs(
    accountCurrencies: [CurrencyCode], defaultCurrency: CurrencyCode
  ) -> [CurrencyPair] {
    var pairs = [
      CurrencyPair(base: .usd, quote: .rub), CurrencyPair(base: .eur, quote: .rub),
    ]
    for currency in accountCurrencies {
      for quote in [defaultCurrency, .rub] where quote != currency {
        let pair = CurrencyPair(base: currency, quote: quote)
        if !pairs.contains(pair) { pairs.append(pair) }
      }
    }
    return pairs
  }

  /// The days asked for, oldest first, `today` last.
  public static func days(
    _ period: CurrencyChartPeriod, today: DateOnly, calendar: CalendarContext
  ) -> [DateOnly] {
    let (count, step): (Int, Int) =
      switch period {
      case .week: (7, 1)
      case .month: (11, 3)
      case .year: (13, 30)
      }
    return (0..<count).reversed().map { calendar.adding(days: -$0 * step, to: today) }
  }

  /// The rate of the pair from the rubles per unit of each side (a ruble side is 1); nil when a
  /// side has no rate.
  public static func rateE4(
    of pair: CurrencyPair, basePerRub: Decimal?, quotePerRub: Decimal?
  ) -> Int64? {
    let base = pair.base == .rub ? 1 : basePerRub
    let quote = pair.quote == .rub ? 1 : quotePerRub
    guard let base, let quote, base > 0, quote > 0 else { return nil }
    let value = DecimalMath.round(base / quote * 10_000, scale: 0)
    return Int64(truncating: value as NSDecimalNumber)
  }

  /// The points of the pair on `days`, in their order. `rate` gives the rubles per unit of a
  /// currency on a day — for a day the bank published nothing, the publication that stands that
  /// day — and is never asked about the ruble. A day a side has no rate of is left out. Nil when
  /// the task was cancelled on the way.
  public static func points(
    of pair: CurrencyPair, on days: [DateOnly],
    rate: @Sendable (CurrencyCode, DateOnly) async -> Decimal?
  ) async -> [CurrencyChartPoint]? {
    var found: [CurrencyChartPoint] = []
    for day in days {
      if Task.isCancelled { return nil }
      let base = pair.base == .rub ? nil : await rate(pair.base, day)
      let quote = pair.quote == .rub ? nil : await rate(pair.quote, day)
      if let value = rateE4(of: pair, basePerRub: base, quotePerRub: quote) {
        found.append(CurrencyChartPoint(day: day, rateE4: value))
      }
    }
    return found
  }

  /// The rate now and its change over the period: the last point against the first. The change
  /// in basis points of the first rate; nil with fewer than two points.
  public static func summary(
    _ points: [CurrencyChartPoint]
  ) -> (
    current: Int64, change: Int64, changeBp: Int
  )? {
    guard let first = points.first, let last = points.last, points.count >= 2, first.rateE4 > 0
    else { return nil }
    let change = last.rateE4 - first.rateE4
    let bp = Decimal(change) * 10_000 / Decimal(first.rateE4)
    return (
      last.rateE4, change, Int(truncating: DecimalMath.round(bp, scale: 0) as NSDecimalNumber)
    )
  }

  /// What the tile keeps on this Mac: «USD/RUB|month».
  public static func decode(_ stored: String?) -> (CurrencyPair, CurrencyChartPeriod) {
    let parts = (stored ?? "").split(separator: "|").map(String.init)
    let pair = parts.first.flatMap(CurrencyPair.init) ?? CurrencyPair(base: .usd, quote: .rub)
    let period = parts.count > 1 ? CurrencyChartPeriod(rawValue: parts[1]) ?? .month : .month
    return (pair, period)
  }

  public static func encode(_ pair: CurrencyPair, _ period: CurrencyChartPeriod) -> String {
    "\(pair)|\(period.rawValue)"
  }
}
