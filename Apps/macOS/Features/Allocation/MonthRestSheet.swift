import AppCore
import SwiftUI

/// «Остаток сентября — X»: what is left of the month just past, put on the cushion's account or
/// into a goal. Where to is filled in — the cushion while its goal is not reached, else the last
/// choice —, or asked and remembered. «Не надо» puts the offer away for the month. One record
/// and one step of ⌘Z either way.
struct MonthRestSheet: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies
  @Environment(\.dismiss) private var dismiss
  let offer: MonthRestOffer

  @State private var target: MonthRestTarget?
  @State private var amount: AmountE4 = .zero
  @State private var cushionAccount: UUID?
  @State private var started = false

  var body: some View {
    let snapshot = compute.snapshot
    let goals = (snapshot?.dataset.goals ?? []).filter { !$0.archived }
    let cushionAccounts = (snapshot?.dataset.paymentMethods ?? []).filter {
      $0.cushion && !$0.archived
    }
    VStack(alignment: .leading) {
      Text(
        verbatim: AllocationText.format(
          "monthRest.title", environment, environment.dates.monthTitle(offer.month),
          environment.money.rounded(offer.amountE4))
      )
      .appFont(.headline)
      Form {
        Picker(AllocationText.t("monthRest.where", environment), selection: $target) {
          if !cushionAccounts.isEmpty {
            Text(verbatim: AllocationText.t("allocation.line.cushion", environment))
              .tag(MonthRestTarget?.some(.cushion))
          }
          ForEach(goals) { goal in
            Text(verbatim: goal.name).tag(MonthRestTarget?.some(.goal(goal.id)))
          }
        }
        if target == .cushion, cushionAccounts.count > 1 {
          Picker(
            AllocationText.t("allocation.line.cushionAccount", environment),
            selection: $cushionAccount
          ) {
            ForEach(cushionAccounts) { account in
              Text(verbatim: account.name).tag(UUID?.some(account.id))
            }
          }
        }
        LabeledContent(AllocationText.t("monthRest.amount", environment)) {
          HStack {
            AmountField(amount: $amount).frame(width: 120)
            Text(verbatim: environment.money.symbol(for: .rub)).foregroundStyle(.secondary)
          }
        }
        Text(verbatim: AllocationText.t("monthRest.hint", environment))
          .appFont(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .formStyle(.grouped)
      HStack {
        Button(AllocationText.t("allocation.decline", environment)) {
          guard let dependencies else { return }
          if AllocationActions(dependencies).decline(offer) { dismiss() }
        }
        Spacer()
        Button(environment.language("action.cancel")) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button(AllocationText.t("allocation.write", environment)) {
          guard let dependencies, let target else { return }
          if AllocationActions(dependencies).allocate(
            offer, to: target, amount: amount, cushionAccount: cushionAccount)
          {
            dismiss()
          }
        }
        .keyboardShortcut(.defaultAction)
        .disabled(target == nil || amount.raw <= 0 || (target == .cushion && cushionAccount == nil))
      }
    }
    .padding(20)
    .sheetFrame(width: 420, height: 340)
    .onAppear {
      guard !started else { return }
      started = true
      amount = offer.amountE4
      target = offer.target
      if let snapshot {
        cushionAccount =
          Allocation.cushionAccount(
            dataset: snapshot.dataset, settings: snapshot.dataset.allocationSettings,
            cushion: snapshot.planning.cushion) ?? cushionAccounts.first?.id
      }
    }
  }
}
