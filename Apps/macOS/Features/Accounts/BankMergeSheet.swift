import AppCore
import SwiftUI

/// «Объединить с…» of a bank, asked before it is made: with which live bank, which accounts move
/// under it — archived ones too —, that no money moves and no account changes its name, and that
/// ⌘Z brings the bank back. One write and one step of ⌘Z.
struct BankMergeSheet: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.store) private var store

  let bank: Bank
  /// Called once the sheet is done with: whether the banks were merged.
  let finish: (Bool) -> Void

  @State private var target: UUID?
  @State private var refusal: AccountRefusal?
  @State private var failed = false

  private var actions: AccountActions { AccountActions(environment: environment, store: store) }
  private func t(_ key: String) -> String { environment.language(key, table: AccountText.table) }

  var body: some View {
    let targets = actions.mergeTargets(for: bank)
    let selected = target ?? targets.first?.id
    let plan = selected.flatMap { try? actions.bankMergePlan(bank.id, into: $0).get() }
    VStack(alignment: .leading, spacing: 12) {
      Text(
        verbatim: environment.format("bank.merge.title", table: AccountText.table, bank.name)
      )
      .appFont(.headline)
      Form {
        Picker(selection: Binding(get: { selected }, set: { target = $0 })) {
          ForEach(targets) { bank in
            Text(verbatim: bank.name).tag(Optional(bank.id))
          }
        } label: {
          Text(verbatim: t("bank.merge.into"))
        }
        .accessibilityIdentifier("bank.merge.into")
        if let plan {
          Section {
            line(
              environment.format(
                "bank.merge.message", table: AccountText.table, plan.merged.name,
                plan.kept.name))
            if plan.movedAccounts.isEmpty {
              line(t("bank.merge.noAccounts"))
            } else {
              line(
                environment.format(
                  "bank.merge.accounts", table: AccountText.table,
                  counts: plan.movedAccounts.count))
              line(names(plan.movedAccounts))
                .foregroundStyle(.secondary)
            }
            line(t("bank.merge.money"))
            line(t("bank.merge.undo"))
          }
        }
      }
      .formStyle(.grouped)

      if let refusal {
        AccountRefusalNote(refusal: refusal)
      }
      HStack {
        Spacer()
        Button(environment.language("action.cancel"), role: .cancel) { finish(false) }
          .keyboardShortcut(.cancelAction)
        Button(t("bank.merge.confirm")) { merge(into: selected) }
          .keyboardShortcut(.defaultAction)
          .buttonStyle(.borderedProminent)
          .disabled(selected == nil || store.isWritingInBackground)
      }
    }
    .padding(20)
    .sheetFrame(width: 480, height: 460)
    .refusedWriteAlert($failed, environment)
  }

  private func line(_ text: String) -> Text {
    Text(verbatim: text)
  }

  /// The accounts that move, in list order, an archived one said so.
  private func names(_ accounts: [PaymentMethod]) -> String {
    let locale = environment.language.locale
    let live = AccountRules.ordered(accounts, locale: locale).map(\.name)
    let archived = accounts.filter(\.archived).map {
      environment.format("bank.merge.archivedAccount", table: AccountText.table, $0.name)
    }
    return (live + archived).joined(separator: ", ")
  }

  private func merge(into keptId: UUID?) {
    guard let keptId else { return }
    refusal = nil
    failed = false
    switch actions.mergeBank(bank.id, into: keptId) {
    case .done: finish(true)
    case .refused(let reason): refusal = reason
    case .failed: failed = true
    }
  }
}
