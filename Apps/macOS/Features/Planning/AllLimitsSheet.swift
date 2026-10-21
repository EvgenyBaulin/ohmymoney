import AppCore
import SwiftUI

/// Every limit of the month, over Planning, in the one order of the lists of limits — over the
/// limit, then close to it, then by the share spent. Each amount is edited in place the way
/// the Planning block edits it (Enter saves one step of ⌘Z, Esc puts it back); the menu of a
/// row opens the form or deletes the limit. A limit of an archived category is not listed.
struct AllLimitsSheet: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies
  @Environment(\.dismiss) private var dismiss
  /// The limit whose amount is being typed, and why its last Enter was refused.
  @State private var editing: UUID?
  @State private var refusal: String?
  /// The form of a limit, opened from a row's menu over this sheet.
  @State private var form: EditedLimit?
  /// A limit asked to be deleted: the confirmation comes first.
  @State private var deleting: Budget?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(verbatim: t("limits.allTitle")).appFont(.headline)
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          if let snapshot = compute.snapshot {
            let lines = LimitLists.ranked(snapshot, environment, all: true).shown
            if lines.isEmpty {
              Text(verbatim: t("limits.none")).foregroundStyle(.secondary)
            }
            ForEach(lines, id: \.budget.id) { line in
              LimitRow(
                line: line, tree: snapshot.ledger.tree,
                editing: LimitAmountEditing(
                  editing: $editing, refusal: $refusal,
                  save: { budget, text in save(budget, text) }),
                edit: { form = EditedLimit(budget: $0) }, delete: { deleting = $0 })
              Divider()
            }
          } else {
            Text(verbatim: environment.language("common.calculating"))
              .foregroundStyle(.secondary)
          }
        }
        .padding(.trailing, 8)
      }
      .frame(minHeight: 160, maxHeight: 440)
      HStack {
        Spacer()
        // While an amount is typed, Esc belongs to its field: it puts the amount back rather
        // than closing the sheet with the field in it.
        Button(environment.language("action.close")) { dismiss() }
          .keyboardShortcut(editing == nil ? .cancelAction : nil)
      }
    }
    .padding(20)
    .sheetFrame(width: 540)
    .sheet(item: $form) { item in
      BudgetForm(original: item.budget)
        .handingOver(dependencies)
    }
    .confirmationDialog(
      t("limits.deleteTitle"),
      isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
      titleVisibility: .visible, presenting: deleting
    ) { budget in
      Button(environment.language("action.delete"), role: .destructive) {
        if let dependencies { PlanningActions(dependencies).delete(budget) }
      }
    }
  }

  private func save(_ budget: Budget, _ text: String) -> String? {
    guard let dependencies else { return t("form.notSaved") }
    return LimitWrites.changeAmount(of: budget, typed: text, deps: dependencies).map(t)
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Planning") }
}

/// A limit whose form is open over the sheet of all limits.
private struct EditedLimit: Identifiable {
  let budget: Budget
  var id: UUID { budget.id }
}
