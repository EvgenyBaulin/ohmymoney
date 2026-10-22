import AppCore
import SwiftUI

/// «Разобрать»: the list of conflicts and the comparison on a sheet over the main window. The
/// sheet closes by itself when the last record is settled.
struct ConflictsSheet: View {
  @Dependency(\.environment) private var environment
  @Environment(\.dismiss) private var dismiss
  let coordinator: SyncCoordinator

  var body: some View {
    NavigationStack {
      ConflictsList(coordinator: coordinator)
        .toolbar {
          ToolbarItem(placement: .confirmationAction) {
            Button(environment.language("action.close")) { dismiss() }
              .accessibilityIdentifier("sync.conflicts.close")
          }
        }
    }
    #if os(macOS)
      .frame(minWidth: 520, minHeight: 420)
    #endif
    .onChange(of: coordinator.conflicts.isEmpty) { _, empty in
      if empty { dismiss() }
    }
  }
}

/// The strip over the main window while records wait for a choice. Nothing is drawn for a
/// database that does not exchange or when no record waits.
struct SyncConflictsStrip: View {
  @Dependency(\.environment) private var environment
  @Binding var showsList: Bool

  var body: some View {
    if let coordinator = environment.sync {
      ConflictsBanner(coordinator: coordinator) { showsList = true }
    }
  }
}
