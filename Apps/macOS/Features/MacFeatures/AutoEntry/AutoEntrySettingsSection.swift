import AppCore
import SwiftUI

/// Settings → «Приватность» → «Сообщения банков»: what a text of a bank passed on by «Быстрые
/// команды» becomes — offered first (the default) or written at once. A habit of this Mac
/// (`UserDefaults`), not the archive.
struct AutoEntrySettingsSection: View {
  @Dependency(\.environment) private var environment
  @AppStorage(AutoEntryCenter.modeKey) private var mode = AutoEntryMode.standard.rawValue

  private func t(_ key: String) -> String {
    environment.language(key, table: AutoEntryCenter.table)
  }

  var body: some View {
    #if os(macOS)
      macBody
    #else
      formBody
    #endif
  }

  #if os(macOS)
    /// The design's card (Figma 61:67468): the title 13 semibold, one row of 16 × 11 with the
    /// choice at its right in the accent, and the explanation under the card.
    private var macBody: some View {
      Section {
        VStack(alignment: .leading, spacing: 8) {
          Text(verbatim: t("autoEntry.settings.title"))
            .appFont(AppFont.body.weight(.semibold))
          SettingsCard {
            SettingsCardRow(title: t("autoEntry.settings.mode"), showsDivider: false, compact: true)
            {
              Picker(selection: $mode) {
                ForEach(AutoEntryMode.allCases, id: \.self) { choice in
                  Text(verbatim: t("autoEntry.settings.mode.\(choice.rawValue)"))
                    .tag(choice.rawValue)
                }
              } label: {
                Text(verbatim: t("autoEntry.settings.mode"))
              }
              .labelsHidden()
              .fixedSize()
              .accessibilityIdentifier("settings.autoEntry.mode")
            }
          }
          Text(verbatim: t("autoEntry.settings.footer"))
            .appFont(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, SettingsChromeMetrics.contentInset)
        .padding(.vertical, 4)
      }
      .listRowBackground(Color.clear)
      .listRowInsets(EdgeInsets())
    }
  #endif

  private var formBody: some View {
    Section {
      Picker(selection: $mode) {
        ForEach(AutoEntryMode.allCases, id: \.self) { choice in
          Text(verbatim: t("autoEntry.settings.mode.\(choice.rawValue)")).tag(choice.rawValue)
        }
      } label: {
        Text(verbatim: t("autoEntry.settings.mode"))
      }
      .accessibilityIdentifier("settings.autoEntry.mode")
    } header: {
      Text(verbatim: t("autoEntry.settings.title")).settingsHeaderStyle()
    } footer: {
      Text(verbatim: t("autoEntry.settings.footer"))
        .appFont(.callout).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}
