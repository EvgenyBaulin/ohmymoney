import AppCore
import XCTest

@testable import OhMyMoney

/// The journal on disk: what is written, what a build writes at all, when it is rolled round
/// and when it is put on the platter.
final class LogbookTests: XCTestCase {
  private var directory: URL!

  override func setUpWithError() throws {
    try super.setUpWithError()
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-logs-\(UUID().uuidString)", isDirectory: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: directory)
    try super.tearDownWithError()
  }

  private func lines(in name: String = "ohmymoney.log") throws -> [String] {
    let url = directory.appendingPathComponent(name)
    guard FileManager.default.fileExists(atPath: url.path) else { return [] }
    return try String(contentsOf: url, encoding: .utf8)
      .split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
  }

  private func event(_ level: LogLevel, _ name: String = "window.opened") -> LogEvent {
    LogEvent(
      at: Date(), level: level, category: .ui, name: name, message: "a window was opened",
      pairs: [LogPair("window", .token("transactions"))])
  }

  func testAnEventBecomesOneLineInTheFile() throws {
    let book = Logbook()
    book.open(directory: directory, threshold: .debug)
    book.write(event(.info))
    book.close()

    let written = try lines()
    XCTAssertEqual(written.count, 1)
    XCTAssertTrue(written[0].contains(" info ui window.opened "))
    XCTAssertTrue(written[0].hasSuffix("window=transactions"))
  }

  /// In Release only `info` and above; in Debug everything.
  func testABuildWritesOnlyWhatItsLevelAllows() throws {
    let book = Logbook()
    book.open(directory: directory, threshold: .info)
    book.write(event(.debug, "debug.noise"))
    book.write(event(.info))
    book.write(event(.error, "error.caught"))
    book.close()

    let written = try lines()
    XCTAssertEqual(written.count, 2, "the debug line should not have been written")
    XCTAssertFalse(written.joined().contains("debug.noise"))
  }

  /// An error is on the platter before the call is over: the line worth reading is the last
  /// one before a crash, and a buffered line is the one that never arrives.
  func testAnErrorIsOnDiskWithoutWaitingForTheFileToClose() throws {
    let book = Logbook()
    book.open(directory: directory, threshold: .debug)
    book.write(event(.error, "error.caught"))

    XCTAssertEqual(try lines().count, 1, "the error had not reached the file")
    book.close()
  }

  /// The same promise kept by what the app calls, not by the journal on its own: when
  /// `AppLog.error` returns, the line is in the file. It used to be handed to a task that
  /// ran some time later — and a crash in the same turn is exactly when it never runs.
  func testAnErrorOfTheAppIsInTheFileWhenTheCallReturns() throws {
    Logbook.shared.open(directory: directory, threshold: .debug)
    AppLog.error("crash.test", .app, "the last line before a crash")

    let written = try lines()
    Logbook.shared.close()
    XCTAssertTrue(
      written.contains { $0.contains(" error app crash.test ") },
      "AppLog.error returned before its line was in the file")
  }

  /// Lines written just before the journal closes are in it: the quit logs its last lines
  /// and closes the journal in the same breath, and a journal without its exit lines cannot
  /// be told from one cut short by a crash.
  func testTheLinesBeforeTheCloseAreInTheFile() throws {
    Logbook.shared.open(directory: directory, threshold: .debug)
    for index in 0..<50 { AppLog.info("line.\(index)", .app, "one of fifty") }
    AppLog.info("app.stopped", .app, "the application was put down cleanly")
    Logbook.shared.close()

    let written = try lines()
    XCTAssertEqual(written.count, 51, "lines written before the close were lost")
    XCTAssertTrue(written.last?.contains("app.stopped") == true, "the exit line is not last")
  }

