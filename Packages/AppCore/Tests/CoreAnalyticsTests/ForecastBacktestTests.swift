import CoreKit
import CoreSample
import Foundation
import Testing

@testable import CoreAnalytics

/// The rolling-origin backtest of the month forecast: the arithmetic of the
/// metrics on values worked out by hand, and the three ways of forecasting measured against
/// each other on the synthetic history.
@Suite("Backtest of the month forecast")
struct ForecastBacktestTests {
  /// Under the truth costs `q`, over it costs `1 − q`. At P90 an underestimate hurts nine
  /// times as much as an overestimate — that is what makes it a 90th percentile.
  @Test func thePinballLossIsLopsided() {
    let under = ForecastBacktest.pinball(actual: 1_000, predicted: 900, at: Decimal(9) / 10)
    let over = ForecastBacktest.pinball(actual: 900, predicted: 1_000, at: Decimal(9) / 10)

    #expect(under == 90)
    #expect(over == 10)
    #expect(ForecastBacktest.pinball(actual: 500, predicted: 500, at: Decimal(1) / 2) == 0)
  }

  /// Four origins with answers written out by hand: MAE 250, coverage three out of four.
  @Test func theMetricsAreTheMeanOfTheOrigins() {
    func sample(
      _ p10: String, _ middle: String, _ p90: String, actual: String
    ) -> (forecast: MonthForecast.Remainder, actual: Decimal) {
      (
        MonthForecast.Remainder(
          p10: money(p10), middle: money(middle), p90: money(p90), lowData: false,
          computedFor: DateOnly(year: 2026, month: 9, day: 1), daysLeft: 10, windowDays: 90),
        money(actual).decimal
      )
    }

    let metrics = ForecastBacktest.score([
      sample("0", "1000", "2000", actual: "1000"),  // error 0, inside
      sample("0", "1000", "2000", actual: "1500"),  // error 500, inside
      sample("0", "1000", "2000", actual: "1200"),  // error 200, inside
      sample("0", "1000", "2000", actual: "2300"),  // error 1300, outside
    ])

    #expect(metrics.origins == 4)
    #expect(metrics.mae == money("500"))  // (0 + 500 + 200 + 1300) / 4
    #expect(metrics.coverageBp == 7_500)
    // P50 pinball: half of every error, whichever side it falls on.
    #expect(metrics.pinball50 == money("250"))
  }

  /// A history that is only a month long has no origin the weekday method could have been
  /// used on, so nothing is measured — and nothing is claimed.
  @Test func aShortHistoryIsNotBacktested() {
    var sketch = Sketch()
    let today = DateOnly(year: 2026, month: 9, day: 20)
    for offset in 1...20 { sketch.expense(today.adding(days: -offset).iso, "100") }

    let backtest = ForecastBacktest.run(ledger: sketch.ledger, today: today)

    #expect(backtest.isEmpty)
    #expect(!backtest.beatsTheRate)
  }

  /// The one that matters: on two years of the synthetic history, the way the app forecasts
  /// has to beat the plain rate it is measured against. The measured numbers, and why the
  /// interval holds less often than its name says, are written next to the checks below.
  @Test func theForecastBeatsThePlainRate() {
    let set = SampleDataGenerator(seed: 20_260_918).generate(
      months: 24, endingOn: Synthetic.endingOn, calendar: Synthetic.calendar, language: "en")
    let ledger = Ledger(dataset: Synthetic.dataset(set), calendar: Synthetic.calendar)
    let today = set.lastDay

    let backtest = ForecastBacktest.run(ledger: ledger, today: today)

    #expect(backtest.chosen == .weekday)
    #expect((backtest.metrics(of: .weekday)?.origins ?? 0) > 100)
    #expect(backtest.beatsTheRate, "the forecast does not beat the rate it is measured against")
    // Measured 20.09.2026 on the sample as it is kept now, with the rent a scheduled
    // payment: 13 659 against 23 685 of the plain rate.
    let weekday = backtest.metrics(of: .weekday)
    let rate = backtest.metrics(of: .rate)
    #expect((weekday?.mae.raw ?? 0) * 3 / 2 < (rate?.mae.raw ?? 0))
    // The interval is narrower than its name: the sample of stretches it is drawn from does
    // not know that a month can be heavier than the three before it. What the owner sees is
    // the measured figure, not the nominal 80 %.
    let coverage = weekday?.coverageBp ?? 0
    #expect(coverage >= 5_000, "the interval holds too rarely to be worth drawing")
    #expect(coverage <= 9_800, "an interval that always holds is too wide to say anything")
  }

  /// On the last day of a month that month is not over: today's spending is still being
  /// entered, so its origins have no answer yet. What is typed on the 30th in the evening
  /// changes nothing the backtest said in the morning.
  @Test func theMonthThatEndsTodayIsNotScoredYet() {
    var sketch = Sketch()
    let today = DateOnly(year: 2026, month: 9, day: 30)
    for offset in 1...120 { sketch.expense(today.adding(days: -offset).iso, "100") }
    let morning = ForecastBacktest.run(ledger: sketch.ledger, today: today)

    sketch.expense(today.iso, "1000000")
    let evening = ForecastBacktest.run(ledger: sketch.ledger, today: today)

    #expect(!morning.isEmpty)
    #expect(morning == evening)
  }

  /// A forecast made on an origin never sees a single day after it — the property the whole
  /// backtest rests on.
  @Test func anOriginNeverSeesItsOwnFuture() {
    var sketch = Sketch()
    let today = DateOnly(year: 2026, month: 9, day: 20)
    for offset in 1...120 { sketch.expense(today.adding(days: -offset).iso, "100") }
    let origin = today.adding(days: -40)
    let before = MonthForecast.remainder(ledger: sketch.ledger, today: origin)

    // The same history plus a fortune spent after the origin.
    for offset in 0...10 { sketch.expense(origin.adding(days: offset + 1).iso, "1000000") }
    let after = MonthForecast.remainder(ledger: sketch.ledger, today: origin)

    #expect(before == after)
  }
}
