import AppCore
import Foundation

/// Says whether the last session ended or was cut short.
///
/// A mark is left beside the journal when the app starts and taken away when it stops in
/// order. Finding one still there at the next start means the session before this did not
/// end — a crash, a kill, the power going — and the app says so in the journal and offers to
/// gather a problem report. The point is that the next crash should not need a terminal to
/// find out about.
///
/// A file, not a row in the database: the database is the thing most likely to have been what
/// broke, and a file outlives both `kill -9` and a database nobody can open.
enum SessionMarker {
  static func url(in directory: URL) -> URL {
    directory.appendingPathComponent("session.running")
  }

  /// Leaves the mark of this session and says whether the one before it was cut short.
  @discardableResult
  static func begin(in directory: URL, at moment: Date = Date()) -> Bool {
    let url = Self.url(in: directory)
    let interrupted = FileManager.default.fileExists(atPath: url.path)
    // The version and the moment, and nothing else: this file is read after a crash, and a
    // crash is exactly when nobody wants to find their own data in a stray file.
    let text = "started \(LogLine.stamp(moment, in: .current)) app \(AppEnvironment.appVersion)\n"
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try Data(text.utf8).write(to: url, options: .atomic)
    } catch {
      // Without the mark a crash of this session goes unnoticed at the next launch: the
      // journal says so, and a report without `session.interrupted` is read knowing it.
      AppLog.error(
        "session.markFailed", .app,
        "the mark of a running session could not be left: a crash will go unnoticed",
        [LogPair("error", .error(error)), LogPair("code", .count((error as NSError).code))])
    }
    return interrupted
  }

  static func end(in directory: URL) {
    let url = Self.url(in: directory)
    do {
      try FileManager.default.removeItem(at: url)
    } catch {
      // A session that left no mark has none to take away.
      guard FileManager.default.fileExists(atPath: url.path) else { return }
      AppLog.error(
        "session.markNotRemoved", .app,
        "the mark of the session could not be taken away: the next launch will read a crash",
        [LogPair("error", .error(error)), LogPair("code", .count((error as NSError).code))])
    }
  }
}
