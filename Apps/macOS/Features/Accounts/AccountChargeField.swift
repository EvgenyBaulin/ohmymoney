import AppCore
import SwiftUI

/// «Списано со счёта»: what the account was charged for an operation in a currency it does not
/// hold, in the account's main currency — 12 $ on a ruble card is the rubles the bank took.
///
/// Prefilled from the bank's rates (through rubles for two foreign currencies) and editable:
/// the figure from the statement is the one to keep, and a typed one stays while the account is
/// charged in the same currency — once the amount, currency, day or account it was typed for
/// changes, it says it was not worked out again. A prefill resting on a rate the bank has not
/// published for the day yet says «предварительно» in words and with a symbol, and the help
/// says to check the statement. An empty field means no rate was found: the figure has to be
/// typed.
struct AccountChargeField: View {
  @Dependency(\.environment) private var environment
  @Bindable var model: EntryDraftModel
  /// The notes under the field rather than beside it: a narrow column has no room for them.
  var stacked = false

  private var layout: AnyLayout {
    stacked
      ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
      : AnyLayout(HStackLayout(spacing: 8))
  }

  var body: some View {
    layout {
      HStack(spacing: 8) {
        AmountField(
          amount: Binding(
            get: { model.draft.accountAmount ?? .zero },
            set: { model.setCharge($0) })
        )
        .frame(width: stacked ? nil : 140)
        .accessibilityLabel(Text(verbatim: t("entry.accountCharge")))
        .accessibilityIdentifier("entry.accountCharge")
        if let currency = model.draft.accountCurrency {
          Text(verbatim: currency.code)
            .foregroundStyle(.secondary)
        }
      }
      if model.chargeIsProvisional {
        Label {
          Text(verbatim: t("entry.accountCharge.provisional"))
        } icon: {
          Image(systemName: "hourglass")
        }
        .appFont(.caption)
        .foregroundStyle(.secondary)
        .help(t("entry.accountCharge.provisionalHelp"))
      }
      // Typed for another amount, currency, day or account: kept, and said so in words.
      if model.chargeNeedsCheck {
        Label {
          Text(verbatim: t("entry.accountCharge.check"))
        } icon: {
          Image(systemName: "exclamationmark.triangle")
        }
        .appFont(.caption)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("entry.accountCharge.check")
      }
    }
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Entry") }
}
