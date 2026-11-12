import AppCore
import SwiftUI

/// Where an operation or a transfer opened from a list is edited: in the column beside the
/// table of «Операции», in the form at the side of the window, or in a sheet when the screen has
/// no room for the column. Transfers go where operations go.
@MainActor
enum OperationEditPlace: Equatable {
  case column
  case form
  case sheet

  /// What the table keeps beside the editor: every column of the design at its minimum, the
  /// 17 pt gap AppKit leaves after each, the card's left margin and the divider. A narrower
  /// table would run off under a horizontal scroller, so the screen edits in a sheet instead.
  static let tableWidthBesideEditor: CGFloat =
    OperationColumn.allCases.filter(\.shownByDefault).reduce(0) {
      $0 + CGFloat($1.minimumWidth) + 17
    } + OperationsMetrics.pageSide + 1

  /// The narrowest screen that edits beside the table: the editor's column and a table that
  /// still shows all its columns.
  static let widthForEditorColumn: CGFloat =
    TransactionInspector.idealWidth + tableWidthBesideEditor

  /// `width` is what the screen was given, 0 while it is not known yet (the column is tried).
  static func choose(style: EntryStyle, width: CGFloat) -> OperationEditPlace {
    switch style {
    case .form: .form
    case .line: width <= 0 || width >= widthForEditorColumn ? .column : .sheet
    }
  }
}
