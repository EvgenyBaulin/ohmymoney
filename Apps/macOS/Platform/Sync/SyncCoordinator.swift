import AppCore
import AppDatabase
import Foundation
import Observation

/// The exchange with the other devices, as the screens see it: a status, the list of
/// conflicts, the folder, and the actions «Повторить», «Оставить мою», «Взять другую».
///
/// The exchange itself is `SyncExchange` (the package); this class chooses when it runs, opens
/// the folder the owner picked, keeps the result for the status row and writes the journal
/// (identifiers and counts only, 0054). A data set (`exchange == nil`) never exchanges: it
/// has no folder, writes no journal and shows nothing.
@MainActor
@Observable
final class SyncCoordinator {
  /// The key of the folder's bookmark, kept on this device and never carried by the archive.
  static let folderKey = "sync.folder"

  private(set) var status: SyncStatus
  private(set) var conflicts: [SyncConflict] = []
  /// The chosen folder as the screens name it; `nil` while none is chosen.
  private(set) var folderName: String?
  /// What the last exchange did, for the status row (rows sent from the existing books, a
  /// fresh copy of the whole database in the folder).
  private(set) var lastOutcome: SyncOutcome?
  /// Where «Загрузить данные из папки» stands.
  private(set) var bootstrap: SyncBootstrapState = .idle

  let exchange: SyncExchange?
  private let bookmarks: BookmarkStore
  private let protectedFolders: @Sendable () -> [URL]
  private let notifier: any SyncNotifying
  private let defaults: UserDefaults
  private var isRunning = false
  private var isStopped = false
  private var debounce: Task<Void, Never>?
  @ObservationIgnored private var foregroundObserver: (any NSObjectProtocol)?
  /// How long a burst of changes is left to settle before one exchange.
  var debounceDelay: Duration = .seconds(3)
  /// The language of the interface, for the words of a notification; the wiring sets it.
  var language: AppLanguage?

  init(
    exchange: SyncExchange?,
    bookmarks: BookmarkStore = BookmarkStore(key: SyncCoordinator.folderKey),
    protectedFolders: @escaping @Sendable () -> [URL] = { [] },
    notifier: any SyncNotifying = SystemSyncNotifier(), defaults: UserDefaults = .standard
  ) {
    self.exchange = exchange
    self.bookmarks = bookmarks
    self.protectedFolders = protectedFolders
    self.notifier = notifier
    self.defaults = defaults
    self.status = .notConfigured
    refreshFolderName()
  }

  /// Whether this database exchanges at all.
  var isAvailable: Bool { exchange != nil }
  var hasFolder: Bool { bookmarks.isStored }

  // MARK: Folder

  enum Choice: Equatable {
    case accepted
    /// The folder is, holds or lies in the database or its copies.
    case refused
  }

  /// The owner confirmed a folder. The database and the folders of its copies are refused: only
  /// journal files go to the exchange folder.
  @discardableResult
  /// `thenSync` starts the first exchange at once; a caller that wants to offer the snapshot of the
  /// folder first (the empty device) or a test that must not race it passes `false`.
  func choose(folder url: URL, thenSync: Bool = true) -> Choice {
    guard SyncFolderPolicy.allows(url, protecting: protectedFolders()) else {
      AppLog.warning("sync.folderRefused", .db, "the folder holds or lies in the books")
      return .refused
    }
    do {
      try bookmarks.save(url)
    } catch {
      AppLog.warning(
        "sync.folderNotSaved", .db, "the bookmark was not written",
        [LogPair("error", .error(error))])
      status = .failed(.folderMissing)
      return .accepted
    }
    refreshFolderName(url)
    exchange.map { try? $0.setRecording(true) }
    if thenSync { Task { await syncNow() } }
    return .accepted
  }

  /// «Не обмениваться»: the folder is forgotten. Nothing in it is deleted, and nothing that
  /// waits to go out is lost: it goes when a folder is chosen again.
  func forgetFolder() {
    bookmarks.clear()
    folderName = nil
    status = .notConfigured
  }

  private func refreshFolderName(_ known: URL? = nil) {
    guard bookmarks.isStored else {
      folderName = nil
      return
    }
    if let known {
      folderName = SyncFolderSuggestion.displayName(of: known)
    } else if folderName == nil {
      folderName = ""  // chosen, name not known until the bookmark opens
    }
  }

  // MARK: Triggers

  /// The data changed (any committed write, the exchange's own included): the status shows what
  /// waits, and one exchange runs once the changes have stopped coming. Without a folder there
  /// is nothing to run.
  func changed() {
    guard exchange != nil, !isStopped else { return }
    refresh()
    guard bookmarks.isStored else { return }
    debounce?.cancel()
    let delay = debounceDelay
    debounce = Task { [weak self] in
      try? await Task.sleep(for: delay)
      guard !Task.isCancelled else { return }
      await self?.syncNow()
    }
  }

