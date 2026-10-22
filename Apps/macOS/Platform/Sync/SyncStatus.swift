import AppCore
import AppDatabase
import Foundation

/// Where the exchange with the other devices stands, in the words of the status row.
enum SyncStatus: Equatable {
  /// No folder is chosen (or this is a data set that never exchanges).
  case notConfigured
  case running
  /// The last exchange went through, at this moment.
  case synced(at: Date)
  /// Changes of this device that are not in a file yet.
  case waiting(changes: Int)
  case failed(SyncFailure)

  /// The key of the line under the title, `Sync` catalog. Counts go through the plural key.
  var titleKey: String {
    switch self {
    case .notConfigured: "sync.status.notConfigured"
    case .running: "sync.status.running"
    case .synced: "sync.status.synced"
    case .waiting: "sync.status.waiting.title"
    case .failed: "sync.status.failed"
    }
  }

  /// Only a failure offers «Повторить».
  var offersRetry: Bool {
    if case .failed = self { return true }
    return false
  }
}

extension SyncFailure {
  /// What went wrong, in a sentence the owner can act on (`Sync` catalog).
  var messageKey: String {
    switch self {
    case .folderMissing: "sync.error.folderMissing"
    case .folderNotReadable: "sync.error.folderNotReadable"
    case .folderNotWritable: "sync.error.folderNotWritable"
    case .database: "sync.error.database"
    }
  }
}
