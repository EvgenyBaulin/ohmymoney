import AppCore
import Foundation

/// Why the shared folder could not be used. Never carries a path or a name.
public enum SyncFolderError: Error, Sendable, Equatable {
  /// The folder is gone, is not a folder, or the bookmark to it no longer opens.
  case missing
  case notReadable
  case notWritable
  /// A name the exchange never writes: the live database, a copy of it, anything that is not
  /// a journal file. Refused before a byte is written.
  case refusedName
}

/// The shared folder as a directory on disk (`JournalFolder`).
///
/// It writes nothing but journal files: a temporary name starts with the journal's temporary
/// prefix, a final name is a journal name, and a final name that already exists is refused — a
/// journal file is immutable. So the live database, its `-wal` and `-shm`, and the copies of the
/// backup folder can not get here even by a mistake of the caller.
public struct DirectoryJournalFolder: JournalFolder {
  public let url: URL

  public init(url: URL) {
    self.url = url
  }

  public func listNames() throws -> [String] {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else { throw SyncFolderError.missing }
    let names: [String]
    do {
      names = try FileManager.default.contentsOfDirectory(atPath: url.path)
    } catch {
      throw SyncFolderError.notReadable
    }
    var ready: [String] = []
    for name in names {
      // iCloud Drive keeps a file that is not on this device as `.<name>.icloud`. Ask for it;
      // it shows under its own name once it has come, and the next exchange reads it.
      if name.hasPrefix("."), name.hasSuffix(".icloud") {
        let real = String(name.dropFirst().dropLast(".icloud".count))
        if SyncFormat.parse(fileName: real) != nil || SyncSnapshotName.parse(real) != nil {
          try? FileManager.default.startDownloadingUbiquitousItem(
            at: url.appendingPathComponent(real))
        }
        continue
      }
      ready.append(name)
    }
    return ready
  }

  public func read(name: String) throws -> Data {
    guard SyncFormat.parse(fileName: name) != nil else { throw SyncFolderError.refusedName }
    do {
      return try Data(contentsOf: url.appendingPathComponent(name))
    } catch {
      throw SyncFolderError.notReadable
    }
  }

  public func put(temporaryName: String, data: Data) throws {
    guard temporaryName.hasPrefix(SyncFormat.temporaryPrefix), !temporaryName.contains("/") else {
      throw SyncFolderError.refusedName
    }
    do {
      try data.write(to: url.appendingPathComponent(temporaryName), options: [])
    } catch {
      throw SyncFolderError.notWritable
    }
  }

  public func rename(temporaryName: String, to name: String) throws {
    guard temporaryName.hasPrefix(SyncFormat.temporaryPrefix), !temporaryName.contains("/"),
      SyncFormat.parse(fileName: name) != nil
    else { throw SyncFolderError.refusedName }
    let destination = url.appendingPathComponent(name)
    guard !FileManager.default.fileExists(atPath: destination.path) else {
      throw SyncFolderError.refusedName
    }
    do {
      try FileManager.default.moveItem(
        at: url.appendingPathComponent(temporaryName), to: destination)
    } catch {
      throw SyncFolderError.notWritable
    }
  }
}

/// Where a shared folder may and may not be. The live database, its copies and the folder
/// the copies are mirrored to must never be the exchange folder, lie in it, or hold it.
public enum SyncFolderPolicy {
  /// `false` for a folder that is, holds or lies in one of `protected`.
  public static func allows(_ folder: URL, protecting protected: [URL]) -> Bool {
    let candidate = normalized(folder)
    for other in protected.map(normalized) {
      if candidate == other || candidate.hasPrefix(other) || other.hasPrefix(candidate) {
        return false
      }
    }
    return true
  }

  private static func normalized(_ url: URL) -> String {
    let path = url.standardizedFileURL.resolvingSymlinksInPath().path
    return path.hasSuffix("/") ? path : path + "/"
  }
}
