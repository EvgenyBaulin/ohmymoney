import AppCore
import SwiftUI

/// «Сделать кредиткой» of a card of a debit account: the terms of the credit card, what to do
/// with the operations the card already paid — all of them (the default), the ones from a day on,
/// or none — and the name when the card's own is taken. One write, one step of ⌘Z; the sheet
/// then hands the plan back so the screen offers to count both accounts.
struct CardToCreditCardSheet: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.store) private var store

  let card: PaymentCard
  /// Called once the sheet is done with: the plan that was written, `nil` when cancelled.
  let finish: (CreditCardConversionPlan?) -> Void

  @State private var draft: CardToCreditCardDraft
  @State private var failed = false

  init(
    card: PaymentCard, today: Date = Date(), finish: @escaping (CreditCardConversionPlan?) -> Void
  ) {
    self.card = card
    self.finish = finish
    _draft = State(initialValue: CardToCreditCardDraft(today: today))
  }

  private var actions: AccountActions { AccountActions(environment: environment, store: store) }
  private func t(_ key: String) -> String { environment.language(key, table: AccountText.table) }

  private var currency: CurrencyCode {
    actions.all.first { $0.id == card.accountId }?.mainCurrency ?? environment.defaultCurrency
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(verbatim: environment.format("card.toCredit.title", table: AccountText.table, card.name))
        .appFont(.headline)
      Text(verbatim: t("card.toCredit.message"))
        .appFont(.callout)
        .secondaryInk()
        .fixedSize(horizontal: false, vertical: true)
      Form {
        AccountCreditSection(draft: $draft.credit, currency: currency, showsToggle: false)
        Section {
          Picker(selection: $draft.past) {
            ForEach(CardToCreditCardDraft.Past.allCases, id: \.self) { choice in
              Text(verbatim: t(Self.key(of: choice))).tag(choice)
            }
          } label: {
            Text(verbatim: t("card.toCredit.past"))
          }
          .pickerStyle(.inline)
          .accessibilityIdentifier("card.toCredit.past")
          if draft.past == .fromDate {
            DatePicker(selection: $draft.fromDate, displayedComponents: .date) {
              Text(verbatim: t("card.toCredit.fromDate"))
            }
            .accessibilityIdentifier("card.toCredit.fromDate")
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
              identifier: "card.toCredit.name")
          } footer: {
            Text(verbatim: t("card.toCredit.nameHint")).secondaryInk()
          }
        }
      }
      .formStyle(.grouped)
      if let refusal = draft.refusal {
        Text(verbatim: AccountText.message(refusal, environment))
          .appFont(.callout)
          .foregroundStyle(Color.red)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("card.toCredit.refusal")
      }
      HStack {
        Spacer()
        Button(environment.language("action.cancel"), role: .cancel) { finish(nil) }
          .keyboardShortcut(.cancelAction)
        Button(t("card.toCredit.confirm"), action: confirm)
          .keyboardShortcut(.defaultAction)
          .buttonStyle(.borderedProminent)
          .disabled(store.isWritingInBackground)
          .accessibilityIdentifier("card.toCredit.confirm")
      }
    }
    .padding(20)
    .sheetFrame(width: 520, height: 640)
    .refusedWriteAlert($failed, environment)
  }

  static func key(of choice: CardToCreditCardDraft.Past) -> String {
    switch choice {
    case .all: "card.toCredit.past.all"
    case .fromDate: "card.toCredit.past.fromDate"
    case .none: "card.toCredit.past.none"
    }
  }

  private func confirm() {
    failed = false
    // The books of this moment: the card may have moved, been archived or renamed since.
    guard
      let plan = draft.attempt(
        converting: card, cards: actions.cards, accounts: actions.all,
        calendar: environment.calendar)
    else { return }
    switch actions.convert(plan) {
    case .done: finish(plan)
    case .refused: break
    case .failed: failed = true
    }
  }
}
