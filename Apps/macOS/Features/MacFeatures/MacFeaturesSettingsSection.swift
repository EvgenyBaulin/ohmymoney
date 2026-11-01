import AppCore
import SwiftUI

/// Settings → «Приватность» → «За пределами приложения»: what the Mac shows outside the app's
/// windows. Spotlight is off until it is turned on here; the three kinds of notifications are on
/// until one is turned off. Habits of this Mac — `UserDefaults`, never the archive.
struct MacFeaturesSettingsSection: View {
  @Dependency(\.environment) private var environment
  @AppStorage(SpotlightIndexer.enabledKey) private var spotlight = false
  @AppStorage(MacNotifications.key(for: .payments)) private var payments = true
  @AppStorage(MacNotifications.key(for: .limits)) private var limits = true
  @AppStorage(MacNotifications.key(for: .summaries)) private var summaries = true

  private func t(_ key: String) -> String { environment.language(key, table: MacCommands.table) }

  var body: some View {
    Section {
      Toggle(isOn: $spotlight) {
        Text(verbatim: t("mac.settings.spotlight"))
        Text(verbatim: t("mac.settings.spotlight.hint"))
      }
      .accessibilityIdentifier("settings.mac.spotlight")
      .onChange(of: spotlight) { _, on in
        // Either way at once, not at the next change of the data: off empties the index.
        Task {
          if !on {
            await SpotlightIndexer.shared.turnOff()
          } else if let deps = AppLaunch.startedDependencies {
            await SpotlightIndexer.shared.refresh(deps)
          }
        }
      }
      Toggle(isOn: $payments) {
        Text(verbatim: t("mac.settings.payments"))
        Text(verbatim: t("mac.settings.payments.hint"))
      }
      .accessibilityIdentifier("settings.mac.payments")
      Toggle(isOn: $limits) { Text(verbatim: t("mac.settings.limits")) }
        .accessibilityIdentifier("settings.mac.limits")
      Toggle(isOn: $summaries) { Text(verbatim: t("mac.settings.summaries")) }
        .accessibilityIdentifier("settings.mac.summaries")
    } header: {
      Text(verbatim: t("mac.settings.title")).settingsHeaderStyle()
    } footer: {
      Text(verbatim: t("mac.settings.footer"))
        .appFont(.callout).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}
