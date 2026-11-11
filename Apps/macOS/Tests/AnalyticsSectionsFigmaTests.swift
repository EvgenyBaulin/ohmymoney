import AppCore
import AppKit
import SwiftUI
import XCTest

@testable import OhMyMoney

/// The pages of Analytics other than the first of «Траты» against the numbers of their frames —
/// «Хорошие и плохие» 6:107920, «За других» 6:108126, «На кого» 6:108350, «Места» 6:108517,
/// «События» 6:108672, «Счета» 6:108823 — and the figures they show against the core's own
/// tables of the same synthetic book.
@MainActor
final class AnalyticsSectionsFigmaTests: XCTestCase {
  private let today = DateOnly(year: 2026, month: 11, day: 10)
  private let october = MonthKey(year: 2026, month: 10)

  private func ledger() -> Ledger { PlanningFigmaWindowTests.snapshot(today: today).ledger }

  // MARK: Numbers of the frames

  /// 6:108467: rows of 16, 14 apart; the name column 150, the amount 130, the note 50, 10
  /// between; a tick of 2 by 24; the longest bar at 90 % of the track.
  func testTheTrackRowsHaveTheNumbersOfTheFrame() {
    XCTAssertEqual(TrackBarsMetrics.rowHeight, 16)
    XCTAssertEqual(TrackBarsMetrics.rowGap, 14)
    XCTAssertEqual(TrackBarsMetrics.columnGap, 10)
    XCTAssertEqual(TrackBarsMetrics.nameWidth, 150)
    XCTAssertEqual(TrackBarsMetrics.amountWidth, 130)
    XCTAssertEqual(TrackBarsMetrics.noteWidth, 50)
    XCTAssertEqual(TrackBarsMetrics.tickSize, CGSize(width: 2, height: 24))
    XCTAssertEqual(TrackBarsMetrics.ratio(52_000, top: 52_000), 0.9, accuracy: 0.0001)
    XCTAssertEqual(TrackBarsMetrics.ratio(26_000, top: 52_000), 0.45, accuracy: 0.0001)
    XCTAssertEqual(TrackBarsMetrics.ratio(-5, top: 52_000), 0)
    XCTAssertEqual(TrackBarsMetrics.ratio(5, top: 0), 0)
  }

  /// The previous period counts for the scale: a tick never leaves the track.
  func testTheLongestFigureMayBeThePreviousOne() {
    let rows = [
      TrackRow(
        id: "a", label: "A", marker: nil, tint: .accent, value: 50, previous: 100, amount: "",
        note: nil, spokenValue: ""),
      TrackRow(
        id: "b", label: "B", marker: nil, tint: .accent, value: 80, previous: nil, amount: "",
        note: nil, spokenValue: ""),
    ]
    XCTAssertEqual(TrackBarsMetrics.top(of: rows), 100)
  }

  /// 6:108313: a plot of 170, bars of 40, the tallest at 60 %, the outline of 2, 8 between the
  /// parts, a legend swatch of 22 by 6, 16 between its items.
  func testThePairedBarsHaveTheNumbersOfTheFrame() {
    XCTAssertEqual(PairedBarsMetrics.plotHeight, 170)
    XCTAssertEqual(PairedBarsMetrics.barWidth, 40)
    XCTAssertEqual(PairedBarsMetrics.bar(slot: 181.67), 40)
    XCTAssertLessThan(PairedBarsMetrics.bar(slot: 100), 40)
    XCTAssertEqual(PairedBarsMetrics.barHeight(100, top: 100), 102, accuracy: 0.001)
    XCTAssertEqual(PairedBarsMetrics.barHeight(50, top: 100), 51, accuracy: 0.001)
    XCTAssertEqual(PairedBarsMetrics.barHeight(0, top: 100), 0)
    XCTAssertEqual(PairedBarsMetrics.gridLines, 4)
    XCTAssertEqual(PairedBarsMetrics.spacing, 8)
    XCTAssertEqual(PairedBarsMetrics.legendGap, 16)
    XCTAssertEqual(PairedBarsMetrics.swatch, CGSize(width: 22, height: 6))
  }

