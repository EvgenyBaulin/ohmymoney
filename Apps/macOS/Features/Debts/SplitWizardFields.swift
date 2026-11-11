import AppCore
import SwiftUI

/// Service terms generate a schedule; every generated amount and date can be corrected.
struct SplitWizardFields: View {
  @Dependency(\.environment) private var environment
  @Binding var model: DebtWizardModel

  private func t(_ key: String) -> String { environment.language(key, table: "Debts") }

  var body: some View {
    Section {
      LabeledContent(t("split.payment")) { AmountField(amount: $model.monthly) }
      Stepper(value: $model.parts, in: 2...120) {
        Text(verbatim: environment.format("wizard.parts", table: "Debts", String(model.parts)))
      }
      DatePicker(t("split.firstDue"), selection: firstBinding, displayedComponents: .date)
      Picker(t("wizard.step.every"), selection: $model.everyTwoWeeks) {
        Text(verbatim: t("wizard.every.twoWeeks")).tag(true)
        Text(verbatim: t("wizard.every.month")).tag(false)
      }
      Button(t("split.generate")) { model.splitPayments = [] }
      Text(verbatim: t("split.accountingHint"))
        .appFont(.caption).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    Section(t("split.schedule")) {
      ForEach(Array(model.splitRows.indices), id: \.self) { index in
        paymentRow(index)
      }
      if !model.splitIsValid {
        Text(verbatim: t("split.invalid"))
          .appFont(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private var firstBinding: Binding<Date> {
    Binding(
      get: { environment.calendar.noon(of: model.splitFirstDue) },
      set: { model.splitFirstDue = environment.calendar.day(of: $0) })
  }

  private func row(at index: Int) -> SplitPayment {
    let rows = model.splitRows
    return rows.indices.contains(index)
      ? rows[index] : SplitPayment(day: model.splitFirstDue, amountE4: .zero)
  }

  private func paymentRow(_ index: Int) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      DatePicker(
        environment.format("split.number", table: "Debts", String(index + 1)),
        selection: Binding(
          get: { environment.calendar.noon(of: row(at: index).day) },
          set: { date in
            var rows = model.splitRows
            guard rows.indices.contains(index) else { return }
            rows[index].day = environment.calendar.day(of: date)
            model.splitRows = rows
          }), displayedComponents: .date)
      AmountField(
        amount: Binding(
          get: { row(at: index).amountE4 },
          set: { amount in
            var rows = model.splitRows
            guard rows.indices.contains(index) else { return }
            rows[index].amountE4 = amount
            model.splitRows = rows
          }))
    }
  }
}
