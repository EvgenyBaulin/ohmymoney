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

  /// The narrowest screen that edits beside the table: the editor's column and a table that
  /// still shows the time, the description and the amount.
  static let widthForEditorColumn: CGFloat = TransactionInspector.idealWidth + 380

  /// `width` is what the screen was given, 0 while it is not known yet (the column is tried).
  static func choose(style: EntryStyle, width: CGFloat) -> OperationEditPlace {
    switch style {
    case .form: .form
    case .line: width <= 0 || width >= widthForEditorColumn ? .column : .sheet
    }
  }
}
