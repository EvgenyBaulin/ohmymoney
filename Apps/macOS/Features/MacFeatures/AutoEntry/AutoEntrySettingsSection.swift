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