  /// The app came to the front: look at what waits and run an exchange.
  func startObservingForeground(center: NotificationCenter = .default) {
    guard exchange != nil, foregroundObserver == nil else { return }
    foregroundObserver = center.addObserver(
      forName: SyncWiring.foregroundNotification, object: nil, queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in
        self?.refresh()
        await self?.syncNow()
      }
    }
  }

  /// The launch: what waits, and one exchange.
  func start() {
    refresh()
    startObservingForeground()
    Task { await syncNow() }
  }

  /// Before the database closes: no new exchange begins, and one in flight is waited for.
  func stop() async {
    isStopped = true
    debounce?.cancel()
    debounce = nil
    if let observer = foregroundObserver {
      NotificationCenter.default.removeObserver(observer)
      foregroundObserver = nil
    }
    var waited = 0
    while isRunning, waited < 200 {
      try? await Task.sleep(for: .milliseconds(50))
      waited += 1
    }
  }

  // MARK: Running

  /// Looks at what is waiting without touching the folder.
  func refresh() {
    guard let exchange else { return }
    conflicts = (try? exchange.conflicts()) ?? conflicts
    guard bookmarks.isStored else {
      status = .notConfigured
      return
    }
    if case .failed = status { return }
    if let pending = try? exchange.pendingCount(), pending > 0, !isRunning {
      status = .waiting(changes: pending)
    }
  }

  /// One exchange: out, in, conflicts. Does nothing while one runs or when no folder is chosen.
  func syncNow() async {
    guard let exchange, !isRunning, !isStopped else { return }
    guard bookmarks.isStored else {
      status = .notConfigured
      return
    }
    isRunning = true
    status = .running
    defer { isRunning = false }
    guard let url = bookmarks.resolve() else {
      fail(.folderMissing)
      return
    }
    defer { bookmarks.release(url) }
    refreshFolderName(url)
    let before = conflicts.count
    // The launch put another database in place: the exchange drops what it remembered of the
    // old one and sends every row of the new one before anything else.
    let replaced = defaults.bool(forKey: SyncWiring.replacedKey)
    let fromSnapshot = replaced && defaults.bool(forKey: SyncWiring.bootstrapKey)
    let result: Result<SyncOutcome, any Error> = await Task.detached {
      Result {
        if replaced {
          let rows = try exchange.databaseWasReplaced(bootstrappedFromSnapshot: fromSnapshot)
          AppLog.info(
            "sync.replaced", .db, "the database was replaced; the exchange starts over",
            [LogPair("seeded", .count(rows)), LogPair("snapshot", .count(fromSnapshot ? 1 : 0))])
        }
        let folder = DirectoryJournalFolder(url: url)
        var outcome = try exchange.exchange(with: folder)
        // The copy of the whole database is a courtesy to a device that joins later: when it
        // can not be written the exchange itself has still gone through.
        do {
          outcome.snapshotWritten = try exchange.snapshotIfDue(to: folder)
        } catch {
          AppLog.warning(
            "sync.snapshotFailed", .db, "the snapshot was not written; nothing was lost",
            [LogPair("error", .error(error))])
        }
        return outcome
      }
    }.value
    switch result {
    case .success(let outcome):
      if replaced {
        defaults.removeObject(forKey: SyncWiring.replacedKey)
        defaults.removeObject(forKey: SyncWiring.bootstrapKey)
      }
      AppLog.info(
        "sync.done", .db, "the exchange went through",
        outcome.logPairs.map { LogPair($0.0, .count($0.1)) })
      lastOutcome = outcome
      conflicts = (try? exchange.conflicts()) ?? conflicts
      status = .synced(at: Date())
      if conflicts.count > before { announceConflicts() }
    case .failure(let error):
      fail((error as? SyncFailure) ?? .database, error: error)
    }
  }

  private func fail(_ failure: SyncFailure, error: (any Error)? = nil) {
    var pairs = [LogPair("reason", .token(failure.token))]
    if let error { pairs.append(LogPair("error", .error(error))) }
    AppLog.warning("sync.failed", .db, "the exchange stopped; nothing was lost", pairs)
    status = .failed(failure)
  }

  /// «Повторить».
  func retry() async {
    if case .failed = status { status = .notConfigured }
    await syncNow()
  }

  // MARK: Joining with the folder's snapshot

  /// Why a device did not take the snapshot of the folder.
  enum BootstrapResult: Equatable {
    /// The snapshot is checked and staged; the next launch puts it in place and the exchange
    /// carries on from the journal files.
    case staged
    case notConfigured
    /// This database holds the owner's books: it is never replaced by a snapshot.
    case notEmpty
    case noSnapshot
    case damaged
    case newerVersion
    case failed
  }

  /// A device with empty books takes the newest snapshot in the folder as its database. The
  /// snapshot is fetched, checked as a restore checks a copy, the current state is copied first
  /// (`BackupRestoreFlow`), and the file is staged for the next launch. Nothing is replaced
  /// here; the screen that offers it decides when to ask for the restart.
  func bootstrapFromSnapshot(
    backups: BackupService, schema: any SchemaSource = BundleSchemaSource(),
    target: URL = AppPaths.pendingReplacementURL
  ) async -> BootstrapResult {
    guard let exchange, bookmarks.isStored else { return .notConfigured }
    guard !exchange.holdsOwnerData else {
      AppLog.warning("sync.bootstrapRefused", .db, "the database holds books; no snapshot is taken")
      return .notEmpty
    }
    guard let url = bookmarks.resolve() else { return .failed }
    defer { bookmarks.release(url) }
    let fetched = URL(fileURLWithPath: target.path + ".snapshot")
    defer { try? FileManager.default.removeItem(at: fetched) }
    do {
      let folder = DirectoryJournalFolder(url: url)
      let found: SyncSnapshotInfo? = try await Task.detached {
        try SyncSnapshots.newest(in: folder)
      }
      .value
      guard let found else { return .noSnapshot }
      try await Task.detached {
        try SyncSnapshots.fetchVerified(found, from: folder, to: fetched, schema: schema)
      }.value
      try await BackupRestoreFlow.stage(copy: fetched, backups: backups, target: target)
    } catch let error as SyncSnapshotError {
      AppLog.warning(
        "sync.bootstrapFailed", .db, "the snapshot was not taken",
        [LogPair("reason", .token(error == .newerSchema ? "newer" : "damaged"))])
      return error == .newerSchema ? .newerVersion : (error == .none ? .noSnapshot : .damaged)
    } catch {
      AppLog.warning(
        "sync.bootstrapFailed", .db, "the snapshot was not taken",
        [LogPair("error", .error(error))])
      return .failed
    }
    defaults.set(true, forKey: SyncWiring.bootstrapKey)
    AppLog.info("sync.bootstrapStaged", .db, "the snapshot of the folder is staged")
    return .staged
  }

  /// Looks in the folder for a snapshot this device could take as its books. Offered only while
  /// the books hold nothing of the owner's and a folder is chosen; otherwise the state is idle.
  func lookForSnapshot() async {
    if case .loading = bootstrap { return }
    if case .staged = bootstrap { return }
    guard let exchange, bookmarks.isStored, !exchange.holdsOwnerData else {
      bootstrap = .idle
      return
    }
    guard let url = bookmarks.resolve() else {
      bootstrap = .idle
      return
    }
    defer { bookmarks.release(url) }
    let found: SyncSnapshotInfo? = await Task.detached {
      try? SyncSnapshots.newest(in: DirectoryJournalFolder(url: url))
    }.value
    if let found {
      bootstrap = .offered(
        SyncSnapshotOffer(
          madeAt: found.modified, deviceId: SyncSnapshotName.parse(found.name) ?? ""))
    } else {
      bootstrap = .result(.noSnapshot)
    }
  }

  /// «Загрузить данные из папки»: stages the snapshot (`bootstrapFromSnapshot`) and keeps the
  /// answer for the screen.
  func loadSnapshot(
    backups: BackupService?, schema: any SchemaSource = BundleSchemaSource(),
    target: URL = AppPaths.pendingReplacementURL
  ) async {
    guard let backups else {
      bootstrap = .result(.failed)
      return
    }
    if case .loading = bootstrap { return }
    bootstrap = .loading
    let result = await bootstrapFromSnapshot(backups: backups, schema: schema, target: target)
    bootstrap = result == .staged ? .staged : .result(result)
  }

  // MARK: Choices

  func keepMine(_ conflict: SyncConflict) async {
    await settle(conflict) { try $0.keepMine(conflict.key) }
  }

  func takeTheirs(_ conflict: SyncConflict) async {
    await settle(conflict) { try $0.takeTheirs(conflict.key) }
  }

  private func settle(
    _ conflict: SyncConflict, _ choose: (SyncExchange) throws -> Void
  ) async {
    guard let exchange else { return }
    do {
      try choose(exchange)
      AppLog.info("sync.chosen", .db, "a conflict was settled")
    } catch {
      AppLog.warning(
        "sync.chooseFailed", .db, "the choice was not written", [LogPair("error", .error(error))])
    }
    conflicts = (try? exchange.conflicts()) ?? []
    await syncNow()
  }

  private func announceConflicts() {
    let count = conflicts.count
    notifier.conflictsAppeared(
      count: count,
      title: language?("sync.notify.title", table: "Sync") ?? "OhMyMoney",
      body: language?.format("sync.conflicts.banner", table: "Sync", counts: count)
        ?? "\(count)")
  }
}
