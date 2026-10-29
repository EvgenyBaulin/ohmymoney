import AppCore
import CoreKit
import Foundation

/// The journal of openings: one line a time in a file beside the database of this Mac
/// (`privacy-journal.jsonl`, JSON Lines). It is not in the database, the archive or the CSV files,
/// so it never leaves the Mac with a copy. A line carries a moment and a token -- never an
/// amount, a name or a title. Lines older than the number of days the owner keeps (a year by
/// default) are cut away.
///
/// A line is appended with one write, so a crash leaves at most one torn last line, which the
/// reader skips. Cutting rewrites the file through a temporary one and replaces it in one step.
public final class PrivacyJournalStore: @unchecked Sendable {
  public static let fileName = "privacy-journal.jsonl"

  private let url: URL
  private var kept = PrivacySettings.defaultJournalDays
  private let now: @Sendable () -> Date
  private let lock = NSLock()
  /// The day the file was last cut, so a long session cuts once a day and not at every line.
  private var lastCut: Date?

  /// `directory` is the folder of the data of this copy of the app (`AppPaths.dataDirectory`).
  public init(
    directory: URL, retentionDays: Int = PrivacySettings.defaultJournalDays,
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.url = directory.appendingPathComponent(Self.fileName)
    self.kept = retentionDays
    self.now = now
  }

  /// How many days a line is kept (`privacy.journalDays`); the owner changes it in the settings.
  public var retentionDays: Int {
    get {
      lock.lock()
      defer { lock.unlock() }
      return kept
    }
    set {
      lock.lock()
      defer { lock.unlock() }
      kept = newValue
    }
  }

  public var fileURL: URL { url }

  /// Writes one line. A journal that cannot be written never stops what the owner is doing: the
  /// failure goes to the app's own journal as a type.
  public func record(_ event: PrivacyJournalEntry.Event) {
    lock.lock()
    defer { lock.unlock() }
    let moment = now()
    do {
      let line = try PrivacyJournal.line(for: PrivacyJournalEntry(at: moment, event: event)) + "\n"
      try append(Data(line.utf8))
    } catch {
      AppLog.warning(
        "privacy.journalWrite", .app, "a line of the journal of openings was not written",
        [LogPair("error", .error(error))])
      return
    }
    cutIfDue(at: moment)
  }

  /// Every line that reads, the newest first, for the screen of the journal.
  public func entries() -> [PrivacyJournalEntry] {
    lock.lock()
    defer { lock.unlock() }
    return PrivacyJournal.kept(readAll(), now: now(), days: kept).reversed()
  }

  /// Cuts the lines older than the days kept. Called once at the start and then by `record` once
  /// a day.
  public func trim() {
    lock.lock()
    defer { lock.unlock() }
    cut(at: now())
  }

  /// Removes the file: the owner cleared the journal.
  public func clear() {
    lock.lock()
    defer { lock.unlock() }
    try? FileManager.default.removeItem(at: url)
    lastCut = nil
  }

  // MARK: - File

  private func readAll() -> [PrivacyJournalEntry] {
    guard let data = try? Data(contentsOf: url) else { return [] }
    return PrivacyJournal.entries(in: String(decoding: data, as: UTF8.self))
  }

  private func append(_ data: Data) throws {
    let manager = FileManager.default
    try manager.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    if !manager.fileExists(atPath: url.path) {
      try data.write(to: url, options: .atomic)
      return
    }
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: data)
  }

  private func cutIfDue(at moment: Date) {
    if let lastCut, moment.timeIntervalSince(lastCut) < 86_400 { return }
    cut(at: moment)
  }

  private func cut(at moment: Date) {
    lastCut = moment
    let all = readAll()
    let remaining = PrivacyJournal.kept(all, now: moment, days: kept)
    // Rewritten when a line goes, and when a torn or unknown line would otherwise stay.
    guard remaining.count != all.count || fileHasUnreadableLines(readCount: all.count) else {
      return
    }
    do {
      let text = try remaining.map { try PrivacyJournal.line(for: $0) + "\n" }.joined()
      try Data(text.utf8).write(to: url, options: .atomic)
      AppLog.info(
        "privacy.journalCut", .app, "old lines of the journal of openings were cut",
        [
          LogPair("left", .count(remaining.count)),
          LogPair("cut", .count(all.count - remaining.count)),
        ])
    } catch {
      AppLog.warning(
        "privacy.journalCutFail", .app, "the journal of openings was not cut",
        [LogPair("error", .error(error))])
    }
  }

  private func fileHasUnreadableLines(readCount: Int) -> Bool {
    guard let data = try? Data(contentsOf: url) else { return false }
    let lines = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).count
    return lines != readCount
  }
}
