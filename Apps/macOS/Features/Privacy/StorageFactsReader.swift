import AppCore
import AppDatabase
import CoreKit
import Foundation

/// Gathers the plain numbers behind «Что знает приложение» from the open database and the disk:
/// rows per table, the size of the database file, the attached files, the copies, the journal of
/// openings. Counts and sizes only -- no value of any row is read, so nothing here can leak a name
/// or an amount.
enum StorageFactsReader {
  /// Builds the facts from what the caller has read. Pure apart from the sizes of the files it is
  /// pointed at, so a test hands it a folder.
  static func facts(
    tableRows: [String: Int], databaseURL: URL?, attachments: [AttachedFile],
    backupCount: Int, backupFolder: URL?, journalURL: URL?, journalCount: Int
  ) -> StorageFacts {
    var database: Int64 = 0
    if let databaseURL {
      // The write-ahead log is part of the database as far as the disk is concerned.
      for suffix in ["", "-wal"] {
        database += bytes(ofItemAt: URL(fileURLWithPath: databaseURL.path + suffix))
      }
    }
    return StorageFacts(
      tableRows: tableRows, databaseBytes: database, attachmentCount: attachments.count,
      attachmentBytes: attachments.reduce(0) { $0 + max(0, $1.byteSize) },
      backupCount: backupCount,
      backupBytes: backupFolder.map { bytes(ofItemAt: $0) } ?? 0,
      journalCount: journalCount,
      journalBytes: journalURL.map { bytes(ofItemAt: $0) } ?? 0)
  }

  /// The size of a file, or of everything under a folder; 0 for what is not there.
  static func bytes(ofItemAt url: URL) -> Int64 {
    let manager = FileManager.default
    var isFolder: ObjCBool = false
    guard manager.fileExists(atPath: url.path, isDirectory: &isFolder) else { return 0 }
    guard isFolder.boolValue else {
      return ((try? manager.attributesOfItem(atPath: url.path)[.size]) as? Int64) ?? 0
    }
    var total: Int64 = 0
    let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
    guard
      let walk = manager.enumerator(
        at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
    else { return 0 }
    for case let item as URL in walk {
      let values = try? item.resourceValues(forKeys: Set(keys))
      if values?.isRegularFile == true { total += Int64(values?.fileSize ?? 0) }
    }
    return total
  }

  /// Reads the facts of the running app. The database is counted away from the main thread.
  @MainActor
  static func read(_ environment: AppEnvironment) async -> StorageFacts {
    var rows: [String: Int] = [:]
    if let stack = environment.stack {
      rows =
        await Task.detached(priority: .utility) {
          (try? StorageCensus.tableRows(writer: stack.writer)) ?? [:]
        }.value
    }
    let attachments = (try? environment.attachments?.repository.all()) ?? []
    var backupCount = 0
    var backupFolder: URL?
    if let backups = environment.backups {
      backupCount = (try? await backups.backups().count) ?? 0
      backupFolder = await backups.folder
    }
    let journal = environment.privacyJournal
    return facts(
      tableRows: rows, databaseURL: AppPaths.databaseURL(in: AppPaths.dataDirectory),
      attachments: attachments, backupCount: backupCount, backupFolder: backupFolder,
      journalURL: journal.fileURL, journalCount: journal.entries().count)
  }
}

/// Where the things the report speaks of lie, for the owner to find them in the Finder. Display
/// only: nothing here is stored in the database or the archive.
struct StorageLocations: Equatable {
  var dataFolder: String
  var backupsFolder: String?
  /// The folder the owner chose for mirrored copies, when there is one.
  var mirrorFolder: String?

  @MainActor
  static func read(_ environment: AppEnvironment) async -> StorageLocations {
    var backupsFolder: String?
    if let backups = environment.backups { backupsFolder = await backups.folder.path }
    return StorageLocations(
      dataFolder: AppPaths.dataDirectory.path, backupsFolder: backupsFolder,
      mirrorFolder: environment.mirrorFolder?.path)
  }
}
