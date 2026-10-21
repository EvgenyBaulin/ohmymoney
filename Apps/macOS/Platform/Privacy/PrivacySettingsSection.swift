import SwiftUI

/// Settings → «Основные» → «Конфиденциальность»: hiding the amounts, and the lock with its idle
/// time and its password. All are of this Mac (`AmountPrivacy`, `PrivacyLock`), never data of the
/// books. Turning the lock on asks Touch ID or the password of the Mac, then the app's password.
struct PrivacySettingsSection: View {
  @Dependency(\.environment) private var environment
  /// The lock the section shows: the app's own, unless a test hands one that answers as it says.
  var lockShown: PrivacyLock?
  @State private var passwordSheet: LockPasswordSheet.Purpose?

  var body: some View {
    @Bindable var amounts = environment.amounts
    @Bindable var lock = lockShown ?? environment.lock
    Section {
      Toggle(isOn: $amounts.hidesAmounts) {
        Text(verbatim: environment.language("settings.privacy.hideAmounts", table: "Settings"))
      }
      .accessibilityIdentifier("settings.privacy.hideAmounts")

      Toggle(
        isOn: Binding(
          get: { lock.isEnabled },
          set: { on in
            if on {
              let reason = environment.language("privacy.enable.reason")
              Task {
                if await lock.beginEnabling(reason: reason) { passwordSheet = .first }
              }
            } else {
              lock.disable()
            }
          })
      ) {
        Text(verbatim: environment.language("settings.privacy.lock", table: "Settings"))
      }
      .disabled(!lock.applies || lock.isAuthenticating)
      .accessibilityIdentifier("settings.privacy.lock")
      .sheet(item: $passwordSheet) {
        if !lock.isEnabled { lock.cancelEnabling() }
      } content: { purpose in
        // dependencies: none — the sheet is handed the lock and the language it reads.
        LockPasswordSheet(purpose: purpose, lock: lock, language: environment.language) {
          passwordSheet = nil
        }
      }

      Picker(selection: $lock.idleMinutes) {
        ForEach(PrivacyLock.idleChoices, id: \.self) { minutes in
          Text(
            verbatim: environment.language("settings.privacy.idle.\(minutes)", table: "Settings")
          )
          .tag(minutes)
        }
      } label: {
        Text(verbatim: environment.language("settings.privacy.idle", table: "Settings"))
      }
      .disabled(!lock.isEnabled)

      if lock.isEnabled {
        passwordRow(lock)
      }

      if !lock.isEnabled, let refusal = lock.lastRefusal,
        let key = Self.refusalKey(refusal)
      {
        Label {
          Text(verbatim: environment.language(key, table: "Settings"))
        } icon: {
          Image(systemName: "exclamationmark.octagon")
        }
        .foregroundStyle(.red)
      }
    } header: {
      Text(verbatim: environment.language("settings.privacy", table: "Settings"))
    } footer: {
      Text(
        verbatim: environment.language(
          lock.applies ? "settings.privacy.hint" : "settings.privacy.notInDataSet",
          table: "Settings")
      )
      .foregroundStyle(.secondary)
    }
  }

  /// The password of the lock: change or remove it, or set it where the lock was turned on before
  /// the app had one.
  @ViewBuilder
  private func passwordRow(_ lock: PrivacyLock) -> some View {
    LabeledContent {
      HStack {
        if lock.hasPassword {
          Button {
            passwordSheet = .change
          } label: {
            Text(
              verbatim: environment.language("settings.privacy.changePassword", table: "Settings"))
          }
          .accessibilityIdentifier("settings.privacy.changePassword")
          Button {
            lock.removePassword()
          } label: {
            Text(
              verbatim: environment.language("settings.privacy.removePassword", table: "Settings"))
          }
          .accessibilityIdentifier("settings.privacy.removePassword")
        } else {
          Button {
            passwordSheet = .change
          } label: {
            Text(
              verbatim: environment.language("settings.privacy.setPassword", table: "Settings"))
          }
          .accessibilityIdentifier("settings.privacy.setPassword")
        }
      }
    } label: {
      Text(verbatim: environment.language("settings.privacy.password", table: "Settings"))
      Text(
        verbatim: environment.language(
          lock.hasPassword ? "settings.privacy.passwordSet" : "settings.privacy.noPassword",
          table: "Settings"))
    }
    if lock.passwordProblem == .keychain, passwordSheet == nil {
      Label {
        Text(verbatim: environment.language("privacy.password.keychain"))
      } icon: {
        Image(systemName: "exclamationmark.octagon")
      }
      .foregroundStyle(.red)
    }
  }

  /// Why the lock stayed off; nothing after a cancel.
  static func refusalKey(_ refusal: LockAuthentication) -> String? {
    switch refusal {
    case .failed: "settings.privacy.lockRefused"
    case .unavailable: "settings.privacy.lockUnavailable"
    case .cancelled, .passed: nil
    }
  }
}
