import AppCore
import CoreKit
import XCTest

@testable import OhMyMoney

/// The journal of openings is a file of its own beside the database: one JSON line a time, cut to
/// the days kept, read newest first, and never a part of the database, the archive or the CSV files.
final class PrivacyJournalStoreTests: XCTestCase {
  private var directory: URL!

  override func setUpWithError() throws {
    try super.setUpWithError()
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-journal-tests-\(UUID().uuidString)")
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: directory)
    try super.tearDownWithError()
  }

  private func store(now: @escaping @Sendable () -> Date, days: Int = 365) -> PrivacyJournalStore {
    PrivacyJournalStore(directory: directory, retentionDays: days, now: now)
  }

  func testNothingIsWrittenUntilSomethingHappens() {
    let journal = store(now: { Date() })
    XCTAssertFalse(FileManager.default.fileExists(atPath: journal.fileURL.path))
    XCTAssertTrue(journal.entries().isEmpty)
  }

  func testEveryEventIsOneLineAndReadsBackNewestFirst() throws {
    let clock = Clock(Date(timeIntervalSince1970: 1_800_000_000))
    let journal = store(now: { clock.now })
    let events: [PrivacyJournalEntry.Event] = [
      .opened, .unlocked(method: .touchID), .hiddenShown, .locked, .exportedCopy,
    ]
    for event in events {
      journal.record(event)
      clock.advance(60)
    }
    let text = try String(contentsOf: journal.fileURL, encoding: .utf8)
    XCTAssertEqual(text.split(separator: "\n").count, events.count)
    XCTAssertTrue(text.hasSuffix("\n"))
    XCTAssertEqual(journal.entries().map(\.event), events.reversed())
    XCTAssertEqual(journal.fileURL.lastPathComponent, "privacy-journal.jsonl")
    XCTAssertEqual(journal.fileURL.deletingLastPathComponent().path, directory.path)
  }

  func testTheLinesCarryTokensOnly() throws {
    let journal = store(now: { Date(timeIntervalSince1970: 1_800_000_000) })
    journal.record(.unlocked(method: .password))
    let text = try String(contentsOf: journal.fileURL, encoding: .utf8)
    XCTAssertEqual(text, #"{"at":"2027-01-15T08:00:00Z","event":"unlocked:password"}"# + "\n")
  }

  func testLinesOlderThanTheDaysKeptAreCutWhenTheJournalIsTrimmed() throws {
    let clock = Clock(Date(timeIntervalSince1970: 1_800_000_000))
    let journal = store(now: { clock.now }, days: 365)
    journal.record(.opened)
    clock.advance(200 * 86_400)
    journal.record(.locked)
    clock.advance(200 * 86_400)
    journal.record(.exportedCopy)
    // The first line is now 400 days old.
    journal.trim()
    let kept = try String(contentsOf: journal.fileURL, encoding: .utf8).split(separator: "\n")
    XCTAssertEqual(kept.count, 2)
    XCTAssertEqual(journal.entries().map(\.event), [.exportedCopy, .locked])
  }

  func testTheDaysKeptCanBeChangedAndTheScreenFollows() {
    let clock = Clock(Date(timeIntervalSince1970: 1_800_000_000))
    let journal = store(now: { clock.now })
    journal.record(.opened)
    clock.advance(40 * 86_400)
    journal.record(.opened)
    XCTAssertEqual(journal.entries().count, 2)
    journal.retentionDays = 30
    XCTAssertEqual(journal.entries().count, 1)
    XCTAssertEqual(journal.retentionDays, 30)
  }

  func testATornLastLineIsSkippedAndTheNextLineStillReads() throws {
    let journal = store(now: { Date(timeIntervalSince1970: 1_800_000_000) })
    journal.record(.opened)
    let handle = try FileHandle(forWritingTo: journal.fileURL)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(#"{"at":"2027-01-15T0"#.utf8))
    try handle.close()
    XCTAssertEqual(journal.entries().map(\.event), [.opened])
    journal.trim()
    XCTAssertEqual(
      try String(contentsOf: journal.fileURL, encoding: .utf8).split(separator: "\n").count, 1,
      "the torn line is cleaned out when the file is rewritten")
  }

  func testClearRemovesTheFile() {
    let journal = store(now: { Date() })
    journal.record(.opened)
    journal.clear()
    XCTAssertFalse(FileManager.default.fileExists(atPath: journal.fileURL.path))
    XCTAssertTrue(journal.entries().isEmpty)
  }

  func testTheFileIsNotAmongTheFilesOfAnExport() {
    XCTAssertFalse(
      ExportTables.all.contains { $0.fileName.contains("journal") },
      "the journal of openings never goes into a CSV export or an archive")
  }
}

private final class Clock: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Date
  init(_ start: Date) { value = start }
  var now: Date {
    lock.lock()
    defer { lock.unlock() }
    return value
  }
  func advance(_ seconds: TimeInterval) {
    lock.lock()
    defer { lock.unlock() }
    value = value.addingTimeInterval(seconds)
  }
}
