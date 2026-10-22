import AppCore
import AppDatabase
import SwiftUI

/// The costs of a loan on its card and what it really costs (`DebtCostReport`): the fees and
/// insurance with how often they are paid, the overpay, the real rate and a word when it
/// disagrees with the contract's full cost of credit by more than half a point.
struct DebtCostSection: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies
  let line: DebtLine

  var body: some View {
    let costs = (compute.snapshot?.dataset.debtCosts ?? []).filter { $0.debtId == line.debt.id }
    let report = Self.report(line, costs: costs, calendar: environment.calendar)
    if !costs.isEmpty || report != nil {
      VStack(alignment: .leading, spacing: 4) {
        Text(verbatim: t("costs.honest")).appFont(.headline)
          .accessibilityAddTraits(.isHeader)
        if let report {
          DebtFactRow(
            label: t("costs.borrowed"),
            value: environment.money.exact(report.principalE4, currency: line.debt.currency))
        }
        ForEach(costs) { cost in
          HStack {
            Text(verbatim: cost.name ?? t("costs.kind.\(cost.kind.rawValue)"))
            Text(verbatim: t("costs.every.\(cost.every.rawValue)")).foregroundStyle(.secondary)
            if cost.inLoan {
              Text(verbatim: t("costs.inLoan.short")).foregroundStyle(.secondary)
            }
            Spacer()
            Text(verbatim: environment.money.exact(cost.amountE4, currency: line.debt.currency))
              .monospacedDigit()
            Button(role: .destructive) {
              if let dependencies { DebtActions(dependencies).removeCost(cost) }
            } label: {
              Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(t("costs.remove"))
          }
          .appFont(.callout)
        }
        if let report {
          if report.interestE4.raw > 0 {
            DebtFactRow(
              label: t("costs.interest"),
              value: "+" + environment.money.exact(report.interestE4, currency: line.debt.currency))
          }
          Divider()
          DebtFactRow(
            label: t("costs.total"),
            value: environment.money.exact(Self.total(report), currency: line.debt.currency),
            bold: true)
          DebtCostLines(report: report, currency: line.debt.currency)
            .foregroundStyle(.secondary)
        }
      }
      .contentCard()
      .accessibilityIdentifier("debts.costs")
    }
  }

  /// «Вернёте всего»: every payment and every fee, the principal included.
  static func total(_ report: DebtCostReport) -> AmountE4 {
    report.paymentsE4 + report.costsOnceE4 + report.costsPeriodicE4
  }

  /// The true cost of the loan of `line` from its first due: the money drawn, at its rate and
  /// the sum of its first due; `nil` for a loan without a rate or a sum.
  static func report(
    _ line: DebtLine, costs: [DebtCost], calendar: CalendarContext
  ) -> DebtCostReport? {
    let debt = line.debt
    guard let rate = debt.interestRate, rate > 0, let firstDue = line.dues.firstDue else {
      return nil
    }
    let payment = line.dues.knowing(debt).amount(ofDue: 0)
    let drawn = AmountE4.sum(
      line.entries.filter { $0.amountE4.raw > 0 && $0.kind != .payment }.map(\.amountE4))
    guard payment.raw > 0, drawn.raw > 0 else { return nil }
    let schedule = DebtAmortization.schedule(
      principal: drawn, percent: rate, payment: payment, firstDue: firstDue,
      paymentDay: line.dues.paymentDay)
    let start =
      line.entries.filter { $0.amountE4.raw > 0 && $0.kind != .payment }.compactMap(\.date).min()
      ?? firstDue.adding(months: -1)
    return DebtCostReport.report(
      debt: debt, borrowedE4: drawn, costs: costs, schedule: schedule, paidE4: .zero,
      firstDay: start)
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Debts") }
}

/// «Комиссии и страховка…» of a loan: the costs to add, and its full cost of credit from the
/// contract. One write, one step of ⌘Z.
struct DebtCostsSheet: View {
  @Dependency(\.environment) private var environment
  @Environment(\.dependencies) private var dependencies
  @Environment(\.dismiss) private var dismiss
  let debt: Debt

  @State private var costs: [DebtWizardModel.CostDraft] = [DebtWizardModel.CostDraft()]
  @State private var day = Date()
  @State private var pskText = ""
  @State private var failed = false

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(verbatim: environment.format("costs.sheet.title", table: "Debts", debt.name))
        .appFont(.headline)
      Form {
        ForEach($costs) { $cost in
          CostRow(cost: $cost, currency: debt.currency) {
            costs.removeAll { $0.id == cost.id }
          }
        }
        Button(t("costs.add")) { costs.append(DebtWizardModel.CostDraft()) }
        DatePicker(t("costs.day"), selection: $day, displayedComponents: .date)
        TextField(t("wizard.psk"), text: $pskText)
        Text(verbatim: t("costs.hint"))
          .appFont(.caption).foregroundStyle(.secondary).fixedSize(
            horizontal: false, vertical: true)
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
        Button(t("form.save")) { save() }
          .keyboardShortcut(.defaultAction)
          .buttonStyle(.borderedProminent)
          .disabled(dependencies == nil)
      }
    }
    .padding(20)
    .sheetFrame(width: 480)
    .onAppear { pskText = debt.psk.map { environment.money.number($0) } ?? "" }
  }

  private func save() {
    guard let dependencies else { return }
    let actions = DebtActions(dependencies)
    let costDay = environment.calendar.day(of: day)
    let written = costs.filter { $0.amount.raw > 0 }.enumerated().map { index, cost in
      DebtCost(
        id: cost.id, debtId: debt.id, kind: cost.kind, amountE4: cost.amount, every: cost.every,
        day: costDay, inLoan: cost.every == .once && cost.inLoan, sort: index)
    }
    let psk = DebtPayoff.parseRate(pskText)
    var changed = debt
    changed.psk = psk
    if written.isEmpty && psk == debt.psk {
      dismiss()
      return
    }
    if actions.addCosts(changed, costs: written, savingDebt: psk != debt.psk) {
      dismiss()
    } else {
      failed = true
    }
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Debts") }
}
