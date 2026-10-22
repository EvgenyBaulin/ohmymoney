import AppCore
import Foundation
import GRDB

/// The name of the copy of the whole database that a device keeps in the shared folder, next to
/// its journal files: `snapshot-<deviceId>.ohmymoney-snapshot`. The suffix is not `.sqlite` on
/// purpose: it is a copy made for the exchange, never the live database, and no tool should
/// take one for the other.
public enum SyncSnapshotName {
  public static let prefix = "snapshot-"
  public static let suffix = ".ohmymoney-snapshot"

  public static func fileName(deviceId: String) -> String { prefix + deviceId + suffix }

  /// The device a snapshot name belongs to, or `nil` for a name that is not a snapshot's.
  public static func parse(_ name: String) -> String? {
    guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return nil }
    let device = String(name.dropFirst(prefix.count).dropLast(suffix.count))
    return SyncDevice.isValid(id: device) ? device : nil
  }
}

public struct SyncSnapshotInfo: Sendable, Hashable {
  public var name: String
  public var modified: Date
  public init(name: String, modified: Date) {
    self.name = name
    self.modified = modified
  }
}

/// A shared folder that can also hold the snapshot. Only the snapshot's own name goes through
/// it; the folder refuses every other.
public protocol SnapshotFolder: Sendable {
  func snapshots() throws -> [SyncSnapshotInfo]
  /// Puts the file under the snapshot's name, replacing the one there in a single step: at no
  /// moment is there no snapshot, or half of one.
  func putSnapshot(named name: String, from file: URL) throws
  /// Copies the snapshot to a local file that does not exist yet.
  func fetchSnapshot(named name: String, to file: URL) throws
}

extension DirectoryJournalFolder: SnapshotFolder {
  public func snapshots() throws -> [SyncSnapshotInfo] {
    try listNames().compactMap { name in
      guard SyncSnapshotName.parse(name) != nil else { return nil }
      let values = try? url.appendingPathComponent(name).resourceValues(forKeys: [
        .contentModificationDateKey
      ])
      return SyncSnapshotInfo(
        name: name, modified: values?.contentModificationDate ?? .distantPast)
    }
  }

  public func putSnapshot(named name: String, from file: URL) throws {
    guard SyncSnapshotName.parse(name) != nil else { throw SyncFolderError.refusedName }
    let manager = FileManager.default
    let temporary = url.appendingPathComponent(SyncFormat.temporaryPrefix + name)
    let destination = url.appendingPathComponent(name)
    do {
      try? manager.removeItem(at: temporary)
      try manager.copyItem(at: file, to: temporary)
      if manager.fileExists(atPath: destination.path) {
        _ = try manager.replaceItemAt(destination, withItemAt: temporary)
      } else {
        try manager.moveItem(at: temporary, to: destination)
      }
    } catch {
      try? manager.removeItem(at: temporary)
      throw SyncFolderError.notWritable
    }
  }

  public func fetchSnapshot(named name: String, to file: URL) throws {
    guard SyncSnapshotName.parse(name) != nil else { throw SyncFolderError.refusedName }
    do {
      try FileManager.default.copyItem(at: url.appendingPathComponent(name), to: file)
    } catch {
      throw SyncFolderError.notReadable
    }
  }
}

public enum SyncSnapshotError: Error, Sendable, Equatable {
  /// The folder holds no snapshot.
  case none
  /// The snapshot is not a sound database: nothing of it is used.
  case damaged
  /// A newer build wrote it; this one would refuse to open it.
  case newerSchema
  /// The local copy of the books could not be made.
  case notWritten
}