  /// 6:108672: within, over, not started; the bar fills to the share spent and an overrun fills
  /// it all, 7 at least, 8 high.
  func testTheEventCardsJudgeSpendingAgainstTheBudget() {
    func item(_ total: Int64, _ budget: Int64?) -> EventItem {
      EventItem(
        eventId: UUID(), start: today, end: today, total: total, budget: budget, left: nil,
        lastYearTotal: nil, lastYear: nil, byCategory: [])
    }
    XCTAssertEqual(EventBudgetMetrics.verdict(item(82_000, 100_000)), .within)
    XCTAssertEqual(EventBudgetMetrics.verdict(item(31_000, 25_000)), .over)
    XCTAssertEqual(EventBudgetMetrics.verdict(item(0, 40_000)), .notStarted)
    XCTAssertEqual(EventBudgetMetrics.verdict(item(5, nil)), .within)
    XCTAssertEqual(EventBudgetMetrics.ratio(spent: 82_000, budget: 100_000), 0.82, accuracy: 0.0001)
    XCTAssertEqual(EventBudgetMetrics.ratio(spent: 31_000, budget: 25_000), 1)
    XCTAssertEqual(EventBudgetMetrics.ratio(spent: 0, budget: 40_000), 0)
    XCTAssertEqual(EventBudgetMetrics.barHeight, 8)
    XCTAssertEqual(EventBudgetMetrics.minimumFill, 7)
    // Words and a symbol for each verdict: never the colour alone.
    XCTAssertNotNil(EventBudgetMetrics.Verdict.within.symbol)
    XCTAssertNotNil(EventBudgetMetrics.Verdict.over.symbol)
    XCTAssertNil(EventBudgetMetrics.Verdict.notStarted.symbol)
  }

  /// 6:109174: a row of the list is 57 high with a chip of 21 and no card of its own.
  func testTheAnomalyRowHasTheNumbersOfTheFrame() {
    XCTAssertEqual(AnomalyRowMetrics.rowHeight, 57)
    XCTAssertEqual(AnomalyRowMetrics.chipHeight, 21)
  }

  /// 61:62017: cells 20 high, 2 across and 3 down, the day's name 22, 12 between the blocks.
  func testTheHeatmapHasTheNumbersOfTheFrame() {
    XCTAssertEqual(HeatmapMetrics.cellHeight, 20)
    XCTAssertEqual(HeatmapMetrics.cellGap, 2)
    XCTAssertEqual(HeatmapMetrics.rowGap, 3)
    XCTAssertEqual(HeatmapMetrics.labelWidth, 22)
    XCTAssertEqual(HeatmapMetrics.sectionGap, 12)
    XCTAssertEqual(HeatmapMetrics.swatch, CGSize(width: 14, height: 10))
    XCTAssertEqual(HeatmapReading.levels + 1, 5, "five swatches in the legend")
  }

  /// 61:61028: controls and rows 12 apart, figure columns 110, change 150, 10 between.
  func testTheComparisonHasTheNumbersOfTheFrame() {
    XCTAssertEqual(ComparisonMetrics.controlGap, 12)
    XCTAssertEqual(ComparisonMetrics.rowGap, 12)
    XCTAssertEqual(ComparisonMetrics.columnGap, 10)
    XCTAssertEqual(ComparisonMetrics.figureWidth, 110)
    XCTAssertEqual(ComparisonMetrics.changeWidth, 150)
  }

  /// 61:62668: the half-width cut of the rows: the longest bar fills its track, no tick.
  func testTheHalfWidthTrackRowsFillTheTrack() {
    XCTAssertEqual(TrackBarsLayout.half.topRatio, 1)
    XCTAssertEqual(TrackBarsLayout.half.rowGap, 12)
    XCTAssertEqual(TrackBarsLayout.half.noteSize, 11)
    XCTAssertEqual(
      TrackBarsMetrics.ratio(14_200, top: 14_200, topRatio: TrackBarsLayout.half.topRatio), 1)
    XCTAssertEqual(TrackBarsLayout.wide.nameWidth, 150)
  }

  // MARK: What the sections show

