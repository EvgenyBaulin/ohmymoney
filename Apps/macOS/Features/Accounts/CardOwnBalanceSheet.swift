import AppCore
import SwiftUI

struct CardOwnBalanceSheet: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.store) private var store
  let card: PaymentCard
  let finish: (CreditCardConversionPlan?) -> Void

  @State private var draft: CardOwnBalanceDraft
  @State private var failed = false

  init(
    card: PaymentCard, today: Date = Date(), finish: @escaping (CreditCardConversionPlan?) -> Void
  ) {
    self.card = card
    self.finish = finish
    _draft = State(initialValue: CardOwnBalanceDraft(today: today))
  }

  private func t(_ key: String) -> String { environment.language(key, table: AccountText.table) }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(verbatim: t("card.ownBalance.title")).appFont(.headline)
      Text(verbatim: t("card.ownBalance.message"))
        .appFont(.callout).secondaryInk().fixedSize(horizontal: false, vertical: true)
      Form {
        Section {
          Picker(selection: $draft.past) {
            ForEach(CardToCreditCardDraft.Past.allCases, id: \.self) { choice in
              Text(verbatim: t(CardToCreditCardSheet.key(of: choice))).tag(choice)
            }
          } label: {
            Text(verbatim: t("card.toCredit.past"))
          }
          .pickerStyle(.inline)
          .accessibilityIdentifier("card.ownBalance.past")
          if draft.past == .fromDate {
            DatePicker(selection: $draft.fromDate, displayedComponents: .date) {
              Text(verbatim: t("card.toCredit.fromDate"))
            }
          }
        } header: {
          Text(verbatim: t("card.toCredit.pastHeader"))
        } footer: {
          Text(verbatim: t("card.toCredit.pastHint")).secondaryInk()
        }
        if draft.asksForName {
          Section {
            NameField(
              title: t("card.toCredit.name"), text: $draft.name, prompt: card.name,
              identifier: "card.ownBalance.name")
          }
        }
      }
      .formStyle(.grouped)
      if let refusal = draft.refusal {
        Text(verbatim: message(refusal))
          .appFont(.callout).foregroundStyle(Color.red)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("card.ownBalance.refusal")
      }
      HStack {
        Spacer()
        Button(environment.language("action.cancel"), role: .cancel) { finish(nil) }
          .keyboardShortcut(.cancelAction)
        Button(t("card.ownBalance.confirm"), action: confirm)
          .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
          .disabled(store.isWritingInBackground)
          .accessibilityIdentifier("card.ownBalance.confirm")
      }
    }
    .padding(20)
    .sheetFrame(width: 520, height: 480)
    .refusedWriteAlert($failed, environment)
  }

  private func message(_ issue: CardOwnBalanceIssue) -> String {
    switch issue {
    case .conversion(let reason): AccountText.message(.conversion(reason), environment)
    case .alreadyOwnBalance, .accountIdInUse: t("card.ownBalance.unavailable")
    }
  }

  private func confirm() {
    let actions = AccountActions(environment: environment, store: store)
    guard
      let plan = draft.attempt(
        separating: card, cards: actions.cards, accounts: actions.all,
        calendar: environment.calendar)
    else { return }
    switch actions.convert(plan) {
    case .done: finish(plan)
    case .failed: failed = true
    case .refused: break
    }
  }
}
