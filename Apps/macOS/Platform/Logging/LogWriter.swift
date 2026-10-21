import AppCore
import Foundation

/// The app's own journal on disk: one file that is appended to, rolled round when it fills up. The
/// arithmetic of the rolling is `CoreLog.LogRotation`; what is here is the disk.
///
/// Not thread-safe on its own: it belongs to `Logbook`, which only ever touches it from one
/// serial queue, and which is the only thing that ever holds one.
final class LogWriter {
  private let directory: URL
  private let rotation: LogRotation
  private var handle: FileHandle?
  /// The bytes of the live file, as far as this writer knows: what reached it, not what was
  /// asked for. What the rotation decides by.
  private(set) var size = 0
  /// A refused write is said once in the system log, not once a line.
  private var hasReportedAFailedWrite = false

  init(directory: URL, rotation: LogRotation = LogRotation()) throws {
    self.directory = directory
    self.rotation = rotation
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try open()
  }

  var liveFile: URL { directory.appendingPathComponent(rotation.name(at: 0)) }

  /// The files of this journal that exist, newest first.
  var files: [URL] {
    rotation.names
      .map(directory.appendingPathComponent)
      .filter { FileManager.default.fileExists(atPath: $0.path) }
  }

  private func open() throws {
    let url = liveFile
    if !FileManager.default.fileExists(atPath: url.path) {
      FileManager.default.createFile(atPath: url.path, contents: nil)
    }
    let handle = try FileHandle(forWritingTo: url)
    size = Int(try handle.seekToEnd())
    self.handle = handle
  }

  /// Appends one event. `flush` puts it on the platter before returning: an `error` is worth
  /// nothing if it is the line that never arrived.
  func append(_ text: String, flush: Bool) {
    let data = Data((text + "\n").utf8)
    if rotation.shouldRoll(current: size, adding: data.count) { roll() }
    guard let handle else { return }
    do {
      try handle.write(contentsOf: data)
    } catch {
      // A full disk, a file size limit: the journal cannot say it in itself, so the system
      // log does, once.
      if !hasReportedAFailedWrite {
        hasReportedAFailedWrite = true
        AppLog.system(
          LogEvent(
            at: Date(), level: .error, category: .app, name: "journal.writeFailed",
            message: "a line could not be written to the journal file",
            pairs: [LogPair("code", .count((error as NSError).code))]))
      }
    }
    // What the file holds, read back rather than added up: a line refused, or cut short, is
    // not counted, and the rotation goes by the file.
    size = (try? handle.offset()).map { Int($0) } ?? size + data.count
    if flush { try? handle.synchronize() }
  }

  /// The oldest file goes, the others move up one, and a new live file is opened. Done by
  /// renaming, so nothing is ever read half-written.
  private func roll() {
    handle?.closeFile()
    handle = nil
    let manager = FileManager.default
    for name in rotation.dropped() {
      try? manager.removeItem(at: directory.appendingPathComponent(name))
    }
    for rename in rotation.renames() {
      let from = directory.appendingPathComponent(rename.from)
      guard manager.fileExists(atPath: from.path) else { continue }
      let to = directory.appendingPathComponent(rename.to)
      try? manager.removeItem(at: to)
      try? manager.moveItem(at: from, to: to)
    }
    size = 0
    try? open()
  }

  func close() {
    try? handle?.synchronize()
    handle?.closeFile()
    handle = nil
  }
}
