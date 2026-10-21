import AppCore
import SwiftUI

#if canImport(AppKit)
  import AppKit
#endif

/// Copies of the database: where they go, what is there and how to come back from one.
/// The live database is never placed in iCloud — only copies are mirrored there.
struct BackupSettingsView: View {
  @Dependency(\.environment) private var environment
  @Environment(\.dependencies) private var dependencies
  @State private var list = BackupList(items: [])
  @State private var comparing: BackupList.Item?
  /// An archive chosen for «Сравнить с архивом…»: the file and the password it was asked for.
  @State private var comparingArchive: ArchiveToCompare?
  /// The copies whose description is being worked out on demand.
  @State private var describing: Set<URL> = []
  @State private var mirror: URL?
  @State private var pendingRestore: URL?
  /// What went wrong with the last copy, as a key of the Settings catalog.
  @State private var failure: String?
  /// Why the last restore stopped, as a key of the Settings catalog.
  @State private var restoreFailure: String?
  /// Why the folder just chosen was not taken, as a key of the Settings catalog.
  @State private var folderFailure: String?
  /// The room on the disk the copies lie on.
  @State private var space = BackupService.Space(freeBytes: nil)
  /// «Освободить место»: the list that was worked out and is asked about; nothing is deleted
  /// until «Да», and then exactly this list.
  @State private var freeUp: BackupSpace.Plan?
  /// «Удалить старше года»: the same for the copies made before updates.
  @State private var oldUpdates: [BackupEntry]?

