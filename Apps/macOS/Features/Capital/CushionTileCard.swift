import AppCore
import SwiftUI

/// «Подушка безопасности» on Overview: the months the cushion lasts, the bar to the goal and a
/// hint.
struct CushionTileCard: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute

  var body: some View {
    ComputedBlock(
      title: OverviewTileText.name(of: .cushion, environment),
      state: compute.states.data, fillsHeight: true,
      retry: { compute.retry(ComputeStep.data) }
    ) { snapshot in
      CushionTileContent(
        status: snapshot.planning.cushion, settings: snapshot.dataset.capitalSettings)
    }
  }
}

/// The body of the tile, apart so a test lays it out with figures of its own.
struct CushionTileContent: View {
  @Dependency(\.environment) private var environment
  let status: CushionStatus
  let settings: CapitalSettings

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if let months = CushionText.shortMonths(status, environment) {
        Text(verbatim: months)
          .appFont(.title2.monospacedDigit())
          .accessibilityIdentifier("overview.cushion.months")
        CushionBar(status: status, settings: settings)
      }
      Text(verbatim: CushionText.tileHint(status, settings: settings, environment))
        .appFont(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Button(CushionText.t("cushion.planning.open", environment)) {
        NotificationCenter.default.post(
          name: .selectSection, object: MainWindow.Section.capital.shortcutIndex)
      }
      .buttonStyle(.link)
      .accessibilityIdentifier("overview.cushion.open")
    }
  }
}
