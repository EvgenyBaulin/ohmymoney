#if os(macOS)
  import SwiftUI

  /// The Mac's «Приватность» in the design's rows (Figma 6:94917): a card rounded 12, a row of
  /// 16 × 14 for each switch or door, a symbol in a 24-point slot, the title 14 medium over its
  /// 12-point hint. The groups the design does not draw (what the Mac shows outside the app, the
  /// text of a bank) keep their form sections below.
  extension PrivacySettingsView {
    var macBody: some View {
      Form {
        Section {
          VStack(alignment: .leading, spacing: SettingsControlMetrics.blockGap) {
            group("privacy.settings.screen") {
              SettingsCard {
                SettingsCardRow(
                  symbol: "eye.slash", title: t("privacy.settings.autoHide"),
                  hint: t("privacy.settings.autoHide.hint")
                ) {
                  Toggle("", isOn: autoHide).labelsHidden().toggleStyle(.switch)
                    .accessibilityIdentifier("settings.privacy.autoHide")
                }
                SettingsCardRow(
                  symbol: "lock.shield", title: t("privacy.settings.readOnly"),
                  hint: t("privacy.settings.readOnly.hint")
                ) {
                  Toggle("", isOn: readOnly).labelsHidden().toggleStyle(.switch)
                    .accessibilityIdentifier("settings.privacy.readOnly")
                }
                SettingsCardRow(
                  symbol: "lock", title: t("privacy.settings.lock"), showsDivider: false
                ) {
                  chevron
                }
                .contentShape(Rectangle())
                .onTapGesture { SettingsNavigation.shared.section = .general }
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("settings.privacy.lockLink")
              }
            }
            group("privacy.settings.knows", footer: "privacy.settings.knows.footer") {
              SettingsCard {
                doorRow(
                  "clock.arrow.circlepath", "privacy.settings.journal", id: "journal"
                ) { showsJournal = true }
                doorRow(
                  "internaldrive", "privacy.settings.storage", id: "storage", last: true
                ) { showsStorage = true }
              }
            }
            group("privacy.settings.hand", footer: "privacy.settings.hand.footer") {
              SettingsCard {
                doorRow(
                  "square.and.arrow.up", "privacy.settings.exportCopy", id: "exportCopy",
                  last: false,
                  disabled: environment.exportCopies == nil
                ) { showsExport = true }
                doorRow(
                  "play.rectangle", "privacy.settings.demo", id: "demo", last: true,
                  disabled: DemoDataMode.isOn()
                ) { confirmsDemo = true }
              }
            }
          }
          .padding(.horizontal, SettingsChromeMetrics.contentInset)
          .padding(.vertical, 12)
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets())
        MacFeaturesSettingsSection()
        AutoEntrySettingsSection()
      }
      .formStyle(.grouped)
      .scrollContentBackground(.hidden)
    }

    private var chevron: some View {
      Image(systemName: "chevron.right")
        .font(.system(size: 11, weight: .semibold))  // font-fixed: chevron in a 15 pt slot
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }

    private func doorRow(
      _ symbol: String, _ key: String, id: String, last: Bool = false, disabled: Bool = false,
      action: @escaping () -> Void
    ) -> some View {
      Button(action: action) {
        SettingsCardRow(symbol: symbol, title: t(key), showsDivider: !last) { chevron }
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(disabled)
      .accessibilityIdentifier("settings.privacy.\(id)")
    }

    private func group<Content: View>(
      _ header: String, footer: String? = nil, @ViewBuilder content: () -> Content
    ) -> some View {
      VStack(alignment: .leading, spacing: 6) {
        Text(verbatim: t(header)).settingsHeaderStyle()
        content()
        if let footer {
          Text(verbatim: t(footer))
            .appFont(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }
#endif
