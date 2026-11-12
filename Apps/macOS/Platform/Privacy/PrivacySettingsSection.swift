#if os(macOS)
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
    cardBody
  }

  /// The design's card (Figma «Настройки · Основные», 52:625): hide the amounts, the lock with
  /// its hint, the idle time as a menu; the password of the lock (change, remove) comes after
  /// them when the lock is on. A row of Touch ID of its own the design draws has no setting
  /// behind it: Touch ID answers when the lock opens.
  private var cardBody: some View {
    @Bindable var amounts = environment.amounts
    @Bindable var lock = lockShown ?? environment.lock
    return SettingsCardGroup(
      title: g("settings.general.group.privacy"),
      footer: environment.language(
        lock.applies ? "settings.privacy.hint" : "settings.privacy.notInDataSet", table: "Settings")
    ) {
      SettingsCardRow(
        symbol: "eye.slash",
        title: environment.language("settings.privacy.hideAmounts", table: "Settings"),
        hint: g("settings.general.hideAmountsHint"), verticalPadding: 11
      ) {
        Toggle(isOn: $amounts.hidesAmounts) {
          Text(verbatim: environment.language("settings.privacy.hideAmounts", table: "Settings"))
        }
        .labelsHidden().toggleStyle(.switch)
        .accessibilityIdentifier("settings.privacy.hideAmounts")
      }
      SettingsCardRow(
        symbol: "lock", title: g("settings.general.lock"), hint: g("settings.general.lockHint"),
        verticalPadding: 11
      ) {
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
        ) { Text(verbatim: g("settings.general.lock")) }
        .labelsHidden().toggleStyle(.switch)
        .disabled(!lock.applies || lock.isAuthenticating)
        .accessibilityIdentifier("settings.privacy.lock")
      }
      .sheet(item: $passwordSheet) {
        if !lock.isEnabled { lock.cancelEnabling() }
      } content: { purpose in
        // dependencies: none — the sheet is handed the lock and the language it reads.
        LockPasswordSheet(purpose: purpose, lock: lock, language: environment.language) {
          passwordSheet = nil
        }
      }
      SettingsCardRow(
        symbol: "timer", title: g("settings.general.idle"),
        showsDivider: lock.isEnabled || lock.lastRefusal != nil
      ) {
        SettingsValueMenu(
          value: environment.language(
            "settings.privacy.idle.\(lock.idleMinutes)", table: "Settings")
        ) {
          Picker("", selection: $lock.idleMinutes) {
            ForEach(PrivacyLock.idleChoices, id: \.self) { minutes in
              Text(
                verbatim: environment.language(
                  "settings.privacy.idle.\(minutes)", table: "Settings")
              )
              .tag(minutes)
            }
          }
          .pickerStyle(.inline).labelsHidden()
          // Only the choices are switched off with the lock: a disabled menu label is dimmed
          // by the system below the contrast the value needs.
          .disabled(!lock.isEnabled)
        }
        .accessibilityIdentifier("settings.privacy.idle")
      }
      if lock.isEnabled {
        SettingsCardRow(
          symbol: "key", title: environment.language("settings.privacy.password", table: "Settings"),
          hint: environment.language(
            lock.hasPassword ? "settings.privacy.passwordSet" : "settings.privacy.noPassword",
            table: "Settings"),
          showsDivider: false, verticalPadding: 11
        ) {
          passwordButtons(lock)
        }
      }
      if let message = problemMessage(lock) {
        Label {
          Text(verbatim: message)
        } icon: {
          Image(systemName: "exclamationmark.octagon")
        }
        .foregroundStyle(.red)
        .padding(.horizontal, SettingsCardMetrics.rowHorizontal)
        .padding(.vertical, SettingsCardMetrics.compactVertical)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }

  private func g(_ key: String) -> String { environment.language(key, table: "SettingsGeneral") }

  private func problemMessage(_ lock: PrivacyLock) -> String? {
    if !lock.isEnabled, let refusal = lock.lastRefusal, let key = Self.refusalKey(refusal) {
      return environment.language(key, table: "Settings")
    }
    if lock.isEnabled, lock.passwordProblem == .keychain, passwordSheet == nil {
      return environment.language("privacy.password.keychain")
    }
    return nil
  }

  private func passwordButtons(_ lock: PrivacyLock) -> some View {
    HStack {
      if lock.hasPassword {
        Button(environment.language("settings.privacy.changePassword", table: "Settings")) {
          passwordSheet = .change
        }
        .accessibilityIdentifier("settings.privacy.changePassword")
        Button(environment.language("settings.privacy.removePassword", table: "Settings")) {
          lock.removePassword()
        }
        .accessibilityIdentifier("settings.privacy.removePassword")
      } else {
        Button(environment.language("settings.privacy.setPassword", table: "Settings")) {
          passwordSheet = .change
        }
        .accessibilityIdentifier("settings.privacy.setPassword")
      }
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
#endif
