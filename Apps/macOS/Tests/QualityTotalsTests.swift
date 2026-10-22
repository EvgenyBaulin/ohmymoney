import AppCore
import XCTest

@testable import OhMyMoney

/// The three tiles of «Good vs Bad» are the chart's own columns added up.
final class QualityTotalsTests: XCTestCase {
  private func column(_ month: Int, good: Int64, neutral: Int64, bad: Int64) -> ShareColumn {
    let values: [(Quality, Int64)] = [(.good, good), (.neutral, neutral), (.bad, bad)]
    return ShareColumn(
      month: MonthKey(year: 2026, month: month),
      segments: values.filter { $0.1 > 0 }.map {
        ShareSegment(quality: $0.0, basisPoints: 0, start: 0, end: 0, value: $0.1)
      })
  }

  func testTotalsAreSummedOverAllColumnsAndSharedOutOfTheWhole() {
    let totals = QualityTotals.make(columns: [
      column(1, good: 100, neutral: 300, bad: 100),
      column(2, good: 300, neutral: 500, bad: 100),
    ])
    XCTAssertEqual(totals.tiles.map(\.quality), [.good, .neutral, .bad])
    XCTAssertEqual(totals.tiles.map(\.value), [400, 800, 200])
    // 400 / 1400, 800 / 1400, 200 / 1400 in basis points.
    XCTAssertEqual(totals.tiles.map(\.basisPoints), [2_857, 5_714, 1_429])
  }

  func testARatingWithoutSpendingStillHasItsTile() {
    let totals = QualityTotals.make(columns: [column(1, good: 0, neutral: 500, bad: 0)])
    XCTAssertEqual(totals.tiles.count, 3)
    XCTAssertEqual(totals.tiles[0].value, 0)
    XCTAssertEqual(totals.tiles[0].basisPoints, 0)
    XCTAssertEqual(totals.tiles[1].basisPoints, 10_000)
  }

  func testNoSpendingHasNoShares() {
    let totals = QualityTotals.make(columns: [])
    XCTAssertEqual(totals.tiles.count, 3)
    XCTAssertTrue(totals.tiles.allSatisfy { $0.basisPoints == nil && $0.value == 0 })
  }
}
