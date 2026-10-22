import AppCore
import SwiftUI
import UniformTypeIdentifiers

/// «Папка обмена»: the folder the journal files of this device and of the others live in. The
/// app proposes iCloud Drive → OhMyMoney → Sync; the owner confirms it or picks another one
/// (0518). Only journal files go there — never the database or its copies, and a folder that
/// holds or lies in them is refused. Settings → «Основные» shows it, and only for the real database.
struct SyncFolderSettingsView: View {
  @Dependency(\.environment) private var environment
  let coordinator: SyncCoordinator
  @State private var picking = false
  @State private var refused = false

  var body: some View {
    Section {
      LabeledContent {
        Text(
          verbatim: coordinator.folderName.flatMap { $0.isEmpty ? nil : $0 }
            ?? ConflictText.t("sync.folder.none", environment)
        )
        .foregroundStyle(.secondary)
      } label: {
        Text(verbatim: ConflictText.t("sync.folder.title", environment))
      }
      .accessibilityIdentifier("sync.folder.name")
      if !coordinator.hasFolder {
        Text(verbatim: ConflictText.t("sync.folder.suggest", environment))
          .appFont(.caption)
          .foregroundStyle(.secondary)
      }
      HStack {
        Button(
          ConflictText.t(
            coordinator.hasFolder ? "sync.folder.change" : "sync.folder.choose", environment)
        ) { picking = true }
        .accessibilityIdentifier("sync.folder.choose")
        if coordinator.hasFolder {
          Button(ConflictText.t("sync.folder.stop", environment)) { coordinator.forgetFolder() }
            .accessibilityIdentifier("sync.folder.stop")
        }
      }
      SyncStatusRow(coordinator: coordinator)
      if refused {
        Text(verbatim: ConflictText.t("sync.error.insideData", environment))
          .appFont(.caption)
          .foregroundStyle(.red)
          .accessibilityIdentifier("sync.folder.refused")
      }
    } footer: {
      Text(verbatim: ConflictText.t("sync.folder.note", environment))
    }
    .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
      guard case .success(let url) = result else { return }
      // The bookmark of a picked folder can be made only while access to it is open.
      let scoped = url.startAccessingSecurityScopedResource()
      defer { if scoped { url.stopAccessingSecurityScopedResource() } }
      refused = coordinator.choose(folder: url) == .refused
    }
  }
}
