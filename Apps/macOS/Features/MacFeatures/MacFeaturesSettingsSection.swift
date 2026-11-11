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
  @AppStorage(MacNotifications.key(for: .evening)) private var evening = true
  @AppStorage(MacNotifications.privacyKey) private var privacy = NotificationPlan.Privacy.standard
    .rawValue

  private func t(_ key: String) -> String { environment.language(key, table: MacCommands.table) }

  var body: some View {
    #if os(macOS)
      macBody
    #else
      formBody
    #endif
  }

  #if os(macOS)
    /// The design's card (Figma 61:67007): a title of 13 semibold, then rows of 16 × 11 — name
    /// 13 medium over a hint 11, the switch at the right — and the last row the choice of what a
    /// notification says, in the accent.
    private var macBody: some View {
      Section {
        VStack(alignment: .leading, spacing: 8) {
          Text(verbatim: t("mac.settings.title"))
            .appFont(AppFont.body.weight(.semibold))
          SettingsCard {
            switchRow("mac.settings.spotlight", hint: "mac.settings.spotlight.hint", $spotlight)
              .onChange(of: spotlight) { _, on in
                Task {
                  if !on {
                    await SpotlightIndexer.shared.turnOff()
                  } else if let deps = AppLaunch.startedDependencies {
                    await SpotlightIndexer.shared.refresh(deps)
                  }
                }
              }
            switchRow("mac.settings.payments", hint: "mac.settings.payments.hint", $payments)
            switchRow("mac.settings.limits", hint: nil, $limits)
            switchRow("mac.settings.summaries", hint: nil, $summaries)
            switchRow("mac.settings.evening", hint: nil, $evening)
              .onChange(of: evening) { _, _ in HabitNudgeRoute.route(HabitNudgeRoute.lastAsked) }
            SettingsCardRow(title: t("mac.settings.privacy"), showsDivider: false, compact: true) {
              Picker(selection: $privacy) {
                ForEach(NotificationPlan.Privacy.allCases, id: \.self) { choice in
                  Text(verbatim: t("mac.settings.privacy.\(choice.rawValue)")).tag(choice.rawValue)
                }
              } label: {
                Text(verbatim: t("mac.settings.privacy"))
              }
              .labelsHidden()
              .fixedSize()
              .accessibilityIdentifier("settings.mac.privacy")
            }
          }
          Text(verbatim: t("mac.settings.footer.\(privacy)"))
            .appFont(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, SettingsChromeMetrics.contentInset)
        .padding(.vertical, 4)
      }
      .listRowBackground(Color.clear)
      .listRowInsets(EdgeInsets())
    }

    private func switchRow(_ key: String, hint: String?, _ value: Binding<Bool>) -> some View {
      SettingsCardRow(title: t(key), hint: hint.map(t), compact: true) {
        Toggle("", isOn: value).labelsHidden().toggleStyle(.switch)
          .accessibilityLabel(Text(verbatim: t(key)))
          .accessibilityIdentifier("settings.mac.\(key.split(separator: ".").last ?? "")")
      }
    }
  #endif

  private var formBody: some View {
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
      Toggle(isOn: $evening) { Text(verbatim: t("mac.settings.evening")) }
        .accessibilityIdentifier("settings.mac.evening")
        // Off takes back a reminder already scheduled; on schedules today's.
        .onChange(of: evening) { _, _ in HabitNudgeRoute.route(HabitNudgeRoute.lastAsked) }
      // What a notification may say about amounts and hidden accounts.
      Picker(selection: $privacy) {
        ForEach(NotificationPlan.Privacy.allCases, id: \.self) { choice in
          Text(verbatim: t("mac.settings.privacy.\(choice.rawValue)")).tag(choice.rawValue)
        }
      } label: {
        Text(verbatim: t("mac.settings.privacy"))
      }
      .accessibilityIdentifier("settings.mac.privacy")
    } header: {
      Text(verbatim: t("mac.settings.title")).settingsHeaderStyle()
    } footer: {
      Text(verbatim: t("mac.settings.footer.\(privacy)"))
        .appFont(.callout).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}