  /// 6:108126: six months to the month of the period, what was paid for others and what came
  /// back, each month the core's own report of that month.
  func testTheDynamicsOfPaidForOthersAreTheCoresMonths() throws {
    let book = ledger()
    let model = AnalyticsBuilder.others(ledger: book, period: .month(october), today: today)
    let reason = model.dynamics.reason
    guard let months = model.dynamics.content else {
      // A book that paid for nobody says so and draws nothing.
      XCTAssertEqual(reason, .nothingPaidForOthers)
      return
    }
    XCTAssertEqual(months.count, 6)
    XCTAssertEqual(months.last?.month, october)
    XCTAssertEqual(months.first?.month, MonthKey(year: 2026, month: 5))
    for month in months {
      let totals = OthersReport(ledger: book, period: .month(month.month)).totals
      XCTAssertEqual(month.paid, totals.paid.wholeRubles, month.month.iso)
      XCTAssertEqual(month.returned, totals.returned.wholeRubles, month.month.iso)
    }
  }

  /// 6:108350: «for whom» carries the figure of the period before for its tick, and its rows
  /// the shapes of the frame.
  func testForWhomRowsCarryThePreviousPeriod() throws {
    let book = ledger()
    let model = AnalyticsBuilder.forWhom(ledger: book, period: .month(october), today: today)
    let values = try XCTUnwrap(model.values.content)
    let before = ForWhomReport(ledger: book, period: Period.month(october).previous).values
    for value in values {
      let expected = before.first { $0.key == value.key }?.amount.wholeRubles ?? 0
      XCTAssertEqual(value.previous, expected, "\(value.key)")
    }
    XCTAssertEqual(AnalyticsText.forWhomLook(.me).0, .square)
    XCTAssertEqual(AnalyticsText.forWhomLook(.partner).0, .triangle)
    XCTAssertEqual(AnalyticsText.forWhomLook(.family).0, .ring)
    XCTAssertEqual(AnalyticsText.forWhomLook(.friends).0, .diamond)
    XCTAssertEqual(AnalyticsText.forWhomLook(.other).0, .square)
  }

  /// 6:108517: the places carry the figure of the period before and their visits.
  func testPlacesCarryThePreviousPeriodAndTheirVisits() throws {
    let book = ledger()
    let model = AnalyticsBuilder.places(ledger: book, period: .month(october))
    guard let values = model.byAmount.content else { return }
    let before = PlacesReport(ledger: book, period: Period.month(october).previous).places
    let now = PlacesReport(ledger: book, period: .month(october)).places
    for value in values {
      guard case .place(let id) = value.key else { return XCTFail("a place") }
      XCTAssertEqual(
        value.previous, before.first { $0.placeId == id }?.mySpending.wholeRubles ?? 0)
      XCTAssertEqual(value.times, now.first { $0.placeId == id }?.purchases)
    }
  }

  /// 6:108823: the shares of the accounts and cards add up to the whole of the spending.
  func testPaymentMethodSharesAreOfTheWholeSpending() throws {
    let model = AnalyticsBuilder.paymentMethods(ledger: ledger(), period: .month(october))
    guard let values = model.spending.content else { return }
    let whole = values.reduce(Int64(0)) { $0 + $1.value }
    for value in values {
      let share = try XCTUnwrap(value.share)
      XCTAssertEqual(Double(share), Double(value.value) * 10_000 / Double(whole), accuracy: 0.5)
      XCTAssertNotNil(value.previous)
    }
  }

  /// 6:107920: the lines are the months' shares of the three ratings, in basis points.
  func testTheShareLinesAreTheStackedSharesOfTheCore() throws {
    let tab = AnalyticsBuilder.quality(ledger: ledger(), period: .month(october), today: today)
    guard let columns = tab.shares.content else { return }
    for column in columns {
      XCTAssertLessThanOrEqual(column.segments.map(\.basisPoints).reduce(0, +), 10_050)
    }
    XCTAssertEqual(AnalyticsText.rowLook(0).0, .square)
    XCTAssertEqual(AnalyticsText.rowLook(9).0, .square, "the last look repeats")
  }

  // MARK: Layout

  /// A row of the track chart is 16 high and its rows 14 apart.
  func testTheTrackChartIsAsTallAsItsRows() {
    let rows = (0..<5).map {
      TrackRow(
        id: "\($0)", label: "Row \($0)", marker: .square, tint: .accent, value: Int64($0 + 1),
        previous: 2, amount: "1 ₽", note: "1 %", spokenValue: "")
    }
    let host = NSHostingView(
      rootView: TrackBarsChart(rows: rows).frame(width: 1118))
    host.frame = NSRect(x: 0, y: 0, width: 1118, height: 400)
    let size = host.fittingSize
    XCTAssertEqual(size.height, 5 * 16 + 4 * 14, accuracy: 1)
  }
}
