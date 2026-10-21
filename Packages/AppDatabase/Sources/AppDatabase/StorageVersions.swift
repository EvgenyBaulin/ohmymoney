import Foundation
import SQLite3

/// The versions of what the storage is built on, for the list of dependencies in the problem
/// report.
///
/// SQLite says its own version. GRDB says it nowhere a program can read — the framework it
/// builds into carries `1.0` in its `Info.plist` — so it is written here, and a test holds it
/// to the pin in `Package.resolved`: moving the pin without moving this turns the tests red.
public enum StorageVersions {
  public static let grdb = "7.11.1"

  /// The SQLite library the process runs on.
  public static var sqlite: String { String(cString: sqlite3_libversion()) }
}
