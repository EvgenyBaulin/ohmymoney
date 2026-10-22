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
  func choose(folder url: URL) -> Choice {
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
    Task { await syncNow() }
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
    let result: Result<SyncOutcome, any Error> = await Task.detached {
      Result { try exchange.exchange(with: DirectoryJournalFolder(url: url)) }
    }.value
    switch result {
    case .success(let outcome):
      AppLog.info(
        "sync.done", .db, "the exchange went through",
        outcome.logPairs.map { LogPair($0.0, .count($0.1)) })
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