  var body: some View {
    Form {
      Section {
        LabeledContent {
          HStack(spacing: 8) {
            Text(verbatim: mirror?.lastPathComponent ?? "—")
              .appFont(.callout)
              .foregroundStyle(.secondary)
            Button(environment.language("settings.backups.choose", table: "Settings")) {
              chooseFolder()
            }
            .disabled(AppPaths.dataSet != nil)
          }
        } label: {
          Text(verbatim: environment.language("settings.backups.folder", table: "Settings"))
        }
      } footer: {
        if AppPaths.dataSet != nil {
          Text(verbatim: environment.language(Self.dataSetMirrorsNowhereKey, table: "Settings"))
            .appFont(.callout)
            .foregroundStyle(.secondary)
        } else if mirror != nil {
          Text(verbatim: environment.language(Self.beforeUpdateCopiesKey, table: "Settings"))
            .appFont(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        // Said always: what lies where, and what does not leave this Mac.
        Text(verbatim: environment.language("backups.readable.note", table: "Settings"))
          .appFont(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      if let free = space.freeBytes, space.isLow {
        Section {
          HStack {
            Label {
              Text(verbatim: BackupSpaceText.low(freeBytes: free, in: environment))
            } icon: {
              Image(systemName: "externaldrive.badge.exclamationmark")
            }
            .foregroundStyle(.orange)
            Spacer()
            Button(environment.language("backups.space.freeUp", table: "Settings")) {
              askToFreeUp()
            }
          }
        }
      }

      if !problems.isEmpty {
        Section {
          ForEach(problems, id: \.self) { key in
            Label {
              Text(verbatim: environment.language(key, table: "Settings"))
            } icon: {
              Image(systemName: "exclamationmark.triangle")
            }
            .foregroundStyle(.orange)
          }
        }
      }

      Section {
        if list.items.isEmpty {
          Text(verbatim: environment.language("backups.empty", table: "Settings"))
            .appFont(.callout)
            .foregroundStyle(.secondary)
        } else {
          let listing = Self.listing(of: list.items.map(\.url))
          let byURL = Dictionary(uniqueKeysWithValues: list.items.map { ($0.url, $0) })
          ForEach(listing.recent, id: \.self) { url in
            if let item = byURL[url] { row(item) }
          }
          if !listing.older.isEmpty {
            DisclosureGroup(
              environment.format("backups.older", table: "Settings", counts: listing.older.count)
            ) {
              ForEach(listing.older, id: \.self) { url in
                if let item = byURL[url] { row(item) }
              }
            }
          }
        }
      } footer: {
        if !list.items.isEmpty { Text(verbatim: summary) }
      }

      Section {
        Button(environment.language("backups.compareArchive", table: "Settings")) {
          chooseArchiveToCompare()
        }
        .accessibilityIdentifier("backups.compareArchive")
      } footer: {
        Text(verbatim: environment.language("backups.compareArchive.note", table: "Settings"))
          .appFont(.callout)
          .foregroundStyle(.secondary)
      }

      IntegritySettingsSection()

      if list.beforeUpdateCount > 0 {
        Section {
          Text(
            verbatim: BackupSpaceText.beforeUpdateTotal(
              count: list.beforeUpdateCount, bytes: list.beforeUpdateBytes, in: environment)
          )
          .appFont(.callout)
          Button(environment.language("backups.beforeUpdate.deleteOld", table: "Settings")) {
            askToDeleteOldUpdates()
          }
        }
      }
    }
    .formStyle(.grouped)
    .padding()
    .onAppear(perform: reload)
    .sheet(item: $comparing) { item in
      BackupComparisonSheet(item: item).handingOver(dependencies)
    }
    .sheet(item: $comparingArchive) { chosen in
      BackupComparisonSheet(title: chosen.url.lastPathComponent) { current in
        try ArchiveComparison.compare(
          archiveAt: chosen.url, password: chosen.password, with: current,
          archives: chosen.archives)
      }
      .handingOver(dependencies)
    }
    .alert(
      environment.language("backups.restoreConfirm", table: "Settings"),
      isPresented: Binding(get: { pendingRestore != nil }, set: { if !$0 { pendingRestore = nil } })
    ) {
      Button(environment.language("action.cancel"), role: .cancel) { pendingRestore = nil }
      Button(environment.language("backups.restore", table: "Settings"), role: .destructive) {
        restore()
      }
    }
    .alert(
      environment.language("backups.freeUp.title", table: "Settings"),
      isPresented: Binding(get: { freeUp != nil }, set: { if !$0 { freeUp = nil } }),
      presenting: freeUp
    ) { plan in
      if plan.isEmpty {
        Button(environment.language("action.ok")) { freeUp = nil }
      } else {
        Button(environment.language("backups.freeUp.no", table: "Settings"), role: .cancel) {
          freeUp = nil
        }
        Button(environment.language("backups.freeUp.yes", table: "Settings"), role: .destructive) {
          remove(plan.removals)
        }
      }
    } message: { plan in
      Text(verbatim: BackupSpaceText.freeUpMessage(plan, in: environment))
    }
    .alert(
      environment.language("backups.beforeUpdate.confirmTitle", table: "Settings"),
      isPresented: Binding(get: { oldUpdates != nil }, set: { if !$0 { oldUpdates = nil } }),
      presenting: oldUpdates
    ) { entries in
      if entries.isEmpty {
        Button(environment.language("action.ok")) { oldUpdates = nil }
      } else {
        Button(environment.language("backups.freeUp.no", table: "Settings"), role: .cancel) {
          oldUpdates = nil
        }
        Button(environment.language("backups.freeUp.yes", table: "Settings"), role: .destructive) {
          remove(entries)
        }
      }
    } message: { entries in
      Text(verbatim: BackupSpaceText.oldUpdatesMessage(entries, in: environment))
    }
    .alert(
      environment.language(restoreFailure ?? "backups.restore.failed", table: "Settings"),
      isPresented: Binding(get: { restoreFailure != nil }, set: { if !$0 { restoreFailure = nil } })
    ) {
      Button(environment.language("action.ok")) { restoreFailure = nil }
    }
  }

  /// One copy of the list: its name, what is in it, and the way back from it.
  private func row(_ item: BackupList.Item) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(verbatim: item.url.lastPathComponent)
          .appFont(.callout.monospaced())
        Spacer()
        Button(environment.language("backups.restore", table: "Settings")) {
          pendingRestore = item.url
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
      }
      Text(verbatim: Self.detail(of: item, in: environment))
        .appFont(.caption)
        .foregroundStyle(.secondary)
      HStack(spacing: 12) {
        if item.description == nil {
          Button(environment.language("backups.row.describe", table: "Settings")) {
            describe(item)
          }
          .disabled(describing.contains(item.url))
        }
        Button(environment.language("backups.row.compare", table: "Settings")) {
          comparing = item
        }
        #if os(macOS)
          Button(environment.language("backups.row.showInFinder", table: "Settings")) {
            NSWorkspace.shared.activateFileViewerSelecting(
              [item.url] + (item.readableFolder.map { [$0] } ?? []))
          }
        #endif
      }
      .buttonStyle(.borderless)
      .controlSize(.small)
    }
  }

  /// «все копии: 12 · 48 МБ».
  private var summary: String {
    environment.format("backups.summary", table: "Settings", counts: list.count)
      + " · " + Self.sizeText(list.totalBytes)
  }

  /// «перед обновлением до 10 · 1,204 операции · последняя 6 окт. · 12 МБ» — the reason in the
  /// language of the interface now (the name keeps the language it was written in), what the
  /// description beside the copy says, and the size with the readable folder.
  static func detail(of item: BackupList.Item, in environment: AppEnvironment) -> String {
    let words = BackupWords.writer(code: environment.language.resolvedCode)
    var reason = words(.reason(item.copy.reason))
    if item.copy.damaged { reason += " (" + words(.damaged) + ")" }
    var parts = [reason]
    if item.copy.damaged {
      parts.append(environment.language("backups.row.unverified", table: "Settings"))
    }
    if let description = item.description {
      parts.append(
        environment.format(
          "backups.row.operations", table: "Settings", counts: description.operations))
      if let last = description.lastOperation {
        parts.append(
          environment.format(
            "backups.row.last", table: "Settings",
            last.occurredAt.formatted(
              .dateTime.day().month(.abbreviated).year().locale(environment.language.locale))))
      }
    } else {
      parts.append(environment.language("backups.row.noDescription", table: "Settings"))
    }
    parts.append(sizeText(item.totalBytes))
    return parts.joined(separator: " · ")
  }

  static func sizeText(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
  }

  /// Works the description of an old copy out by opening it read-only, and keeps it beside it.
  private func describe(_ item: BackupList.Item) {
    describing.insert(item.url)
    let url = item.url
    Task {
      await Task.detached(priority: .userInitiated) {
        _ = BackupDescription.compute(forCopyAt: url)
      }.value
      describing.remove(url)
      reload()
    }
  }

  /// How many of the newest copies are in view; the rest are one click away.
  static let recentCount = 20

  /// The copies the tab lists, newest first: the newest in view, and every other copy that is
  /// kept — the rest of the newest fifty, the daily copies of ninety days — under a disclosure.
  /// A copy kept on disk and listed nowhere could not be restored from Settings.
  static func listing(of copies: [URL]) -> (recent: [URL], older: [URL]) {
    (Array(copies.prefix(recentCount)), Array(copies.dropFirst(recentCount)))
  }

  /// Said when the folder for copies was chosen once and no longer opens.
  static let mirrorUnavailableKey = "backups.failure.mirrorUnavailable"

  /// What is wrong, as keys of the Settings catalog: the folder first — nothing reaches it until
  /// it is chosen again — then the last copy.
  private var problems: [String] {
    var keys: [String] = []
    if let folderFailure { keys.append(folderFailure) }
    if environment.mirrorFolderUnavailable { keys.append(Self.mirrorUnavailableKey) }
    if let failure { keys.append(failure) }
    return keys
  }

  private func reload() {
    mirror = Self.shownFolder(in: environment)
    guard let backups = environment.backups else { return }
    Task {
      let folder = await backups.folder
      let found = await Task.detached { BackupList.load(in: folder) }.value
      let problem = await backups.lastFailure
      let room = await backups.space()
      await MainActor.run {
        list = found
        failure = problem?.messageKey
        space = room
      }
    }
  }

  /// «Сравнить с архивом…»: the file is chosen, its password asked when it has one, and the
  /// sheet compares it with the database. Stepping back anywhere stops without a word.
  private func chooseArchiveToCompare() {
    guard let archives = environment.archives else { return }
    #if os(macOS)
      let panel = NSOpenPanel()
      panel.allowsMultipleSelection = false
      panel.canChooseDirectories = false
      guard panel.runModal() == .OK, let url = panel.url else { return }
    #else
      // The file importer of the iPhone screen replaces the open panel.
      guard let url = Optional<URL>.none else { return }
    #endif
    var password: String?
    if ArchiveComparison.needsPassword(url, archives: archives) {
      switch ArchiveImportFlow.Questions.alerts(environment).password() {
      case .cancelled: return
      case .given(let typed): password = typed
      }
    }
    comparingArchive = ArchiveToCompare(url: url, password: password, archives: archives)
  }

  /// Works the list out and asks; the list is what «Да» deletes.
  private func askToFreeUp() {
    guard let backups = environment.backups else { return }
    Task { freeUp = await backups.freeUpPlan() }
  }

  private func askToDeleteOldUpdates() {
    guard let backups = environment.backups else { return }
    Task { oldUpdates = await backups.beforeUpdateOlderThanAYear() }
  }

  private func remove(_ entries: [BackupEntry]) {
    freeUp = nil
    oldUpdates = nil
    guard let backups = environment.backups else { return }
    Task {
      await backups.remove(entries)
      reload()
    }
  }

  /// The folder the copies go to: the one the environment opened access to at the launch or at
  /// the choice. A folder chosen once whose bookmark no longer opens is not it, and a data set
  /// mirrors nowhere — neither is named, and the first says why below. Access is never opened
  /// here: every opening has to be balanced, and the tab appears any number of times.
  static func shownFolder(in environment: AppEnvironment) -> URL? {
    environment.mirrorFolder
  }

  private func chooseFolder() {
    guard let url = Self.askForFolder() else { return }
    folderFailure = Self.choose(url, in: environment)
    mirror = Self.shownFolder(in: environment)
  }

  /// The panel that asks for the folder of the copies: the sandbox gets access to the folder
  /// the owner actually picked. Nil when the owner stepped back.
  static func askForFolder() -> URL? {
    #if os(macOS)
      let panel = NSOpenPanel()
      panel.canChooseDirectories = true
      panel.canChooseFiles = false
      panel.allowsMultipleSelection = false
      return panel.runModal() == .OK ? panel.url : nil
    #else
      // The folder picker of the iPhone screen replaces the open panel.
      return nil
    #endif
  }

  /// «Выбрать папку…» of the question the main window asks after an import
  /// (`AppEnvironment.asksForMirrorFolder`): the same panel and the same rule as the tab, and
  /// what went wrong said in an alert, since no tab is there to show it.
  static func chooseAfterImport(in environment: AppEnvironment) {
    guard let url = askForFolder(), let problem = choose(url, in: environment) else { return }
    #if os(macOS)
      let alert = NSAlert()
      alert.alertStyle = .warning
      alert.messageText = environment.language(problem, table: "Settings")
      alert.runModal()
    #endif
  }

  /// Said in a data-set launch, where copies are mirrored nowhere.
  static let dataSetMirrorsNowhereKey = "backups.dataSet.noMirror"

  /// Said under a chosen folder: the copies written before updates are there too, in a folder of
  /// their own that no rotation enters.
  static let beforeUpdateCopiesKey = "settings.backups.beforeMigrationMirrored"

  /// Said when the folder just chosen could not be remembered, so it was not taken.
  static let folderNotRememberedKey = "backups.failure.folderNotRemembered"

  /// The folder the owner chose becomes the folder of the copies only once its bookmark is
  /// saved: the bookmark is what finds it after a restart. Taken without one, it was mirrored
  /// into until the quit and then forgotten — or, worse, the next launch went back to the folder
  /// chosen before — while the tab showed the new one. Now the folder in use stays in use, and
  /// the key of what went wrong comes back for the tab to say.
  ///
  /// A data-set launch takes no folder at all: its copies stay in its own folder, and the one
  /// key the bookmark is kept under is the owner's too (`AppEnvironment.open`).
  static func choose(
    _ url: URL, in environment: AppEnvironment, dataSet: AppPaths.DataSet? = AppPaths.dataSet
  ) -> String? {
    guard dataSet == nil else { return dataSetMirrorsNowhereKey }
    do {
      try environment.backupFolder.save(url)
    } catch {
      AppLog.error(
        "backup.bookmarkFailed", .backup, "the folder chosen for copies could not be remembered",
        [LogPair("error", .error(error))])
      return folderNotRememberedKey
    }
    environment.useMirrorFolder(url)
    return nil
  }

  /// A copy of the current state is written first, so restoring is itself undoable; without
  /// that copy nothing is replaced, and the owner is told why (`BackupRestoreFlow`).
  ///
  /// The chosen copy is staged next to the database and swapped in at the next launch:
  /// replacing a file that is open would race with the write-ahead log.
  private func restore() {
    guard let url = pendingRestore, let backups = environment.backups else { return }
    pendingRestore = nil
    Task {
      do {
        if case .failed = environment.state {
          // The database did not open: nothing is open to be replaced from under, so nothing
          // to relaunch for. The file that did not open is set aside whole, and the start is
          // made again (`DatabaseRecovery`).
          try await DatabaseRecovery.stage(url, replacing: environment)
          await AppLaunch.retryStarted()
        } else {
          try await BackupRestoreFlow.stage(
            copy: url, backups: backups, target: AppPaths.pendingReplacementURL)
          AppRestart.relaunch()
        }
      } catch {
        restoreFailure = (error as? BackupRestoreFlow.Failure ?? .notStaged).messageKey
      }
    }
  }
}

/// An archive chosen to be compared with the database, and the password it was asked for.
struct ArchiveToCompare: Identifiable {
  let url: URL
  let password: String?
  let archives: ArchiveService
  var id: URL { url }
}
