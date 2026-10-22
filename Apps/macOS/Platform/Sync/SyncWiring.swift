import AppCore
import AppDatabase
import Foundation
import GRDB

#if canImport(AppKit)
  import AppKit
#elseif canImport(UIKit)
  import UIKit
#endif

/// The folders an exchange folder must never hold or lie in: the live database, the folder of
/// its copies and the mirror of the copies. The mirror is chosen while the app runs, so the
/// value is kept behind a lock and read by the coordinator whenever a folder is proposed.
final class SyncProtectedFolders: @unchecked Sendable {
  private let lock = NSLock()
  private var fixed: [URL]
  private var mirror: URL?

  init(fixed: [URL], mirror: URL? = nil) {
    self.fixed = fixed
    self.mirror = mirror
  }

  func setMirror(_ url: URL?) {
    lock.lock()
    defer { lock.unlock() }
    mirror = url
  }

  var all: [URL] {
    lock.lock()
    defer { lock.unlock() }
    return fixed + (mirror.map { [$0] } ?? [])
  }
}

/// How the exchange is put into the app: who this device is, and which databases exchange at
/// all. Only the owner's real database does; a generated data set, a demo and a test database
/// get no coordinator, record nothing and write no journal.
enum SyncWiring {
  /// Kept in the settings of this device, never in the database or the archive: a restored
  /// copy on another device must not pose as the device it came from.
  static let deviceIdKey = "sync.deviceId"

  /// The identity of this device: made once, kept in `defaults`. Letters, digits and hyphens
  /// only, because it sits inside file names of the journal.
  static func deviceId(in defaults: UserDefaults) -> String {
    if let stored = defaults.string(forKey: deviceIdKey), SyncDevice.isValid(id: stored) {
      return stored
    }
    let made = UUID().uuidString.lowercased()
    defaults.set(made, forKey: deviceIdKey)
    return made
  }

  /// The name the other devices show for this one.
  static var deviceName: String {
    #if canImport(AppKit)
      Host.current().localizedName ?? "Mac"
    #else
      MainActor.assumeIsolated { UIDevice.current.name }
    #endif
  }

  /// The coordinator of a database, or `nil` when the database does not exchange. For the real
  /// database the recording of changes is switched on here; for any other nothing is touched.
  @MainActor
  static func makeCoordinator(
    writer: any DatabaseWriter, isRealDatabase: Bool, defaults: UserDefaults = .standard,
    deviceName: String = SyncWiring.deviceName, protected: SyncProtectedFolders,
    language: AppLanguage?,
    bookmarks: BookmarkStore = BookmarkStore(key: SyncCoordinator.folderKey),
    notifier: (any SyncNotifying)? = nil
  ) -> SyncCoordinator? {
    guard isRealDatabase else { return nil }
    guard
      let exchange = try? SyncExchange(
        writer: writer, deviceId: deviceId(in: defaults), deviceName: deviceName)
    else {
      AppLog.warning("sync.notWired", .db, "the exchange could not be made for this database")
      return nil
    }
    do {
      try exchange.setRecording(true)
    } catch {
      AppLog.warning(
        "sync.recordingFailed", .db, "recording of changes was not switched on",
        [LogPair("error", .error(error))])
      return nil
    }
    let coordinator = SyncCoordinator(
      exchange: exchange, bookmarks: bookmarks, protectedFolders: { protected.all },
      notifier: notifier ?? SystemSyncNotifier(), defaults: defaults)
    coordinator.language = language
    return coordinator
  }

  /// The name of the notification that says the app came to the front.
  static var foregroundNotification: Notification.Name {
    #if canImport(AppKit)
      NSApplication.didBecomeActiveNotification
    #else
      UIApplication.willEnterForegroundNotification
    #endif
  }
}

extension AppEnvironment {
  /// Puts the exchange on a database that is open. A database that is not the owner's real one
  /// gets none (`sync` stays `nil`) and records nothing. The folders an exchange folder must
  /// stay out of are the database's own and the folder of its copies, and the mirror.
  func wireSync(
    writer: any DatabaseWriter, isRealDatabase: Bool, defaults: UserDefaults = .standard,
    bookmarks: BookmarkStore = BookmarkStore(key: SyncCoordinator.folderKey),
    notifier: (any SyncNotifying)? = nil
  ) {
    sync = nil
    syncFolders = nil
    guard isRealDatabase else { return }
    let folders = SyncProtectedFolders(
      fixed: [AppPaths.dataDirectory, AppPaths.backupsDirectory], mirror: mirrorFolder)
    syncFolders = folders
    sync = SyncWiring.makeCoordinator(
      writer: writer, isRealDatabase: true, defaults: defaults, protected: folders,
      language: language, bookmarks: bookmarks, notifier: notifier)
  }
}
