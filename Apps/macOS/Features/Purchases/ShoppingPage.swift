import AppCore
import SwiftUI

/// «Покупки»: the second list, for what is to be bought on the next trip to the shop. A line is
/// added by typing and Return, ticked with its box, and the ticked ones are cleared in one go.
struct ShoppingPage: View {
  @Dependency(\.environment) private var environment
  @Environment(\.dependencies) private var dependencies
  let page: PurchasesPage
  let report: (PurchaseOutcome) -> Void
  @State private var draft = ""
  @FocusState private var typing: Bool

  private func t(_ key: String) -> String { PurchasesText.t(key, environment) }

  private var doneCount: Int { page.shopping.filter(\.done).count }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        TextField(text: $draft) {
          Text(verbatim: t("purchases.shopping.add"))
        }
        .textFieldStyle(.roundedBorder)
        .focused($typing)
        .onSubmit(add)
        .accessibilityIdentifier("purchases.shopping.field")
        Button(t("purchases.shopping.addButton"), action: add)
          .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          .accessibilityIdentifier("purchases.shopping.addButton")
      }
      if page.shopping.isEmpty {
        Text(verbatim: t("purchases.shopping.empty"))
          .appFont(.callout)
          .foregroundStyle(.secondary)
          .contentCard()
          .accessibilityIdentifier("purchases.shopping.empty")
      } else {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(page.shopping) { item in
            row(item)
            if item.id != page.shopping.last?.id { Divider() }
          }
        }
        .contentCard()
        if doneCount > 0 {
          Button(PurchasesText.count("purchases.shopping.clear", environment, doneCount)) {
            if let dependencies { report(PurchaseActions(dependencies).clearDone()) }
          }
          .accessibilityIdentifier("purchases.shopping.clear")
        }
      }
    }
  }

  private func add() {
    guard let dependencies else { return }
    let outcome = PurchaseActions(dependencies).addShopping(draft)
    report(outcome)
    if outcome == .done { draft = "" }
    typing = true
  }

  private func row(_ item: ShoppingItem) -> some View {
    HStack(spacing: 10) {
      Button {
        if let dependencies { report(PurchaseActions(dependencies).setDone(item.id, !item.done)) }
      } label: {
        Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
      }
      .buttonStyle(.borderless)
      .accessibilityLabel(
        Text(verbatim: t(item.done ? "purchases.shopping.untick" : "purchases.shopping.tick"))
      )
      .accessibilityIdentifier("purchases.shopping.tick")
      VStack(alignment: .leading, spacing: 2) {
        Text(verbatim: item.name)
          .strikethrough(item.done)
          .foregroundStyle(item.done ? .secondary : .primary)
        if let note = item.note {
          Text(verbatim: note).appFont(.caption).foregroundStyle(.secondary)
        }
      }
      Spacer()
      Button {
        if let dependencies { report(PurchaseActions(dependencies).deleteShopping(item.id)) }
      } label: {
        Image(systemName: "xmark")
      }
      .buttonStyle(.borderless)
      .accessibilityLabel(Text(verbatim: t("purchases.shopping.remove")))
    }
    .padding(.vertical, 6)
    .accessibilityElement(children: .contain)
  }
}
