import SwiftUI
import XCTest

@testable import OhMyMoney

/// The accent is the owner's to choose, and a chart of five series promises
/// five different colours. These two promises meet here: nothing about the shapes and the
/// patterns may move when the accent does.
final class ChartSeriesStyleTests: XCTestCase {
  func testNoTwoSeriesShareAColourForAnyAccent() {
    for accent in AppTheme.Accent.allCases {
      let styles = ChartSeriesStyle.ordered(accent: accent)
      XCTAssertEqual(styles.count, 5, accent.rawValue)
      XCTAssertEqual(
        Set(styles.map(\.tint)).count, styles.count,
        "two series share a colour with the \(accent.rawValue) accent")

      // And none of the fixed colours is the very colour the accent already is: equal names
      // are not the point, equal paint is.
      guard let same = ChartSeriesStyle.accentTint(accent) else { continue }
      XCTAssertFalse(
        styles.dropFirst().contains { $0.tint == same },
        "a series kept the colour the \(accent.rawValue) accent took")
    }
  }

  func testTheShapesAndDashesNeverMoveWithTheAccent() {
    let symbols: [ChartSymbol] = [.circle, .square, .triangle, .diamond, .pentagon]
    let dashes: [[CGFloat]] = [[], [6, 4], [2, 3], [6, 3, 2, 3], [10, 4]]
    for accent in AppTheme.Accent.allCases {
      let styles = ChartSeriesStyle.ordered(accent: accent)
      XCTAssertEqual(styles.map(\.symbol), symbols, accent.rawValue)
      XCTAssertEqual(styles.map(\.dash), dashes, accent.rawValue)
      // The main series is the accent's, whatever the accent is.
      XCTAssertEqual(styles.first?.tint, .accent, accent.rawValue)
    }
  }

  /// Past the last series the list repeats its last, and a negative index its first: the
  /// models never ask for either, and neither may trap.
  func testTheIndexIsClampedToTheFiveSeries() {
    for accent in AppTheme.Accent.allCases {
      let styles = ChartSeriesStyle.ordered(accent: accent)
      XCTAssertEqual(ChartSeriesStyle.series(-1, accent: accent), styles[0])
      XCTAssertEqual(ChartSeriesStyle.series(4, accent: accent), styles[4])
      XCTAssertEqual(ChartSeriesStyle.series(99, accent: accent), styles[4])
    }
  }

  /// `.accent` is the only tint that moves with the owner's choice; every other one is the
  /// system's and answers the same colour whatever is passed in.
  func testOnlyTheAccentTintFollowsTheChoice() {
    XCTAssertEqual(ChartTint.accent.color(.pink), .pink)
    XCTAssertEqual(ChartTint.accent.color(.teal), .teal)
    for tint in ChartTint.allCases where tint != .accent {
      XCTAssertEqual(tint.color(.pink), tint.color(.teal), tint.rawValue)
    }
  }

  /// A pair drawn in named colours — income green against expenses in the accent — has to
  /// step aside too, or a green accent paints both halves of one chart the same
  /// (found on review 21.09).
  func testAFixedColourStepsAsideFromTheAccentItWouldMatch() {
    for accent in AppTheme.Accent.allCases {
      let green = ChartSeriesStyle.free(.green, accent: accent)
      XCTAssertNotEqual(
        ChartSeriesStyle.accentTint(accent), green,
        "\(accent) leaves income and expenses the same colour")
      if accent != .green { XCTAssertEqual(green, .green, "\(accent) moved a colour it need not") }
    }
  }

  func testTheColourThatStepsAsideIsNotTheAccentEither() {
    for accent in AppTheme.Accent.allCases {
      for wanted in ChartTint.allCases {
        let free = ChartSeriesStyle.free(wanted, accent: accent)
        XCTAssertNotEqual(ChartSeriesStyle.accentTint(accent), free, "\(accent) / \(wanted)")
      }
    }
  }
}
