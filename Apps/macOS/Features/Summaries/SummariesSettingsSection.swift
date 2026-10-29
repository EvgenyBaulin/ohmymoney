import AppCore
import SwiftUI

/// «Итоги» in the settings: which of the three come on their own, and the way to the screen.
struct SummariesSettingsSection: View {
  @Dependency(\.environment) private var environment
  @Environment(\.dependencies) private var dependencies
  @AppStorage(SummaryStorage.weekKey) private var week = true
  @AppStorage(SummaryStorage.monthKey) private var month = true
  @AppStorage(SummaryStorage.yearKey) private var year = true
  @State private var showsScreen = false

  private func t(_ key: String) -> String { environment.language(key, table: "Summaries") }

  var body: some View {
    Section {
      Toggle(isOn: $week) {
        Text(verbatim: t("summaries.settings.week"))
        Text(verbatim: t("summaries.settings.weekHint"))
      }
      .accessibilityIdentifier("summaries.settings.week")
      Toggle(isOn: $month) {
        Text(verbatim: t("summaries.settings.month"))
        Text(verbatim: t("summaries.settings.monthHint"))
      }
      .accessibilityIdentifier("summaries.settings.month")
      Toggle(isOn: $year) {
        Text(verbatim: t("summaries.settings.year"))
        Text(verbatim: t("summaries.settings.yearHint"))
      }
      .accessibilityIdentifier("summaries.settings.year")
      Button(t("summaries.settings.open")) { showsScreen = true }
        .accessibilityIdentifier("summaries.settings.open")
    } header: {
      Text(verbatim: t("summaries.settings.title"))
        .settingsHeaderStyle()
    }
    .sheet(isPresented: $showsScreen) {
      SummariesScreen()
        .handingOver(dependencies)
    }
  }
}
