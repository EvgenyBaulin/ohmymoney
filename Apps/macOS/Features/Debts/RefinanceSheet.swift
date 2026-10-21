import AppCore
import AppDatabase
import SwiftUI

/// «Записать рефинансирование…»: a new loan paid this one off. The owner says what the new loan
/// is and the account the money came to and went from; «Записать» writes the new loan and the
/// full payment of this one in one write, one step of ⌘Z (`DebtActions.refinance`). A record of
/// something that happened — it compares nothing and proposes nothing.
struct RefinanceSheet: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies
  @Environment(\.dismiss) private var dismiss
  let debt: Debt

  @State private var name = ""
  @State private var amount: AmountE4 = .zero
  @State private var rate = ""
  @State private var monthly: AmountE4 = .zero
  @State private var paymentDay = 1
  @State private var accrues: Bool?
  @State private var day = Date()
  @State private var account: UUID?
  @State private var fee: AmountE4 = .zero
  @State private var loaded = false
  @State private var failed = false

  private func t(_ key: String) -> String { environment.language(key, table: "Debts") }

  private var accounts: [PaymentMethod] {
    (compute.snapshot?.dataset.paymentMethods ?? []).filter { !$0.archived }
  }

  /// The terms as typed; `nil` while the sheet cannot be saved.
  private var terms: DebtActions.Refinancing? {
    let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let parsed = Self.rate(rate)
    guard !title.isEmpty, amount.raw > 0, parsed.valid else { return nil }
    // A loan with a rate asks how the bank takes a payment (0353): no answer, no record.
    if parsed.value != nil, accrues == nil { return nil }
    return DebtActions.Refinancing(
      name: title, rate: parsed.value, monthlyPayment: monthly.raw > 0 ? monthly : nil,
      paymentDay: monthly.raw > 0 ? paymentDay : nil, accruesInterest: accrues ?? false,
      amount: amount, day: environment.calendar.day(of: day), account: account,
      fee: fee.raw > 0 ? fee : nil)
  }

  /// The rate typed: empty is no rate; a number of at least 0 is one; anything else is unread.
  static func rate(_ text: String) -> (value: Decimal?, valid: Bool) {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty { return (nil, true) }
    guard let value = TypedNumber.parse(trimmed), value >= 0 else { return (nil, false) }
    return (value, true)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(verbatim: environment.format("refinance.title", table: "Debts", debt.name))
        .appFont(.headline)
      Text(verbatim: t("refinance.explain"))
        .appFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      Form {
        TextField(t("refinance.name"), text: $name)
        LabeledContent(t("refinance.amount")) {
          HStack {
            AmountField(amount: $amount)
            Text(verbatim: debt.currency.code).foregroundStyle(.secondary)
          }
        }
        TextField(t("refinance.rate"), text: $rate).monospacedDigit()
        LabeledContent(t("refinance.monthly")) { AmountField(amount: $monthly) }
        if monthly.raw > 0 {
          Stepper(value: $paymentDay, in: 1...28) {
            Text(
              verbatim: environment.format(
                "refinance.paymentDay", table: "Debts", String(paymentDay)))
          }
        }
        if Self.rate(rate).value != nil {
          Picker(t("refinance.accrues"), selection: $accrues) {
            Text(verbatim: t("refinance.accrues.choose")).tag(Bool?.none)
            Text(verbatim: t("refinance.accrues.interestFirst")).tag(Bool?.some(true))
            Text(verbatim: t("refinance.accrues.allToDebt")).tag(Bool?.some(false))
          }
        }
        DatePicker(t("refinance.day"), selection: $day, displayedComponents: .date)
        AccountPicker(title: t("refinance.account"), accounts: accounts, selection: $account)
        LabeledContent(t("refinance.fee")) { AmountField(amount: $fee) }
      }
      .formStyle(.grouped)
      if failed {
        Text(verbatim: environment.language("form.notSaved", table: "Planning"))
          .appFont(.caption).foregroundStyle(.red)
      }
      HStack {
        Spacer()
        Button(environment.language("action.cancel")) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button(t("refinance.record")) { record() }
          .keyboardShortcut(.defaultAction)
          .buttonStyle(.borderedProminent)
          .disabled(terms == nil || dependencies == nil)
          .accessibilityIdentifier("debts.refinance.record")
      }
    }
    .padding(20)
    .sheetFrame(width: 480)
    .onAppear(perform: load)
  }

  private func load() {
    guard !loaded else { return }
    loaded = true
    name = environment.format("refinance.defaultName", table: "Debts", debt.name)
    account = accounts.first { $0.isDefault }?.id ?? accounts.first?.id
    if let dependencies, let owed = DebtActions(dependencies).payoff(of: debt), owed.raw > 0 {
      amount = owed
    }
    paymentDay = min(max(debt.paymentDay ?? environment.calendar.day(of: Date()).day, 1), 28)
  }

  private func record() {
    guard let dependencies, let terms else { return }
    if DebtActions(dependencies).refinance(debt, as: terms) {
      dismiss()
    } else {
      failed = true
    }
  }
}
