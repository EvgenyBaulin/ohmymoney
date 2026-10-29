import AppCore
import SwiftUI

/// A saved operation edited in the form at the side of the main window (`EntryStyle.form`): an
/// operation selected in a list of the window opens here, in the fields of the form, with
/// «Отмена» and «Сохранить». The save is the one of the edit sheet and of the inspector
/// (`TransactionEditorModel.save`): the same refusals, the same questions, one step of ⌘Z.
struct EntryFormEditor: View {
  @Dependency(\.environment) private var environment
  @Environment(\.themeSurfaces) private var surfaces
  @Dependency(\.store) private var store
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies

  @Bindable var editor: TransactionEditorModel
  /// The editing is over — saved or cancelled: the form goes back to a new operation.
  let close: () -> Void
  /// Whether a field of the form has the keyboard: Return is «Сохранить» only then.
  @State private var focusedInside = false

  var body: some View {
    VStack(spacing: 0) {
      HStack(alignment: .firstTextBaseline) {
        Text(verbatim: environment.language("entry.form.editTitle", table: "Entry"))
          .appFont(.title3.bold())
          .accessibilityIdentifier("entry.form.editTitle")
        Spacer(minLength: 8)
      }
      .padding(.horizontal, Self.inset)
      .padding(.vertical, 12)
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          DetailsPanel(
            model: editor.draft, submit: saveOnReturn, focusedInside: $focusedInside,
            arrangement: .column
          )
          AttachedFilesCard(owner: .transaction, id: editor.id)
        }
        .padding(Self.inset)
      }
      Divider()
      VStack(alignment: .leading, spacing: 8) {
        // Wraps in the width of the column, never fixed to its full height.
        if let errorKey = editor.errorKey {
          Text(
            verbatim: environment.language(
              errorKey, table: TransactionEditorModel.table(ofErrorKey: errorKey))
          )
          .appFont(.caption)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
          .accessibilityIdentifier("entry.form.editError")
        }
        HStack {
          Button(environment.language("action.cancel"), role: .cancel, action: close)
            .controlSize(.large)
            .accessibilityIdentifier("entry.form.cancelEdit")
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
          // Return saves from any field of the form while the focus is in it; with the focus in
          // the list beside it, Return and the arrows are the list's.
          .keyboardShortcut(focusedInside ? .defaultAction : nil)
          .disabled(!editor.canSave(in: store))
          .accessibilityIdentifier("entry.form.saveEdit")
        }
      }
      .padding(Self.inset)
    }
    // Esc in a field of the form: back to a new operation, nothing saved.
    .onExitCommand(perform: close)
    // The answers date the operation among the counts of its day, and the save goes on.
    .beforeTheCountQuestions($editor.countQuestion) { moment in
      editor.stampCount(moment)
      save()
    }
    // Money the edit would leave on an archived account goes to a live one, in the same step.
    .sheet(
      isPresented: Binding(
        get: { editor.archivedLeftovers != nil },
        set: { if !$0 { editor.archivedLeftovers = nil } })
    ) {
      if let check = editor.archivedLeftovers {
        ArchivedMoneySheet(
          check: check,
          confirm: { settling in
            editor.archivedLeftovers = nil
            save(settling: settling)
          },
          cancel: { editor.archivedLeftovers = nil }
        )
        .handingOver(dependencies)
      }
    }
    .editSaveQuestions(
      $editor.saveQuestion,
      answered: {
        editor.answerSaveQuestion()
        save()
      }
    )
    .onAppear {
      let compute = self.compute
      editor.balancesNow = { compute.snapshot?.planning.accounts.balances ?? .empty }
      editor.moneyNow = { .init(compute.snapshot) }
    }
    .onDisappear {
      editor.balancesNow = nil
      editor.moneyNow = nil
    }
  }

  /// Return in a text field of the form: the save, when «Сохранить» is on.
  private func saveOnReturn() {
    guard editor.canSave(in: store) else { return }
    save()
  }

  private func save(settling: [Transfer]? = nil) {
    let balances = compute.snapshot?.planning.accounts.balances ?? .empty
    if editor.save(
      store: store, environment: environment, balances: balances, settling: settling)
    {
      close()
    }
  }

  private static var inset: CGFloat { 16 }
}

/// Which saved operation the form at the side edits for a selection of the window's list: one
/// selected operation is edited; nothing, several rows or a transfer — a new operation.
enum EntryFormSelection {
  static func operation(
    _ selection: Set<UUID>, find: (UUID) -> TransactionEntry?
  ) -> TransactionEntry? {
    guard selection.count == 1, let id = selection.first else { return nil }
    return find(id)
  }
}
