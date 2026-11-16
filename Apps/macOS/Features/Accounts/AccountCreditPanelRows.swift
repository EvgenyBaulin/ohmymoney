import AppCore
import SwiftUI

/// The terms of a credit card in the panel of «Настройки → Счета»: the limit, the grace period
/// (the day of the statement and the days to pay it, or the days from a purchase), the rate of
/// purchases. Edited in place like the rest of the panel: a field is written when it is left or
/// Return is pressed, a choice at once; the other terms (cash, the minimum, the fee) stay in
/// «Все поля счёта…». `commit` gets the terms as a whole draft, to be read and saved.
struct AccountCreditPanelRows: View {
  @Dependency(\.environment) private var environment
  @Environment(\.appTheme) private var theme

  let account: PaymentMethod
  let commit: (CreditDraft) -> Void

  @State private var limit = ""
  @State private var rate = ""
  @FocusState private var focus: Field?

  private enum Field: Hashable { case limit, rate }

  private func t(_ key: String) -> String { environment.language(key, table: AccountText.table) }

  private var draft: CreditDraft { CreditDraft(account.credit) }

  var body: some View {
    VStack(alignment: .leading, spacing: AccountsTreeMetrics.panelGap) {
      field("account.credit.limit", text: $limit, field: .limit, unit: account.mainCurrency.code)
      choice(
        "account.credit.grace",
        value: draft.graceKind == .statement
          ? t("account.credit.grace.statement") : t("account.credit.grace.fromPurchase")
      ) {
        Button(t("account.credit.grace.statement")) { edit { $0.graceKind = .statement } }
        Button(t("account.credit.grace.fromPurchase")) { edit { $0.graceKind = .fromPurchase } }
      }
      switch draft.graceKind {
      case .statement:
        choice(
          "account.credit.statementDay",
          value: draft.statementDay == 31 ? t("account.credit.dayLast") : "\(draft.statementDay)"
        ) {
          ForEach(1...31, id: \.self) { day in
            Button(day == 31 ? t("account.credit.dayLast") : "\(day)") {
              edit { $0.statementDay = day }
            }
          }
        }
        choice(
          "account.credit.payDays.short", value: "\(draft.payDays)"
        ) {
          ForEach([10, 15, 20, 25, 30, 45, 60], id: \.self) { days in
            Button("\(days)") { edit { $0.payDays = days } }
          }
        }
      case .fromPurchase:
        choice("account.credit.purchaseDays.short", value: "\(draft.purchaseDays)") {
          ForEach([55, 100, 120, 145, 200, 365], id: \.self) { days in
            Button("\(days)") { edit { $0.purchaseDays = days } }
          }
        }
      }
      field("account.credit.purchaseRate", text: $rate, field: .rate, unit: "%")
    }
    .onAppear {
      limit = draft.limitText
      rate = draft.purchaseRateText
    }
    .onChange(of: focus) { old, _ in
      if old != nil { commitTexts() }
    }
  }

  private func edit(_ change: (inout CreditDraft) -> Void) {
    var next = draft
    change(&next)
    commit(next)
  }

  private func commitTexts() {
    guard limit != draft.limitText || rate != draft.purchaseRateText else { return }
    edit {
      $0.limitText = limit
      $0.purchaseRateText = rate
    }
    // A refused text stays typed until the owner fixes it; a written one is read back.
    limit = limit.trimmingCharacters(in: .whitespaces)
  }

  private func label(_ key: String) -> some View {
    Text(verbatim: t(key))
      .appFont(.callout)
      .foregroundStyle(theme.contentSecondary)
      .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func field(_ key: String, text: Binding<String>, field: Field, unit: String)
    -> some View
  {
    HStack(spacing: 6) {
      label(key)
      TextField(text: text) { Text(verbatim: t(key)) }
        .labelsHidden()
        .textFieldStyle(.plain)
        .multilineTextAlignment(.trailing)
        .appFont(AppFont.callout.weight(.medium).monospacedDigit())
        .focused($focus, equals: field)
        .onSubmit(commitTexts)
        .frame(maxWidth: 110)
        .accessibilityIdentifier("accounts.panel.\(key)")
      Text(verbatim: unit)
        .appFont(.footnote)
        .foregroundStyle(theme.contentSecondary)
    }
  }

  private func choice<Choices: View>(
    _ key: String, value: String, @ViewBuilder choices: () -> Choices
  ) -> some View {
    HStack(spacing: 6) {
      label(key)
      Menu {
        choices()
      } label: {
        HStack(spacing: 6) {
          Text(verbatim: value)
            .appFont(AppFont.callout.weight(.medium))
            .foregroundStyle(theme.contentPrimary)
            .lineLimit(1)
          Image(systemName: "chevron.down")
            .font(.system(size: 8, weight: .semibold))  // font-fixed: chevron in a 10 pt slot
            .foregroundStyle(theme.contentSecondary)
            .frame(width: 10, height: 10)
        }
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
      .accessibilityLabel(Text(verbatim: t(key)))
      .accessibilityValue(Text(verbatim: value))
      .accessibilityIdentifier("accounts.panel.\(key)")
    }
  }
}
