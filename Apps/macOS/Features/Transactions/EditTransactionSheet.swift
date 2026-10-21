import AppCore
import SwiftUI

/// Editing an operation in the main window: a double click in the list opens the shared
/// `TransactionEditor` — the same ↓ panel the entry line uses, bound to the saved operation
/// — in a sheet. Saving replaces it; ⌘Z brings the old version back. The Transactions window
/// shows the same editor in its inspector.
struct EditTransactionSheet: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.store) private var store
  @Environment(\.dismiss) private var dismiss

  let entry: TransactionEntry
  @State private var editor: TransactionEditorModel?

  var body: some View {
    Group {
      if let editor {
        VStack(alignment: .leading, spacing: 0) {
          TransactionEditor(editor: editor, style: .sheet) { dismiss() }
          // An income allocated beyond the sum the edit gives it: said, not refused.
          if entry.transaction.kind == .income,
            let beyond = store.allocatedBeyond(
              incomeId: entry.id, amount: editor.draft.draft.amount)
          {
            Label {
              Text(
                verbatim: environment.format(
                  "allocation.over", table: "Allocation",
                  environment.money.rounded(
                    beyond, currency: entry.transaction.currency)))
            } icon: {
              Image(systemName: "exclamationmark.triangle")
            }
            .appFont(.caption)
            .foregroundStyle(.orange)
            .padding([.horizontal, .bottom], 20)
            .accessibilityIdentifier("edit.allocationOver")
          }
        }
      } else {
        ProgressView()
          .padding(20)
      }
    }
    .onAppear {
      if editor == nil { editor = TransactionEditorModel(entry: entry, environment: environment) }
    }
  }

  /// The saved operation after the edit; see `TransactionEditorModel.edited`.
  nonisolated static func edited(
    _ original: TransactionEntry, with draft: TransactionDraft,
    now: Date = Date(),
    rublesConverter: (AmountE4) throws -> AmountE4
  ) throws -> TransactionEntry {
    try TransactionEditorModel.edited(
      original, with: draft, now: now, rublesConverter: rublesConverter)
  }
}
