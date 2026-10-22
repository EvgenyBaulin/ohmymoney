import SwiftUI

/// The fields of the entry panel as the design lays them out: cells of one column width flowing
/// in rows, a few of them — the amount, the quality, a note, a line of explanation — standing
/// alone on a row of their own. The number of columns follows the width it is given: three in
/// the ↓ panel, two in the form at the side and on a phone, one where even that does not fit.
struct EntryFieldFlow: Layout {
  /// Most columns it may use.
  var maxColumns = 3
  /// The narrowest a cell may be: a menu of a category still reads in it.
  var minimumCellWidth: CGFloat = 150
  var spacing = EntryFieldFlowMetrics.cellSpacing
  var rowSpacing = EntryFieldFlowMetrics.rowSpacing

  /// A cell that takes a whole row.
  struct Alone: LayoutValueKey {
    static let defaultValue = false
  }

  /// How many columns a width holds: as many as fit at the narrowest cell, never more than
  /// `maxColumns`, never fewer than one.
  static func columns(
    width: CGFloat, maxColumns: Int, minimumCellWidth: CGFloat, spacing: CGFloat
  ) -> Int {
    guard width.isFinite, width > 0 else { return max(1, maxColumns) }
    let fit = Int(((width + spacing) / (minimumCellWidth + spacing)).rounded(.down))
    return max(1, min(maxColumns, fit))
  }

  /// The rows the cells fall into: each a run of indexes. A cell standing alone closes the row
  /// before it and fills its own.
  static func rows(alone: [Bool], columns: Int) -> [[Int]] {
    var rows: [[Int]] = []
    var current: [Int] = []
    for (index, isAlone) in alone.enumerated() {
      if isAlone {
        if !current.isEmpty { rows.append(current) }
        current = []
        rows.append([index])
      } else {
        current.append(index)
        if current.count == columns {
          rows.append(current)
          current = []
        }
      }
    }
    if !current.isEmpty { rows.append(current) }
    return rows
  }

  private func plan(_ subviews: Subviews, width: CGFloat) -> (rows: [[Int]], cell: CGFloat) {
    let count = Self.columns(
      width: width, maxColumns: maxColumns, minimumCellWidth: minimumCellWidth, spacing: spacing)
    let rows = Self.rows(alone: subviews.map { $0[Alone.self] }, columns: count)
    let cell = max(0, (width - spacing * CGFloat(count - 1)) / CGFloat(count))
    return (rows, cell)
  }

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let width = proposal.width ?? (minimumCellWidth * CGFloat(maxColumns))
    let (rows, cell) = plan(subviews, width: width)
    var height: CGFloat = 0
    for (rowIndex, row) in rows.enumerated() {
      let alone = row.count == 1 && subviews[row[0]][Alone.self]
      let rowHeight =
        row.map {
          subviews[$0].sizeThatFits(.init(width: alone ? width : cell, height: nil)).height
        }.max() ?? 0
      height += rowHeight + (rowIndex > 0 ? rowSpacing : 0)
    }
    return CGSize(width: width, height: height)
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    let (rows, cell) = plan(subviews, width: bounds.width)
    var y = bounds.minY
    for row in rows {
      let alone = row.count == 1 && subviews[row[0]][Alone.self]
      let cellWidth = alone ? bounds.width : cell
      var rowHeight: CGFloat = 0
      for index in row {
        rowHeight = max(
          rowHeight, subviews[index].sizeThatFits(.init(width: cellWidth, height: nil)).height)
      }
      for (column, index) in row.enumerated() {
        subviews[index].place(
          at: CGPoint(x: bounds.minX + CGFloat(column) * (cellWidth + spacing), y: y),
          anchor: .topLeading, proposal: .init(width: cellWidth, height: rowHeight))
      }
      y += rowHeight + rowSpacing
    }
  }
}

/// The measures of the flow, as plain numbers a test holds.
enum EntryFieldFlowMetrics {
  /// Between two cells of a row.
  static let cellSpacing: CGFloat = 12
  /// Between two rows.
  static let rowSpacing: CGFloat = 10
  /// Columns of the ↓ panel and the editor, 560–720 pt wide.
  static let panelColumns = 3
  /// Columns of the form at the side, about 380 pt wide, and of a phone sheet.
  static let sideColumns = 2
}
