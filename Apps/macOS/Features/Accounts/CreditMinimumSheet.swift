import AppCore
import AppDatabase
import SwiftUI

struct CreditMinimumPrefill: Identifiable {
  var accountId: UUID
  var currency: CurrencyCode
  var statement: CreditStatement
  var id: DateOnly { statement.closesOn }
}

/// The statement's known minimum and deadline, with a way back to the card's estimate.
struct CreditMinimumSheet: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.store) private var store
  @Environment(\.dismiss) private var dismiss
  let prefill: CreditMinimumPrefill
  @State private var amount: AmountE4 = .zero
  @State private var due = Date()
  @State private var loaded = false
  @State private var failed = false

  private func t(_ key: String) -> String { environment.language(key, table: "Accounts") }
  private var dueDay: DateOnly { environment.calendar.day(of: due) }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(verbatim: t("account.credit.minimum.title")).appFont(.headline)
      Text(
        verbatim: environment.format(
          "account.credit.minimum.statement", table: "Accounts",
          environment.dates.longDay(prefill.statement.closesOn)))
      Form {
        LabeledContent(t("account.credit.minimum.amount")) {
          AmountField(amount: $amount)
        }
        DatePicker(t("account.credit.minimum.due"), selection: $due, displayedComponents: .date)
        if failed {
          Text(verbatim: t("account.credit.minimum.failed"))
            .foregroundStyle(.secondary)
        }
      }
      .formStyle(.grouped)
      HStack {
        Button(t("account.credit.minimum.estimate")) { save(nil) }
        Spacer()
        Button(t("account.credit.minimum.save")) {
          save(
            CreditStatementOverride(
              accountId: prefill.accountId, closesOn: prefill.statement.closesOn,
              minimumE4: amount, due: dueDay))
        }
        .disabled(
          amount.isNegative || amount > prefill.statement.debtE4
            || dueDay <= prefill.statement.closesOn)
      }
    }
    .padding(20)
    .sheetFrame(width: 460, height: 360)
    .onAppear {
      guard !loaded else { return }
      loaded = true
      amount = prefill.statement.minimumE4
      due = environment.calendar.noon(of: prefill.statement.due)
    }
  }

  private func save(_ value: CreditStatementOverride?) {
    let actions = AccountActions(environment: environment, store: store)
    if actions.saveCreditMinimum(
      value, accountId: prefill.accountId, closesOn: prefill.statement.closesOn)
    {
      dismiss()
    } else {
      failed = true
    }
  }
}

extension AccountActions {
  /// Writes only this financial setting; the change is one undo step and moves no money.
  func saveCreditMinimum(
    _ value: CreditStatementOverride?, accountId: UUID, closesOn: DateOnly
  ) -> Bool {
    guard let repository = environment.settings else { return false }
    do {
      let key = DebtSettings.statementOverridesKey
      let stored = try repository.string(key)
      let before = DebtSettings(storedValues: stored.map { [key: $0] } ?? [:])
      let settings = try CreditMinimumRules.saving(
        value, accountId: accountId, closesOn: closesOn, in: before)
      var change = PlanningChange()
      change.settings.updateValue(settings.storedValues[key] ?? nil, forKey: key)
      return apply(change) == .done
    } catch { return false }
  }
}
