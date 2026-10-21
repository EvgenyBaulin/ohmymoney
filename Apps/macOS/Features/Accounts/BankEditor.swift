import AppCore
import SwiftUI

/// The form of a bank, new or there already: its name. A new bank comes with its first account
/// and the card of that account, both called like it and in the default currency, in one step of
/// ⌘Z; everything else about them — the kind, the currencies, the balance — is theirs to edit.
/// Shown as a sheet from the settings and from the list of choices of an account; a system form,
/// no glass.
struct BankEditor: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.store) private var store

  /// `nil` for a new bank.
  let previous: Bank?
  /// Called once the sheet is done with: the id of the account a new bank started with, the id of
  /// the bank an edit saved, `nil` when nothing was written.
  let finish: (UUID?) -> Void

  @State private var name: String
  @State private var books: AccountBooks?
  @State private var refusal: AccountRefusal?
  @State private var failed = false

  init(previous: Bank?, finish: @escaping (UUID?) -> Void) {
    self.previous = previous
    self.finish = finish
    _name = State(initialValue: previous?.name ?? "")
  }

  private var actions: AccountActions { AccountActions(environment: environment, store: store) }

  private func t(_ key: String) -> String { environment.language(key, table: "Accounts") }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(verbatim: t(previous == nil ? "bank.editor.newTitle" : "bank.editor.title"))
        .appFont(.headline)
      Form {
        Section {
          NameField(title: t("bank.editor.name"), text: $name, identifier: "bank.editor.name")
            .onSubmit(save)
        } footer: {
          Text(verbatim: t(previous == nil ? "bank.editor.newHint" : "bank.editor.hint"))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .formStyle(.grouped)

      if let refusal {
        AccountRefusalNote(refusal: refusal, restore: restoreFromArchive)
      }
      HStack {
        Spacer()
        Button(environment.language("action.cancel"), role: .cancel) { finish(nil) }
          .keyboardShortcut(.cancelAction)
        Button(environment.language("action.save"), action: save)
          .keyboardShortcut(.defaultAction)
          .buttonStyle(.borderedProminent)
          .disabled(!canSave || store.isWritingInBackground)
      }
    }
    .padding(20)
    .sheetFrame(width: 440)
    .task {
      guard previous == nil else { return }
      books = await actions.books()
      // Without the books nothing can be checked or saved: said, not a greyed button alone.
      if books == nil { failed = true }
    }
    .onChange(of: name) { _, _ in refusal = nil }
    .refusedWriteAlert($failed, environment)
  }

  /// A new bank is checked against the books, which are read when the sheet opens; an edit needs
  /// only a name.
  private var canSave: Bool {
    !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && (previous != nil || books != nil)
  }

  private func save() {
    guard canSave else { return }
    if var bank = previous {
      bank.name = name
      switch actions.save(bank: bank) {
      case .done: finish(bank.id)
      case .refused(let reason): refusal = reason
      case .failed: failed = true
      }
      return
    }
    guard let books else { return }
    let creation = actions.createBank(named: name, books: books)
    switch creation.outcome {
    case .done: finish(creation.accountId)
    case .refused(let reason): refusal = reason
    case .failed: failed = true
    }
  }

  /// A new bank named like an account in the archive: that account comes back instead of a
  /// second account with the same name.
  private func restoreFromArchive(_ id: UUID) {
    switch actions.restore(id) {
    case .done: finish(id)
    case .refused(let reason): refusal = reason
    case .failed: failed = true
    }
  }
}
