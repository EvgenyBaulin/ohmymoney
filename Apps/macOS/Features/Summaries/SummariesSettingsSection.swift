import AppCore
import SwiftUI

/// «Итоги» in the settings: which of the three come on their own, and the way to them — the tab
/// «По периодам» of Reports, the page «Итоги» on a phone.
struct SummariesSettingsSection: View {
  @Dependency(\.environment) private var environment
  @AppStorage(SummaryStorage.weekKey) private var week = true
  @AppStorage(SummaryStorage.monthKey) private var month = true
  @AppStorage(SummaryStorage.yearKey) private var year = true

  private func t(_ key: String) -> String { environment.language(key, table: "Summaries") }

  var body: some View {
    #if os(macOS)
      macBody
    #else
      formBody
    #endif
  }

  #if os(macOS)
    /// The design's card (Figma 61:64965): three switches of rows 11 × 16 with a 13 over 11 text,
    /// then «Открыть Итоги…» with a chevron.
    private var macBody: some View {
      SettingsCardGroup(title: t("summaries.settings.title"), titleGap: 18, verticalMargin: 12) {
        switchRow("week", $week)
        switchRow("month", $month)
        switchRow("year", $year)
        Button { SummariesRoute.open() } label: {
          HStack {
            Text(verbatim: t("summaries.settings.open"))
              .appFont(AppFont.system(size: 13, weight: .medium))
            Spacer()
            Image(systemName: "chevron.right")
              .font(.system(size: 11, weight: .semibold))  // font-fixed: chevron of a link row
              .foregroundStyle(.secondary)
              .accessibilityHidden(true)
          }
          .padding(.horizontal, SettingsCardMetrics.rowHorizontal)
          .padding(.vertical, SettingsCardMetrics.compactVertical)
          .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("summaries.settings.open")
      }
    }

    private func switchRow(_ name: String, _ isOn: Binding<Bool>) -> some View {
      SettingsCardRow(
        title: t("summaries.settings.\(name)"), hint: t("summaries.settings.\(name)Hint"),
        compact: true
      ) {
        Toggle(isOn: isOn) { Text(verbatim: t("summaries.settings.\(name)")) }
          .labelsHidden().toggleStyle(.switch)
          .accessibilityIdentifier("summaries.settings.\(name)")
      }
    }
  #endif

  private var formBody: some View {
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
      Button(t("summaries.settings.open")) { SummariesRoute.open() }
        .accessibilityIdentifier("summaries.settings.open")
    } header: {
      Text(verbatim: t("summaries.settings.title"))
        .settingsHeaderStyle()
    }
  }
}
