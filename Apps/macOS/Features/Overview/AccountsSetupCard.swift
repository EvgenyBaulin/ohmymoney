import AppCore
import SwiftUI

/// The way back to the setup of the accounts after «Позже»: what is missing, and «Настроить
/// счета…», which opens the same sheet. Once the setup is done the card is gone.
///
/// The sheet does not hang here: the card is inside a row of the Overview list, and the card
/// goes away on «Готово» while the sheet is still on screen. It asks the window root, which
/// presents it (`AccountSetupOffer`).
struct AccountsSetupCard: View {
  @Dependency(\.environment) private var environment

  private func t(_ key: String) -> String { environment.language(key, table: "Onboarding") }

  /// The card shows only while the setup is put off.
  static func shows(setup: AccountSettings.Setup?) -> Bool {
    setup == .later
  }

  var body: some View {
    if Self.shows(setup: environment.accountSetup) {
      VStack(alignment: .leading, spacing: 8) {
        Text(verbatim: t("onboarding.card.title"))
          .appFont(.caption)
          .foregroundStyle(.secondary)
          .accessibilityAddTraits(.isHeader)
        Text(verbatim: t("onboarding.card.message"))
          .fixedSize(horizontal: false, vertical: true)
        // Content, not a floating control: a plain small button, never glass.
        Button(t("onboarding.card.action")) { AccountSetupRequest.shared.isRequested = true }
          .buttonStyle(.bordered)
          .controlSize(.small)
      }
      .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
      .contentCard()
      .accessibilityElement(children: .contain)
    }
  }
}
