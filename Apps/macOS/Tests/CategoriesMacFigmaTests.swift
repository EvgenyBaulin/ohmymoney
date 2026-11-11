import AppCore
import SwiftUI
import XCTest

@testable import OhMyMoney

#if os(macOS)
  /// The numbers of «Настройки → Категории» as the design draws them (Figma 60:28461), and the
  /// way a row is opened.
  @MainActor
  final class CategoriesMacFigmaTests: XCTestCase {
    func testRowMeasuresFollowTheDesign() {
      typealias M = CategoriesMacMetrics
      XCTAssertEqual(M.blockGap, 18)
      XCTAssertEqual(M.markSide, 20)
      XCTAssertEqual(M.rowHorizontal, 16)
      XCTAssertEqual(M.rowVertical, 11)
      XCTAssertEqual(M.rowGap, 12)
      XCTAssertEqual(M.chipHorizontal, 8)
      XCTAssertEqual(M.chipVertical, 2)
      XCTAssertEqual(M.chevron, 14)
    }
  }
#endif
