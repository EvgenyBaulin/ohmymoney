import AppCore
import SwiftUI

/// A saved transfer edited in a column — beside the table of «Операции» or as the form at the
/// side of the window —, not in a sheet: the fields of the transfer under their labels, with
/// «Отмена» and «Сохранить». The fields and the save are the sheet's (`TransferFields`,
/// `TransferEntry.save`): the same refusals and questions, one step of ⌘Z with the fee.
struct TransferEditorColumn: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.store) private var store
  @Environment(\.themeSurfaces) private var surfaces

  let entry: TransferEntry
  /// The editing is over — saved or cancelled.
  let close: () -> Void

  private func t(_ key: String) -> String { environment.language(key, table: AccountText.table) }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text(verbatim: t("transfer.sheet.editTitle"))
          .appFont(.title3.bold())
          .accessibilityIdentifier("transfer.column.title")
        Spacer(minLength: 8)
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 12)
      Divider()
      ScrollView {
        TransferFields(entry: entry, layout: .column)
          .padding(16)
      }
      Divider()
      HStack {
        Button(environment.language("action.cancel"), role: .cancel, action: close)
          .controlSize(.large)
          .accessibilityIdentifier("transfer.column.cancel")
        Button {
          save()
        } label: {
          Text(verbatim: environment.language("action.save"))
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .tint(surfaces.accent)
        .controlSize(.large)
        .disabled(entry.isSaving || store.isWritingInBackground)
        .accessibilityIdentifier("transfer.column.save")
      }
      .padding(16)
    }
    .onExitCommand(perform: close)
    .transferQuestions(entry)
  }

  private func save() {
    entry.save(TransferActions(environment: environment, store: store)) { close() }
  }
}
