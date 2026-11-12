import AppCore
import SwiftUI

/// The debt burden the way a bank reads it, under the debt load of the advice: without the
/// instalments, with them, and over nine tenths of the income. A guide, never the bank's verdict.
struct BankPdnView: View {
  @Dependency(\.environment) private var environment
  let pdn: BankPdn

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(verbatim: BanksRuText.t("banksRu.pdn.title", environment))
        .appFont(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
      ForEach(Array(BanksRuText.pdnLines(pdn, environment).enumerated()), id: \.offset) {
        _, line in
        Text(verbatim: line)
          .appFont(.caption.monospacedDigit())
          .fixedSize(horizontal: false, vertical: true)
      }
      Text(verbatim: BanksRuText.t("banksRu.pdn.hint", environment))
        .appFont(.caption)
        .foregroundStyle(.tertiary)
    }
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("advice.load.bankPdn")
  }
}
