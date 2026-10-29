import AppCore
import SwiftUI

/// The screen of a bank (the tab of a bank): its accounts with their balances, the money of the
/// bank against the insurance limit, the credit cards in debt, the conditions the owner typed and
/// how far this month has used them, and the money nothing has moved on. A bank owns no money of
/// its own: every figure here is read from its accounts.
struct BankScreen: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies

  let bankId: UUID
  @State private var feesOpen = false
  @State private var forgottenOpen = false

  private func t(_ key: String) -> String { BankText.t(key, environment) }

  private var name: String {
    guard let dataset = compute.snapshot?.dataset else { return "" }
    if let bank = dataset.banks.first(where: { $0.id == bankId }) { return bank.name }
    return dataset.paymentMethods.first { BankLimits.bankKey($0) == bankId }?.name ?? ""
  }

  /// The live accounts of the bank, as the sidebar orders them.
  private var lines: [AccountsSnapshot.AccountLine] {
    guard let accounts = compute.snapshot?.planning.accounts else { return [] }
    return accounts.sections.flatMap(\.accounts).filter {
      !$0.account.archived && BankLimits.bankKey($0.account) == bankId
    }
  }

  private var insurance: BankInsurance? { compute.snapshot?.planning.banks.insurance(of: bankId) }

  private var creditCards: [CreditCardDebtLine] {
    guard let snapshot = compute.snapshot else { return [] }
    return CreditCardDebts.lines(
      states: snapshot.planning.creditCardStates, accounts: snapshot.planning.accounts,
      debts: snapshot.dataset.debts
    ).filter { $0.bankId == bankId }
  }

  private var forgotten: [ForgottenProduct] {
    let ids = Set(lines.map(\.account.id))
    return (compute.snapshot?.planning.banks.forgotten ?? []).filter { ids.contains($0.accountId) }
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        header
        if let insurance { insuranceCard(insurance) }
        accountsCard
        if !creditCards.isEmpty {
          CreditCardDebtCards(lines: creditCards) { id in
            NotificationCenter.default.post(
              name: .openSidebarItem, object: SidebarItem.account(id))
          }
        }
        ForEach(lines.map(\.account.id), id: \.self) { id in
          AccountConditionsBlock(accountId: id)
        }
        if !forgotten.isEmpty { forgottenCard }
        Button {
          feesOpen = true
        } label: {
          Label(t("bank.fees.open"), systemImage: "percent")
        }
        .accessibilityIdentifier("bank.fees.open")
      }
      .padding(20)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .accessibilityIdentifier("bank.screen")
    .sheet(isPresented: $feesOpen) { BankFeesSheet().handingOver(dependencies) }
    .sheet(isPresented: $forgottenOpen) { ForgottenMoneySheet().handingOver(dependencies) }
  }

  private var header: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: "building.columns").foregroundStyle(.secondary).accessibilityHidden(true)
      Text(verbatim: name).appFont(.title.bold()).accessibilityAddTraits(.isHeader)
      Spacer()
    }
  }

  private func insuranceCard(_ bank: BankInsurance) -> some View {
    ComputedBlock(
      title: t("bank.insurance.title"), state: .ready(bank, at: environment.now()), retry: nil
    ) { bank in
      VStack(alignment: .leading, spacing: 4) {
        let words = BankText.insuranceLines(bank, environment)
        Label {
          Text(verbatim: words[0]).monospacedDigit().fixedSize(horizontal: false, vertical: true)
        } icon: {
          Image(systemName: bank.isOver ? "exclamationmark.shield" : "checkmark.shield")
        }
        .foregroundStyle(bank.isOver ? AnyShapeStyle(.orange) : AnyShapeStyle(.primary))
        Text(verbatim: words[1]).monospacedDigit()
        Text(verbatim: words[2]).appFont(.caption).foregroundStyle(.secondary)
      }
    }
    .accessibilityIdentifier("bank.insurance")
  }

  private var accountsCard: some View {
    ComputedBlock(
      title: t("bank.screen.accounts"), state: .ready(lines.count, at: environment.now()),
      retry: nil
    ) { _ in
      VStack(alignment: .leading, spacing: 6) {
        if lines.isEmpty {
          Text(verbatim: t("bank.screen.noAccounts")).foregroundStyle(.secondary)
        }
        ForEach(lines, id: \.account.id) { line in
          Button {
            NotificationCenter.default.post(
              name: .openSidebarItem, object: SidebarItem.account(line.account.id))
          } label: {
            HStack {
              Label(line.account.name, systemImage: AccountText.kindSymbol(line.account.kind))
              Spacer()
              Text(verbatim: line.totalRub.map { environment.money.rounded($0) } ?? "—")
                .monospacedDigit()
            }
          }
          .buttonStyle(.plain)
        }
      }
    }
  }

  private var forgottenCard: some View {
    ComputedBlock(
      title: t("bank.forgotten.title"), state: .ready(forgotten, at: environment.now()),
      retry: nil
    ) { list in
      ForgottenRows(products: list)
      Button(t("bank.forgotten.title") + "…") { forgottenOpen = true }
        .buttonStyle(.borderless)
    }
    .accessibilityIdentifier("bank.forgotten")
  }
}