  /// Five files of two megabytes; here the size is small enough to see it happen. The live
  /// file has no number and the numbers grow with age.
  func testTheFileIsRolledRoundAndTheOldestGoes() throws {
    let rotation = LogRotation(maximumBytes: 200, keep: 3)
    let writer = try LogWriter(directory: directory, rotation: rotation)
    for index in 0..<40 { writer.append("line number \(index) of a journal", flush: false) }
    writer.close()

    XCTAssertTrue(
      FileManager.default.fileExists(atPath: directory.appendingPathComponent("ohmymoney.log").path)
    )
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: directory.appendingPathComponent("ohmymoney.1.log").path))
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: directory.appendingPathComponent("ohmymoney.3.log").path),
      "more files than the rotation keeps")
    // The newest line is in the live file, and the oldest is gone altogether.
    XCTAssertTrue(try lines().joined().contains("line number 39"))
    let everything = try rotation.names.flatMap { try lines(in: $0) }.joined()
    XCTAssertFalse(everything.contains("line number 0 "), "the oldest lines should have gone")
  }

  /// The rotation counts what is on disk, not what was asked for: the size grew by every line
  /// whether the disk took it or not, so after a refused write the writer and the file
  /// disagreed, and the file was rolled round early. The refusal here is a file size limit on
  /// this process for the length of one write: 1 KiB, with the file at 1000 bytes.
  func testTheSizeCountsWhatReachedTheDiskNotWhatWasAskedFor() throws {
    let writer = try LogWriter(directory: directory)
    defer { writer.close() }
    writer.append(String(repeating: "a", count: 999), flush: true)
    XCTAssertEqual(writer.size, 1000)

    let previous = signal(SIGXFSZ, SIG_IGN)
    var limit = rlimit()
    XCTAssertEqual(getrlimit(RLIMIT_FSIZE, &limit), 0)
    var tight = limit
    tight.rlim_cur = 1024
    XCTAssertEqual(setrlimit(RLIMIT_FSIZE, &tight), 0)
    writer.append(String(repeating: "b", count: 499), flush: true)
    setrlimit(RLIMIT_FSIZE, &limit)
    signal(SIGXFSZ, previous)

    let onDisk = try XCTUnwrap(
      FileManager.default.attributesOfItem(atPath: writer.liveFile.path)[.size] as? Int)
    XCTAssertLessThan(onDisk, 1500, "the limit did not refuse the write")
    XCTAssertEqual(writer.size, onDisk, "the writer counts bytes the disk never took")
  }

  /// The journal opens from the `.task` of the first window, and that window is laid out
  /// before: its `window.opened`, and a stand-in that fires in its first pass —
  /// `dependencies.missing`, the defect the stand-ins exist to surface —
  /// were written while there was no file, and only the system log kept them. They are held
  /// and written, in order and at the level the journal opens with, when it opens.
  func testLinesWrittenBeforeTheJournalOpensAreInItOnceItOpens() throws {
    let book = Logbook()
    book.write(event(.info, "before.open"))
    book.write(event(.debug, "debug.noise"))
    book.write(event(.error, "dependencies.missing"))
    book.open(directory: directory, threshold: .info)
    book.write(event(.info, "after.open"))
    book.close()

    let written = try lines()
    XCTAssertEqual(
      written.map { $0.split(separator: " ")[3] },
      ["before.open", "dependencies.missing", "after.open"],
      "the lines written before the journal opened were lost")
  }

  /// What is held is bounded — a journal that never opens must not grow for ever — and what
  /// did not fit is counted in a line of its own, not dropped without a word.
  func testTheLinesHeldBeforeTheJournalOpensAreBoundedAndTheRestCounted() throws {
    let book = Logbook()
    for _ in 0..<(Logbook.earlyLimit + 3) { book.write(event(.info, "early.line")) }
    book.open(directory: directory, threshold: .info)
    book.close()

    let written = try lines()
    XCTAssertEqual(written.filter { $0.contains(" early.line ") }.count, Logbook.earlyLimit)
    XCTAssertTrue(written.last?.contains(" journal.overflow ") == true, written.last ?? "")
    XCTAssertTrue(written.last?.hasSuffix("dropped=3") == true, written.last ?? "")
  }

  /// A journal that cannot be opened — its folder out of reach — used to be a `try?` and
  /// nothing more: not a word in the system log, and a report that later counted no files
  /// without saying why. The system log says so, since the file cannot.
  @MainActor
  func testAJournalThatCannotOpenSaysSoInTheSystemLog() throws {
    let probe = LogProbe()
    try XCTSkipIf(probe.isBlind, "the process log cannot be read back here")
    let before = probe.counts(of: ["journal.unavailable"])
    // A file where the folder of the journal should be: nothing can be created under it.
    try FileManager.default.createDirectory(
      at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("not a folder".utf8).write(to: directory)
    let book = Logbook()

    book.open(directory: directory.appendingPathComponent("Logs"), threshold: .debug)
    book.write(event(.error, "error.caught"))
    XCTAssertNotNil(book.openFailure, "what a report says in place of the files")
    book.close()
    XCTAssertNil(book.openFailure, "a closed journal is not a failed one")

    let deadline = Date().addingTimeInterval(2)
    while probe.seen(of: ["journal.unavailable"], comparedWith: before).isEmpty, Date() < deadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    XCTAssertEqual(
      probe.seen(of: ["journal.unavailable"], comparedWith: before), ["journal.unavailable"],
      "a journal that could not open said nothing")
  }

  /// A journal opened twice in a row does not lose what was there.
  func testOpeningAgainAppendsRatherThanStartsOver() throws {
    let first = Logbook()
    first.open(directory: directory, threshold: .debug)
    first.write(event(.info, "first.line"))
    first.close()

    let second = Logbook()
    second.open(directory: directory, threshold: .debug)
    second.write(event(.info, "second.line"))
    second.close()

    let written = try lines()
    XCTAssertEqual(written.count, 2)
    XCTAssertTrue(written[0].contains("first.line"))
    XCTAssertTrue(written[1].contains("second.line"))
  }
}
