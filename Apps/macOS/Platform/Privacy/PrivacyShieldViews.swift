import SwiftUI

/// «Показать скрытые» / «Скрыть»: the one row that brings the hidden accounts out and puts them
/// back. Shown only when the books hold a hidden account. Touch ID or the password of the Mac is
/// asked before they show; they stay shown until the lock covers the app again or «Скрыть» is
/// pressed.
struct HiddenAccountsRow: View {
  @Dependency(\.environment) private var environment

  var body: some View {
    let shield = environment.shield
    if shield.hasHiddenAccounts {
      Button {
        if shield.isRevealed {
          shield.cover()
        } else {
          Task { await environment.revealHiddenAccounts() }
        }
      } label: {
        Label {
          Text(verbatim: environment.language(title(shield), table: "PrivacyScreens"))
        } icon: {
          Image(systemName: shield.isRevealed ? "eye.slash" : "eye")
        }
      }
      .buttonStyle(.plain)
      .disabled(shield.isAuthenticating)
      .accessibilityIdentifier("sidebar.accounts.hidden")
    }
  }

  private func title(_ shield: PrivacyShield) -> String {
    shield.isRevealed ? "privacy.hidden.hide" : "privacy.hidden.show"
  }
}

/// The strip that stands in place of the entry line while the app is read-only.
struct ReadOnlyStrip: View {
  @Dependency(\.environment) private var environment

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: "lock.doc")
        .foregroundStyle(.secondary)
      Text(verbatim: environment.language("privacy.readOnly.banner", table: "PrivacyScreens"))
        .appFont(.callout)
      Spacer(minLength: 8)
      Button(environment.language("privacy.readOnly.exit", table: "PrivacyScreens")) {
        Task { await environment.setReadOnly(false) }
      }
      .disabled(environment.shield.isAuthenticating)
      .accessibilityIdentifier("readOnly.exit")
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .background(.background.secondary)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("readOnly.strip")
  }
}
