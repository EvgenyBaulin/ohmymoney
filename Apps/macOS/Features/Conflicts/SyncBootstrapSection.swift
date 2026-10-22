import AppCore
import SwiftUI

/// «Загрузить данные из папки»: a device with no records of its own (a new phone, a fresh
/// install) takes the copy of the whole database that another device left in the exchange
/// folder. Shown only while the books are empty and a folder is chosen; the explanation comes
/// first, the button second, and after the copy is staged the owner is asked to restart.
struct SyncBootstrapSection: View {
  @Dependency(\.environment) private var environment
  let coordinator: SyncCoordinator

  var body: some View {
    let state = coordinator.bootstrap
    Group {
      if SyncBootstrapText.isVisible(state) {
        Section {
          content(state)
        } header: {
          Text(verbatim: ConflictText.t("sync.bootstrap.title", environment))
        }
        .accessibilityIdentifier("sync.bootstrap")
      }
    }
    .task(id: coordinator.hasFolder) { await coordinator.lookForSnapshot() }
    .onChange(of: coordinator.status) { _, _ in
      Task { await coordinator.lookForSnapshot() }
    }
  }

  @ViewBuilder
  private func content(_ state: SyncBootstrapState) -> some View {
    Text(verbatim: ConflictText.t("sync.bootstrap.explain", environment))
      .appFont(.caption)
      .foregroundStyle(.secondary)
    if case .offered(let offer) = state {
      Text(verbatim: ConflictText.offerLine(offer, environment))
        .accessibilityIdentifier("sync.bootstrap.offer")
    }
    if case .loading = state {
      HStack(spacing: 8) {
        ProgressView().controlSize(.small)
        Text(verbatim: ConflictText.t("sync.bootstrap.loading", environment))
      }
    }
    if let key = SyncBootstrapText.messageKey(for: state) {
      Text(verbatim: ConflictText.t(key, environment))
        .accessibilityIdentifier("sync.bootstrap.message")
    }
    if SyncBootstrapText.offersLoad(state) {
      Button(ConflictText.t("sync.bootstrap.load", environment)) {
        Task { await coordinator.loadSnapshot(backups: environment.backups) }
      }
      .accessibilityIdentifier("sync.bootstrap.load")
    }
    if SyncBootstrapText.asksRestart(state) {
      #if os(macOS)
        Button(ConflictText.t("sync.bootstrap.restart", environment)) { AppRestart.relaunch() }
          .accessibilityIdentifier("sync.bootstrap.restart")
      #else
        // The app cannot relaunch itself: the staged copy is put in place at the next launch.
        Text(verbatim: ConflictText.t("sync.bootstrap.reopen", environment))
          .appFont(.caption)
          .foregroundStyle(.secondary)
      #endif
    }
  }
}
