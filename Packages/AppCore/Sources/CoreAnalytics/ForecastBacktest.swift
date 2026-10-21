import CoreKit
import Foundation

/// A backtest of the forecast with a rolling origin, scored by MAE and pinball loss; the
/// result is shown in «Model quality».
///
/// Every day of the last half-year is taken in turn as if it were today: the forecast is made
/// from the history up to that day only, and compared with what the rest of that month
/// actually cost. Nothing after the origin is ever looked at — that is the whole point, and
/// it is why the forecast has to be a function of a day and not of «now».
public struct ForecastBacktest: Hashable, Sendable {
  /// What one way of forecasting scored.
  public struct Metrics: Hashable, Sendable {
    /// Days taken as an origin. Zero means the history is too short to say anything.
    public var origins: Int
    /// Mean absolute error of the middle, in rubles.
    public var mae: AmountE4
    /// The pinball loss of P10, P50 and P90 — what a quantile is actually scored by: being
    /// above the true value costs a tenth as much as being below it, at P10, and nine times
    /// as much at P90.
    public var pinball10: AmountE4
    public var pinball50: AmountE4
    public var pinball90: AmountE4
    /// How often the month landed inside [P10, P90], in basis points. The interval is built
    /// to hold four times out of five, so the target is 8 000.
    public var coverageBp: Int

    public init(
      origins: Int = 0, mae: AmountE4 = .zero, pinball10: AmountE4 = .zero,
      pinball50: AmountE4 = .zero, pinball90: AmountE4 = .zero, coverageBp: Int = 0
    ) {
      self.origins = origins
      self.mae = mae
      self.pinball10 = pinball10
      self.pinball50 = pinball50
      self.pinball90 = pinball90
      self.coverageBp = coverageBp
    }
  }

  public struct Line: Hashable, Sendable {
    public var method: MonthForecast.Method
    public var metrics: Metrics

    public init(method: MonthForecast.Method, metrics: Metrics) {
      self.method = method
      self.metrics = metrics
    }
  }

  /// One line per way of forecasting, in the order of `MonthForecast.Method.allCases`.
  public var lines: [Line]
  /// Days of history the origins were taken from.
  public var days: Int
  /// What a forecast made today would actually use.
  public var chosen: MonthForecast.Method

  public init(lines: [Line] = [], days: Int = 0, chosen: MonthForecast.Method = .rate) {
    self.lines = lines
    self.days = days
    self.chosen = chosen
  }

  public func metrics(of method: MonthForecast.Method) -> Metrics? {
    lines.first { $0.method == method }?.metrics
  }

  /// Nothing was measured: too little history.
  public var isEmpty: Bool { lines.allSatisfy { $0.metrics.origins == 0 } }

  /// The way the app forecasts beat the plain rate it is measured against — what has to be
  /// true for the forecast to be worth its arithmetic.
  public var beatsTheRate: Bool {
    guard let chosen = metrics(of: chosen), let rate = metrics(of: .rate),
      chosen.origins > 0, rate.origins > 0
    else { return false }
    return chosen.mae < rate.mae
  }

  public static let days = 180

  /// The rolling-origin backtest over the last `days` days.
  ///
  /// An origin counts only when every method could have been used on it — the window has to
  /// reach the two months the weekday method needs — so the three lines are scored on exactly
  /// the same days and can be compared at all.
  public static func run(
    ledger: Ledger, today: DateOnly, days: Int = ForecastBacktest.days
  ) -> ForecastBacktest {
    let spending = VariableSpending(ledger: ledger)
    var samples: [MonthForecast.Method: [(forecast: MonthForecast.Remainder, actual: Decimal)]] =
      [:]
    for back in stride(from: days, through: 1, by: -1) {
      let origin = today.adding(days: -back)
      let month = origin.monthKey
      let daysLeft = month.dayCount - origin.day
      guard daysLeft > 0 else { continue }
      // A month that is not over yet has no answer: the days after today hold nothing
      // because they have not happened, and counting them as zeros would make every
      // forecast look far too high. The month that ends today is not over either — today's
      // spending is still being entered, and a run in the morning would score another
      // answer than one in the evening.
      guard month.lastDay < today else { continue }
      let start = max(
        origin.dayNumber - MonthForecast.windowLength, spending.firstDay ?? origin.dayNumber)
      guard origin.dayNumber - start >= MonthForecast.weekdayWindow else { continue }
      // What the rest of that month really cost. The last day of the month is inside it, so
      // a forecast made on the 20th is answered by the 21st through the 30th.
      let actual = spending.sum(
        from: origin.dayNumber + 1, through: month.lastDay.dayNumber)
      for method in MonthForecast.Method.allCases {
        samples[method, default: []].append(
          (spending.remainder(today: origin, method: method), actual))
      }
    }
    let lines = MonthForecast.Method.allCases.map {
      Line(method: $0, metrics: score(samples[$0] ?? []))
    }
    let windowDays = windowDays(of: spending, today: today)
    return ForecastBacktest(
      lines: lines, days: days, chosen: spending.method(windowDays: windowDays))
  }

  private static func windowDays(of spending: VariableSpending, today: DateOnly) -> Int {
    let start = max(
      today.dayNumber - MonthForecast.windowLength, spending.firstDay ?? today.dayNumber)
    return max(0, today.dayNumber - 1 - start + 1)
  }

  static func score(_ samples: [(forecast: MonthForecast.Remainder, actual: Decimal)]) -> Metrics {
    guard !samples.isEmpty else { return Metrics() }
    let count = Decimal(samples.count)
    var absolute = Decimal(0)
    var losses = [Decimal(0), Decimal(0), Decimal(0)]
    var inside = 0
    for sample in samples {
      let middle = sample.forecast.middle.decimal
      let low = sample.forecast.p10.decimal
      let high = sample.forecast.p90.decimal
      absolute += abs(sample.actual - middle)
      for (index, pair) in [
        (Decimal(1) / 10, low), (Decimal(1) / 2, middle), (Decimal(9) / 10, high),
      ]
      .enumerated() {
        losses[index] += pinball(actual: sample.actual, predicted: pair.1, at: pair.0)
      }
      if sample.actual >= low && sample.actual <= high { inside += 1 }
    }
    return Metrics(
      origins: samples.count, mae: AmountE4.rounded(absolute / count),
      pinball10: AmountE4.rounded(losses[0] / count),
      pinball50: AmountE4.rounded(losses[1] / count),
      pinball90: AmountE4.rounded(losses[2] / count),
      coverageBp: Shares.basisPoints(inside, of: samples.count))
  }

  /// Being under the truth costs `q`, being over it costs `1 − q`: at P90 an underestimate
  /// hurts nine times as much as an overestimate, which is what makes it a 90th percentile
  /// and not just a large number.
  static func pinball(actual: Decimal, predicted: Decimal, at probability: Decimal) -> Decimal {
    actual >= predicted
      ? probability * (actual - predicted) : (1 - probability) * (predicted - actual)
  }
}

extension Shares {
  /// A count out of a total, in basis points; 10 000 is all of them.
  static func basisPoints(_ part: Int, of whole: Int) -> Int {
    guard whole > 0 else { return 0 }
    return Int((Int64(part) * Int64(Shares.whole) + Int64(whole) / 2) / Int64(whole))
  }
}
