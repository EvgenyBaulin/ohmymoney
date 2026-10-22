import AppCore
import Foundation

/// What the «Разовое» item of the row menu and of the bulk menu does for a selection, apart
/// from the menu so a test reads it.
enum OneOffMenu {
  enum Action: Equatable {
    case mark
    case unmark
  }

  /// The operations the mark can be put on: expenses (it is spending the averages leave out).
  static func targets(in entries: [TransactionEntry]) -> [UUID] {
    entries.filter { $0.transaction.kind == .expense }.map(\.transaction.id)
  }

  /// «Отметить» unless every expense of the selection already carries the mark, then «Снять»;
  /// `nil` when the selection holds no expense.
  static func action(for entries: [TransactionEntry]) -> Action? {
    let expenses = entries.filter { $0.transaction.kind == .expense }
    guard !expenses.isEmpty else { return nil }
    return expenses.allSatisfy(\.transaction.isOneOff) ? .unmark : .mark
  }
}
