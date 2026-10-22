import AppCore
import AppKit
import SwiftUI
import XCTest

@testable import OhMyMoney

/// The flow of the entry panel's fields: how many columns a width holds, how the cells fall
/// into rows, that a cell standing alone owns its row, and the kind tabs' identifiers.
@MainActor
final class EntryFieldFlowTests: XCTestCase {
  private func columns(_ width: CGFloat, max: Int = 3) -> Int {
    EntryFieldFlow.columns(width: width, maxColumns: max, minimumCellWidth: 150, spacing: 12)
  }

  func testThePanelHoldsThreeColumnsAndAPhoneTwo() {
    XCTAssertEqual(columns(640), 3)
    XCTAssertEqual(columns(560), 3)
    XCTAssertEqual(columns(358), 2)
    XCTAssertEqual(columns(340, max: EntryFieldFlowMetrics.sideColumns), 2)
  }

  func testANarrowWidthFallsToOneColumnAndNeverToZero() {
    XCTAssertEqual(columns(200), 1)
    XCTAssertEqual(columns(0), 3)
    XCTAssertEqual(columns(-5), 3)
    XCTAssertEqual(columns(40), 1)
  }

  func testTheSideFormNeverUsesMoreThanItsColumns() {
    XCTAssertEqual(columns(900, max: EntryFieldFlowMetrics.sideColumns), 2)
  }

  func testCellsFillRowsLeftToRight() {
    let rows = EntryFieldFlow.rows(alone: Array(repeating: false, count: 7), columns: 3)
    XCTAssertEqual(rows, [[0, 1, 2], [3, 4, 5], [6]])
  }

  func testACellAloneClosesTheRowBeforeItAndFillsItsOwn() {
    // amount, category, subcategory, line, place, event, goal
    let alone = [true, false, false, true, false, false, false]
    XCTAssertEqual(
      EntryFieldFlow.rows(alone: alone, columns: 3), [[0], [1, 2], [3], [4, 5, 6]])
  }

  func testOneColumnPutsEveryCellOnItsOwnRow() {
    XCTAssertEqual(
      EntryFieldFlow.rows(alone: [false, false, true, false], columns: 1),
      [[0], [1], [2], [3]])
  }

  func testNoCellsMakeNoRows() {
    XCTAssertEqual(EntryFieldFlow.rows(alone: [], columns: 3), [])
  }

  func testEveryKindTabKeepsTheIdentifierOfItsTile() {
    XCTAssertEqual(EntryKindTabs.identifier(of: .kind(.expense)), "entry.kind.expense")
    XCTAssertEqual(EntryKindTabs.identifier(of: .kind(.reimbursement)), "entry.kind.reimbursement")
    XCTAssertEqual(EntryKindTabs.identifier(of: .transfer), "entry.kind.transfer")
    let all = EntryKindTiles.all.map(EntryKindTabs.identifier(of:))
    XCTAssertEqual(Set(all).count, all.count)
  }

  func testTheFlowStacksCellsOfADefinedWidthInRows() {
    // Three cells in a 480-wide proposal fit one row; a fourth makes a second.
    func height(cells: Int) -> CGFloat {
      // dependencies: the flow reads nothing from the environment; this host only sizes plain cells.
      let host = NSHostingView(
        rootView: EntryFieldFlow(maxColumns: 3) {
          ForEach(0..<cells, id: \.self) { _ in Color.clear.frame(height: 30) }
        }
        .frame(width: 480))
      return host.fittingSize.height
    }
    XCTAssertEqual(height(cells: 3), 30, accuracy: 0.5)
    XCTAssertEqual(height(cells: 4), 30 + EntryFieldFlowMetrics.rowSpacing + 30, accuracy: 0.5)
  }
}
