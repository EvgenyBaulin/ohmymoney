import AppCore
import XCTest

@testable import OhMyMoney

/// «При старте ставится отметка "работает", при нормальном выходе — "завершено чисто". Если
/// при следующем старте отметка осталась, в журнал пишется, что сессия оборвалась, и
/// приложение предлагает собрать отчёт».
///
/// The point is that the next crash should not need a terminal: the app itself says the last
/// session was cut short.
final class SessionMarkerTests: XCTestCase {
  private var directory: URL!

  override func setUpWithError() throws {
    try super.setUpWithError()
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-session-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: directory)
    try super.tearDownWithError()
  }

  private var marker: URL { SessionMarker.url(in: directory) }

  func testAFirstEverStartLeavesTheMarkAndReportsNothing() {
    XCTAssertFalse(SessionMarker.begin(in: directory), "there was no previous session to report")
    XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "the mark was not left")
  }

  func testACleanExitTakesTheMarkAway() {
    SessionMarker.begin(in: directory)
    SessionMarker.end(in: directory)

    XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    XCTAssertFalse(SessionMarker.begin(in: directory), "a clean exit was read as a crash")
  }

  /// The process was killed: nothing removed the mark, and the next start says so.
  func testAMarkLeftBehindSaysTheSessionWasCutShort() {
    SessionMarker.begin(in: directory)
    // No `end`: this is what a crash leaves.
    XCTAssertTrue(SessionMarker.begin(in: directory), "the interrupted session went unnoticed")
    // And the new session leaves its own mark, so the next start is judged on this one.
    XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
  }

  /// The lines the journal got while `body` ran, from a journal of the test's own.
  private func journal(during body: () -> Void) throws -> [String] {
    let logs = directory.appendingPathComponent("Logs-\(UUID().uuidString)", isDirectory: true)
    Logbook.shared.open(directory: logs, threshold: .debug)
    body()
    Logbook.shared.close()
    let text = try String(
      contentsOf: logs.appendingPathComponent("ohmymoney.log"), encoding: .utf8)
    return text.split(separator: "\n").map(String.init)
  }

  /// A mark that could not be written switched the detection of a crash off for the whole
  /// session without a word: the next launch after a crash said nothing, and nobody could
  /// tell that from a clean exit. The journal says the mark is missing, and why.
  func testAMarkThatCouldNotBeLeftIsInTheJournal() throws {
    // A file stands where the folder of the mark should be.
    let blocked = directory.appendingPathComponent("blocked")
    try Data().write(to: blocked)

    let lines = try journal { SessionMarker.begin(in: blocked) }

    let line = try XCTUnwrap(
      lines.first { $0.contains(" session.markFailed ") }, "nothing says the mark is missing")
    XCTAssertTrue(line.contains(" error="), line)
  }

  /// And a mark that could not be taken away at the end — the next launch will read it as a
  /// crash — says so before the journal closes.
  func testAMarkThatCouldNotBeTakenAwayIsInTheJournal() throws {
    let sealed = directory.appendingPathComponent("sealed", isDirectory: true)
    SessionMarker.begin(in: sealed)
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: sealed.path)
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: sealed.path)
    }

    let lines = try journal { SessionMarker.end(in: sealed) }

    XCTAssertTrue(FileManager.default.fileExists(atPath: SessionMarker.url(in: sealed).path))
    XCTAssertNotNil(
      lines.first { $0.contains(" session.markNotRemoved ") },
      "nothing says the next launch will report a crash: \(lines)")
    // A session that left no mark has none to take away, and says nothing more.
    let quiet = try journal { SessionMarker.end(in: directory.appendingPathComponent("none")) }
    XCTAssertFalse(quiet.contains { $0.contains(" session.mark") }, "\(quiet)")
  }

  /// What the mark holds is the session, not the owner: a version and a time, nothing else.
  func testTheMarkHoldsNothingPersonal() throws {
    SessionMarker.begin(in: directory)
    let text = try String(contentsOf: marker, encoding: .utf8)

    XCTAssertFalse(text.isEmpty)
    XCTAssertEqual(
      LogPrivacy.offences(in: text, forbidding: ["Александра", "Продукты", "12 345,67"]), [])
  }
}
