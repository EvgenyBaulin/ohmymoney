import AppCore
import SwiftUI

/// The line that says where the exchange stands: «Синхронизировано · 14:02», «Ждёт · 3 изменения
/// в очереди», «Ошибка обмена» with the reason and «Повторить». A symbol and words, never a
/// colour alone.
struct SyncStatusRow: View {
  @Dependency(\.environment) private var environment
  let coordinator: SyncCoordinator

  var body: some View {
    let status = coordinator.status
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      Image(systemName: symbol(status))
        .foregroundStyle(status.offersRetry ? Color.red : Color.secondary)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(verbatim: ConflictText.t(status.titleKey, environment))
          .appFont(.headline)
        if let detail = ConflictText.statusDetail(status, environment) {
          Text(verbatim: detail)
            .appFont(.caption)
            .foregroundStyle(.secondary)
        }
      }
      Spacer()
      if status.offersRetry {
        Button(ConflictText.t("sync.retry", environment)) {
          Task { await coordinator.retry() }
        }
        .accessibilityIdentifier("sync.retry")
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("sync.status")
  }

  private func symbol(_ status: SyncStatus) -> String {
    switch status {
    case .notConfigured: "icloud.slash"
    case .running: "arrow.triangle.2.circlepath"
    case .synced: "checkmark.circle"
    case .waiting: "ellipsis.circle"
    case .failed: "exclamationmark.octagon"
    }
  }
}
