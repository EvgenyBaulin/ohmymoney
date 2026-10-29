import AppCore
import SwiftUI

/// «Страхование вкладов» in the capital: the banks that hold more of the owner's money than the
/// insurance covers, each with the limit on its date. Nothing is shown while every bank is within
/// it. A symbol and words say it, never colour alone.
struct CapitalInsuranceSection: View {
  @Dependency(\.environment) private var environment
  let banks: [BankInsurance]

  private var over: [BankInsurance] { banks.filter(\.isOver) }

  var body: some View {
    if !over.isEmpty {
      ComputedBlock(
        title: BankText.t("bank.insurance.title", environment),
        state: .ready(over, at: environment.now()), retry: nil
      ) { over in
        VStack(alignment: .leading, spacing: 10) {
          ForEach(over) { bank in
            Button {
              NotificationCenter.default.post(
                name: .openSidebarItem, object: SidebarItem.bank(bank.bankId))
            } label: {
              VStack(alignment: .leading, spacing: 2) {
                let words = BankText.insuranceLines(bank, environment)
                Label {
                  Text(verbatim: bank.name).fontWeight(.medium)
                } icon: {
                  Image(systemName: "exclamationmark.shield")
                }
                .foregroundStyle(.orange)
                Text(verbatim: words[0]).monospacedDigit()
                Text(verbatim: words[1]).monospacedDigit()
                Text(verbatim: words[2]).appFont(.caption).foregroundStyle(.secondary)
              }
            }
            .buttonStyle(.plain)
          }
        }
      }
      .accessibilityIdentifier("capital.insurance")
    }
  }
}
