import AppCore
import SwiftUI

/// «Добавить транш…» of a loan: the sum the bank paid for a term of tuition, its day — a day
/// still to come is a planned tranche —, the account it is filed under and a note. Saved as an
/// expense in «Образование» and the line that grows the debt, one write and one step of ⌘Z
/// (`DebtActions.addTranche`). System `Form`, no glass; the sheet closes only over a write that
/// landed.
struct TrancheSheet: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies
  @Environment(\.dismiss) private var dismiss
  let debt: Debt

  @State private var amount: AmountE4 = .zero
  @State private var date = Date()
  @State private var account: UUID?
  @State private var note = ""
  @State private var failed = false
  @State private var loaded = false

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(verbatim: environment.format("tranche.title", table: "Debts", debt.name))
        .appFont(.headline)
      Form {
        LabeledContent(t("form.amount")) {
          HStack {
            AmountField(amount: $amount)
            Text(verbatim: debt.currency.code).foregroundStyle(.secondary)
          }
        }
        DatePicker(t("form.date"), selection: $date, displayedComponents: .date)
        if Self.isPlanned(environment.calendar.day(of: date), today: environment.today) {
          Label {
            Text(verbatim: t("tranche.planned.hint"))
          } icon: {
            Image(systemName: "calendar.badge.clock")
          }
          .appFont(.caption).foregroundStyle(.secondary)
        }
        AccountPicker(
          title: environment.language("entry.account.from", table: "Entry"), accounts: accounts,
          selection: $account)
        TextField(t("form.description"), text: $note)
        Text(verbatim: t("tranche.hint"))
          .appFont(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
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
        Button(t("tranche.add")) { save() }
          .keyboardShortcut(.defaultAction)
          .buttonStyle(.borderedProminent)
          .disabled(amount.raw <= 0 || dependencies == nil)
      }
    }
    .padding(20)
    .sheetFrame(width: 440)
    .onAppear {
      guard !loaded else { return }
      loaded = true
      account = FormAccounts.account(nil, among: accounts)?.id
    }
  }

  /// A tranche dated after today is a planned one: the schedule counts it, the balance takes it
  /// on its day.
  static func isPlanned(_ day: DateOnly, today: DateOnly) -> Bool { day > today }

  private func save() {
    guard let dependencies else { return }
    let written = DebtActions(dependencies).addTranche(
      debt, amount: amount, on: environment.calendar.day(of: date), account: account,
      note: note.isEmpty ? nil : note)
    if written {
      dismiss()
    } else {
      failed = true
    }
  }

  private var accounts: [PaymentMethod] {
    (compute.snapshot?.dataset.paymentMethods ?? []).filter { !$0.archived }
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Debts") }
}