extension SyncExchange {
  /// Writes the copy of the whole database into the folder — once a day, and after the books
  /// were seeded — unless there is nothing of the owner's in it (an empty copy would shadow a
  /// full one). The copy has the bookkeeping of the exchange taken out: it is the books, not
  /// this device's memory of the folder. Returns whether a snapshot was written.
  @discardableResult
  public func snapshotIfDue(
    to folder: any SnapshotFolder, now: Date = Date(), force: Bool = false
  ) throws -> Bool {
    let day = String(SyncInstant(date: now).text.prefix(10))
    let due = try writer.read { db -> Bool in
      let flagged =
        try String.fetchOne(
          db, sql: "SELECT value FROM sync_meta WHERE key = ?", arguments: [Self.snapshotDueKey])
        == "1"
      let last = try String.fetchOne(
        db, sql: "SELECT value FROM sync_meta WHERE key = ?", arguments: [Self.snapshotDayKey])
      return flagged || last != day
    }
    guard due || force, holdsOwnerData else { return false }
    try writeSnapshot(to: folder)
    try writer.write { db in
      try Self.setMeta(db, Self.snapshotDayKey, day)
      try db.execute(
        sql: "DELETE FROM sync_meta WHERE key = ?", arguments: [Self.snapshotDueKey])
    }
    return true
  }

  /// A consistent copy of the database, stripped of the exchange's bookkeeping, checked, and
  /// put in the folder under this device's snapshot name.
  func writeSnapshot(to folder: any SnapshotFolder) throws {
    let manager = FileManager.default
    let scratch = manager.temporaryDirectory
      .appendingPathComponent("ohmymoney-snapshot-\(UUID().uuidString)", isDirectory: true)
    do {
      try manager.createDirectory(at: scratch, withIntermediateDirectories: true)
    } catch {
      throw SyncSnapshotError.notWritten
    }
    defer { try? manager.removeItem(at: scratch) }
    let copy = scratch.appendingPathComponent("copy.sqlite")
    do {
      try writer.writeWithoutTransaction { db in
        try db.execute(sql: "VACUUM INTO ?", arguments: [copy.path])
      }
      let queue = try DatabaseQueue(path: copy.path)
      try queue.write { db in
        for table in SyncTables.bookkeeping { try db.execute(sql: "DELETE FROM \(table)") }
      }
      let verdict = try queue.read { db in try String.fetchOne(db, sql: "PRAGMA integrity_check") }
      try queue.close()
      guard verdict == "ok" else { throw SyncSnapshotError.notWritten }
    } catch let error as SyncSnapshotError {
      throw error
    } catch {
      throw SyncSnapshotError.notWritten
    }
    try folder.putSnapshot(named: SyncSnapshotName.fileName(deviceId: deviceId), from: copy)
  }
}

/// The reading side: a device with empty books takes the newest snapshot of the folder, checks
/// it the way a restore checks a copy, and only then lets it be put in place.
public enum SyncSnapshots {
  /// The newest snapshot of any device, or `nil`.
  public static func newest(in folder: any SnapshotFolder) throws -> SyncSnapshotInfo? {
    try folder.snapshots().max { ($0.modified, $0.name) < ($1.modified, $1.name) }
  }

  /// Copies the snapshot to `file` and checks the copy: a sound database of a schema this build
  /// has. A copy that fails is deleted. The file is the very one that will be staged, not the
  /// one it came from.
  public static func fetchVerified(
    _ info: SyncSnapshotInfo, from folder: any SnapshotFolder, to file: URL,
    schema: any SchemaSource
  ) throws {
    let manager = FileManager.default
    try? manager.removeItem(at: file)
    try folder.fetchSnapshot(named: info.name, to: file)
    let verdict: DatabaseStack.FileCheck
    do {
      verdict = try DatabaseStack.check(fileAt: file, schema: schema)
    } catch {
      try? manager.removeItem(at: file)
      throw SyncSnapshotError.damaged
    }
    switch verdict {
    case .sound: return
    case .damaged:
      try? manager.removeItem(at: file)
      throw SyncSnapshotError.damaged
    case .newerSchema:
      try? manager.removeItem(at: file)
      throw SyncSnapshotError.newerSchema
    }
  }
}
