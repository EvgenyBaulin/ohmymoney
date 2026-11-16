import AppCore
import SwiftUI

/// «+ → Кредитная карта» of a bank: the terms of the new credit card and its name. The limit is
/// required — «Создать» stays off until one is typed — and the account is made only on that
/// press, as one step of ⌘Z.
struct NewCreditCardSheet: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.store) private var store

  let bank: Bank
  /// Called once the sheet is done with: the id of the account made, `nil` when cancelled.
  let finish: (UUID?) -> Void

  @State private var draft = NewCreditCardDraft()
  @State private var refusal: AccountRefusal?
  @State private var failed = false

  private var actions: AccountActions { AccountActions(environment: environment, store: store) }
  private func t(_ key: String) -> String { environment.language(key, table: AccountText.table) }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(verbatim: environment.format("card.new.title", table: AccountText.table, bank.name))
        .appFont(.headline)
      Form {
        Section {
          NameField(
            title: t("card.new.name"), text: $draft.name,
            prompt: t("account.creditCard.defaultName"), identifier: "card.new.name")
        }
        AccountCreditSection(
          draft: $draft.credit, currency: environment.defaultCurrency, showsToggle: false)
      }
      .formStyle(.grouped)
      if let refusal {
        Text(verbatim: AccountText.message(refusal, environment))
          .appFont(.callout)
          .foregroundStyle(Color.red)
      }
      HStack {
        Spacer()
        Button(environment.language("action.cancel"), role: .cancel) { finish(nil) }
          .keyboardShortcut(.cancelAction)
        Button(t("card.new.confirm"), action: create)
          .keyboardShortcut(.defaultAction)
          .buttonStyle(.borderedProminent)
          .disabled(!draft.canCreate || store.isWritingInBackground)
          .accessibilityIdentifier("card.new.confirm")
      }
    }
    .padding(20)
    .sheetFrame(width: 520, height: 600)
    .refusedWriteAlert($failed, environment)
  }

  private func create() {
    guard case .success(let terms) = draft.terms() else { return }
    Task {
      guard let books = await actions.books() else {
        failed = true
        return
      }
      let made = actions.addCreditCard(to: bank, terms: terms, named: draft.name, books: books)
      switch made.outcome {
      case .done: finish(made.id)
      case .refused(let reason): refusal = reason
      case .failed: failed = true
      }
    }
  }
}
