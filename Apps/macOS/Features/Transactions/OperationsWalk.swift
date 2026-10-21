import AppCore
import SwiftUI

extension Notification.Name {
  /// ↓ in the entry line: the list of operations on screen takes the focus on its newest row
  /// (`OperationsWalk`). Whatever list is in the window answers; a screen with none lets it pass.
  static let walkOperationsList = Notification.Name(
    "io.github.EvgenyBaulin.ohmymoney.walkOperationsList")

  /// ↑ on the newest row, or Esc in the list: the entry line takes the focus back.
  static let returnToEntryLine = Notification.Name(
    "io.github.EvgenyBaulin.ohmymoney.returnToEntryLine")
}

/// Walking the list of operations from the entry line: ↓ in the line selects the newest row of
/// the list on screen and puts the keyboard on the list, where ↓ and ↑ go on row by row; ↑ on that
/// first row, and Esc, hand the keyboard back to the line.
enum OperationsWalk {
  /// The row ↓ lands on: the first line of the newest day — an operation or a transfer, whichever
  /// is later —, or nothing while the list is empty.
  static func firstRow(of days: [[DayItem]]) -> UUID? {
    days.first { !$0.isEmpty }?.first?.selectableId
  }

  /// Whether ↑ on this selection is the way back to the line: the newest row alone is selected.
  static func returnsToTheLine(selection: Set<UUID>, firstRow: UUID?) -> Bool {
    guard let firstRow else { return false }
    return selection == [firstRow]
  }
}

private struct WalkedFromTheEntryLine: ViewModifier {
  let firstRow: UUID?
  @Binding var selection: Set<UUID>
  @FocusState private var focused: Bool

  func body(content: Content) -> some View {
    content
      .focused($focused)
      .onReceive(NotificationCenter.default.publisher(for: .walkOperationsList)) { _ in
        guard let firstRow else { return }
        selection = [firstRow]
        focused = true
      }
      .onKeyPress(.upArrow) {
        guard focused,
          OperationsWalk.returnsToTheLine(selection: selection, firstRow: firstRow)
        else { return .ignored }
        selection = []
        NotificationCenter.default.post(name: .returnToEntryLine, object: nil)
        return .handled
      }
  }
}

extension View {
  /// The list answers ↓ of the entry line: it selects `firstRow` and takes the focus.
  func walkedFromTheEntryLine(firstRow: UUID?, selection: Binding<Set<UUID>>) -> some View {
    modifier(WalkedFromTheEntryLine(firstRow: firstRow, selection: selection))
  }
}

/// The row ↓ or ↑ selects in «Операции»: the next or the one before the row selected, in the order
/// of the table. Nothing selected, ↓ is the first row; several rows, the arrows are the table's
/// own.
enum OperationsArrows {
  static func next(from selection: Set<UUID>, rows: [UUID], down: Bool) -> UUID? {
    guard !rows.isEmpty else { return nil }
    guard let selected = selection.first else { return down ? rows.first : nil }
    guard selection.count == 1, let index = rows.firstIndex(of: selected) else { return nil }
    let target = down ? index + 1 : index - 1
    // At either end the selection stays where it is.
    return rows.indices.contains(target) ? rows[target] : selected
  }

  /// The operations and transfers of the table from top to bottom; the parts of a split are not
  /// selected, so the arrows pass them by.
  static func rows(of listing: TransactionListing) -> [UUID] {
    listing.days.flatMap { $0.rows.map(\.transactionId) }
  }
}
