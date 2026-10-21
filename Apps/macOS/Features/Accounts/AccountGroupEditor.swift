import AppCore
import SwiftUI

/// The form of one group of accounts, new or there already: its name and «Учитывать в общей
/// сводке». A group that holds the main account stays in the summary: its switch is off limits
/// and says why. «Сохранить» is one step of ⌘Z.
struct AccountGroupEditor: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.store) private var store

  /// `nil` for a new group.
  let previous: AccountGroup?
  /// Called once the sheet is done with: the id of the group saved or brought back, `nil`
  /// when nothing was written.
  let finish: (UUID?) -> Void

  @State private var group: AccountGroup
  @State private var accounts: [PaymentMethod] = []
  @State private var refusal: AccountRefusal?
  @State private var failed = false

  init(previous: AccountGroup?, finish: @escaping (UUID?) -> Void) {
    self.previous = previous
    self.finish = finish
    _group = State(initialValue: previous ?? AccountGroup(name: ""))
  }

  private var actions: AccountActions { AccountActions(environment: environment, store: store) }

  private func t(_ key: String) -> String { environment.language(key, table: "Accounts") }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(verbatim: t(previous == nil ? "account.group.newTitle" : "account.group.title"))
        .appFont(.headline)
      Form {
        NameField(
          title: t("account.group.name"), text: $group.name, identifier: "account.group.name")
        Section {
          Toggle(isOn: $group.inSummary) {
            Text(verbatim: t("account.group.inSummary"))
          }
          .disabled(holdsMain)
        } footer: {
          Text(verbatim: t(holdsMain ? "account.group.holdsMain" : "account.group.inSummaryHint"))
            .foregroundStyle(.secondary)
        }
        if !members.isEmpty {
          Section {
            ForEach(members, id: \.id) { account in
              Text(verbatim: account.name)
            }
          } header: {
            Text(verbatim: t("account.group.accounts"))
          }
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
          .disabled(store.isWritingInBackground)
      }
    }
    .padding(20)
    .sheetFrame(width: 420, height: 420)
    .onAppear { accounts = actions.all }
    .onChange(of: group) { _, _ in refusal = nil }
    .refusedWriteAlert($failed, environment)
  }

  /// The live accounts filed under the group, in list order.
  private var members: [PaymentMethod] {
    AccountRules.ordered(accounts, locale: environment.language.locale)
      .filter { $0.groupId == group.id }
  }

  /// The main account is filed here: the group always counts in the summary.
  private var holdsMain: Bool {
    accounts.contains { $0.isDefault && !$0.archived && $0.groupId == group.id }
  }

  private func save() {
    switch actions.save(group: group) {
    case .done: finish(group.id)
    case .refused(let reason): refusal = reason
    case .failed: failed = true
    }
  }

  private func restoreFromArchive(_ id: UUID) {
    switch actions.restoreGroup(id) {
    case .done: finish(id)
    case .refused(let reason): refusal = reason
    case .failed: failed = true
    }
  }
}
