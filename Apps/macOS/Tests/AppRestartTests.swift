import AppKit
import XCTest

@testable import OhMyMoney

/// A relaunch — the language switch, «Перезапустить», a restore or an import — starts the helper
/// that reopens the app, puts the database down and quits. The owner must never be left with no
/// app and no word about it, nor with an app that waits for good, nor with two of it in the Dock.
@MainActor
final class AppRestartTests: XCTestCase {
  /// Everything the relaunch did, in order.
  private var done: [String] = []
  private var clock = ManualClock()

  override func setUp() async throws {
    try await super.setUp()
    done = []
    clock = ManualClock()
  }

  /// The steps of a relaunch that only write down what they were asked to do.
  private func steps(quits: XCTestExpectation) -> AppRestart.Steps {
    var steps = AppRestart.Steps()
    steps.startHelper = { [unowned self] _ in done.append("helper") }
    steps.stop = { [unowned self] in done.append("stop") }
    steps.tell = { [unowned self] in done.append("tell \($0.reason)") }
    steps.terminate = { [unowned self] in
      done.append("terminate")
      quits.fulfill()
    }
    steps.clock = clock.clock
    return steps
  }

  /// The helper waits before anything is put down: it is what brings the app back, and it
  /// opens it only once this process is gone — never a second instance beside this one.
  func testTheHelperStartsFirstThenTheStopThenTheQuit() async {
    let quits = expectation(description: "the old instance quits")
    AppRestart.relaunch(using: steps(quits: quits))

    await fulfillment(of: [quits], timeout: 5)
    XCTAssertEqual(done, ["helper", "stop", "terminate"])
  }

  /// The helper is handed this very bundle: the app comes back as the same copy, from where
  /// it was opened.
  func testTheHelperReopensThisBundle() async {
    let quits = expectation(description: "the old instance quits")
    var opened: URL?
    var steps = steps(quits: quits)
    steps.startHelper = { opened = $0 }
    AppRestart.relaunch(using: steps)

    await fulfillment(of: [quits], timeout: 5)
    XCTAssertEqual(opened, Bundle.main.bundleURL)
  }

  /// A helper that could not start used to be a new instance that did not open, found out only
  /// after the database was put down — and the old instance quit all the same, leaving no app.
  /// Now nothing is put down: the owner reads why, and the app goes on.
  func testAHelperThatDidNotStartIsSaidAndTheAppKeepsRunning() async {
    let quits = expectation(description: "the old instance quits")
    quits.isInverted = true
    var steps = steps(quits: quits)
    steps.startHelper = { [unowned self] _ in
      done.append("helper")
      throw CocoaError(.fileNoSuchFile)
    }
    AppRestart.relaunch(using: steps)

    await fulfillment(of: [quits], timeout: 0.3)
    XCTAssertEqual(done.count, 2, "\(done)")
    XCTAssertEqual(done.first, "helper")
    XCTAssertTrue(done.last?.hasPrefix("tell ") == true, "\(done)")
    // What the system said ends with a full stop, and the sentence of the alert goes on after
    // it: «…could not prepare its restart: The file doesn't exist.. Nothing was closed».
    XCTAssertTrue(CocoaError(.fileNoSuchFile).localizedDescription.hasSuffix("."))
    XCTAssertFalse(done.last?.hasSuffix(".") == true, "\(done)")
    XCTAssertFalse(done.contains("stop"), "the database was put down with no way back")
    XCTAssertFalse(AppRestart.isUnderWay, "a relaunch that gave up still blocks the next one")
  }

  /// A stop that never ends held the relaunch for good: no quit, the windows of a closing app
  /// on screen. Past the limit the app quits all the same, and the helper opens it again after
  /// the process has ended — so the new instance never meets a database still open.
  func testAStopThatHangsDoesNotHoldTheRelaunchForever() async {
    let gate = Gate()
    let quits = expectation(description: "the old instance quits")
    var steps = steps(quits: quits)
    steps.stop = { [unowned self] in
      done.append("stop")
      await gate.wait()
      done.append("stopped")
    }
    AppRestart.relaunch(using: steps)
    await Task.yield()
    clock.fire()

    await fulfillment(of: [quits], timeout: 2)
    XCTAssertEqual(done, ["helper", "stop", "terminate"])

    // The stop that ends late quits nothing a second time.
    gate.open()
    for _ in 0..<5 { await Task.yield() }
    XCTAssertEqual(done.filter { $0 == "terminate" }.count, 1, "\(done)")
  }

  /// «Перезапустить» pressed twice: one helper, one stop, one quit.
  func testASecondRelaunchWhileTheFirstIsUnderWayDoesNothing() async {
    let gate = Gate()
    let quits = expectation(description: "the old instance quits")
    var steps = steps(quits: quits)
    steps.stop = { [unowned self] in
      done.append("stop")
      await gate.wait()
    }
    AppRestart.relaunch(using: steps)
    AppRestart.relaunch(using: steps)
    await Task.yield()
    gate.open()

    await fulfillment(of: [quits], timeout: 5)
    for _ in 0..<5 { await Task.yield() }
    XCTAssertEqual(done, ["helper", "stop", "terminate"])
  }

  /// What the owner reads when the helper did not start says what went wrong, in both
  /// languages.
  func testTheWordsOfAFailedRelaunchAreTranslated() {
    let language = AppLanguage()
    for choice in [AppLanguage.Choice.english, .russian] {
      language.choice = choice
      for key in ["relaunch.failed.title", "relaunch.failed.helper"] {
        XCTAssertNotEqual(language(key), key, "\(key), \(choice)")
      }
      let message = language.format("relaunch.failed.helper", "the reason")
      XCTAssertTrue(message.contains("the reason"), "\(choice)")
      XCTAssertFalse(message.contains(".."), "\(choice)")
    }
  }
}

/// The helper itself, started for real by the call the app makes, with the opening pointed at a
/// line in a file: it must wait while this process holds its pipe, open once the pipe closes —
/// which is what the end of the application's process does — and open again until the new
/// instance takes its mark away.
@MainActor
final class RelaunchHelperTests: XCTestCase {
  private var marks: URL!
  private var log: URL!

  override func setUp() async throws {
    try await super.setUp()
    marks = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-relaunch-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: marks, withIntermediateDirectories: true)
    log = marks.appendingPathComponent("opened.txt")
  }

  override func tearDown() async throws {
    RelaunchHelper.letGo()
    if let marks { try? FileManager.default.removeItem(at: marks) }
    try await super.tearDown()
  }

  private var pending: URL { RelaunchMark.pending(in: marks) }
  private var lost: URL { RelaunchMark.lost(in: marks) }
  private let bundle = URL(fileURLWithPath: "/Applications/OhMyMoney Test.app")

  /// An opening that writes what it was handed into the log, one line each; `thenStarts` is what
  /// the new instance does on that opening, as a line of shell.
  private func opening(thenStarts: String) -> String {
    "printf '%s\\n' \"$*\" >> '\(log.path)'; \(thenStarts)"
  }

  private var openings: [String] {
    ((try? String(contentsOf: log, encoding: .utf8)) ?? "")
      .split(separator: "\n").map(String.init)
  }

  private func waitForTheEnd(of process: Process) {
    let deadline = Date().addingTimeInterval(10)
    while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
  }

  /// The helper as the app starts it — the pipe it waits on held by `start` itself, not by the
  /// test: a writing end let go too early opens the app while this process still runs.
  func testTheHelperWaitsForThisProcessToEndAndOnlyThenOpens() throws {
    let process = try RelaunchHelper.start(
      bundle: bundle, marks: marks, open: opening(thenStarts: "rm -f '\(pending.path)'"),
      patience: [5, 5])
    XCTAssertTrue(FileManager.default.fileExists(atPath: pending.path), "no mark to open against")

    Thread.sleep(forTimeInterval: 0.8)
    XCTAssertTrue(process.isRunning, "the helper did not wait for the application to end")
    XCTAssertEqual(openings, [], "it opened while the application still ran")

    // What the kernel does when the process ends.
    RelaunchHelper.letGo()
    waitForTheEnd(of: process)
    XCTAssertFalse(process.isRunning, "the helper went on waiting after the end")
    XCTAssertEqual(process.terminationStatus, 0)
    XCTAssertEqual(openings, [bundle.path])
    XCTAssertFalse(FileManager.default.fileExists(atPath: lost.path))
  }

  /// Launch Services still listed the instance that had just quit, and `open` brought forward
  /// what was gone: the mark stayed, and the next opening started the app.
  func testAnOpeningThatBroughtNothingBackIsMadeAgain() throws {
    let process = try RelaunchHelper.start(
      bundle: bundle, marks: marks,
      open: opening(
        thenStarts: "[ \"$(grep -c '' '\(log.path)')\" -ge 2 ] && rm -f '\(pending.path)'"),
      patience: [1, 1, 1])
    RelaunchHelper.letGo()
    waitForTheEnd(of: process)

    XCTAssertEqual(process.terminationStatus, 0)
    XCTAssertEqual(openings, [bundle.path, bundle.path])
    XCTAssertFalse(FileManager.default.fileExists(atPath: lost.path))
  }

  /// No opening brought the app back. The helper gives up, and the next launch — by hand —
  /// finds the mark of a relaunch that was lost, with how often it was tried and what `open`
  /// said the last time.
  func testARelaunchThatNeverOpenedIsLeftForTheNextLaunch() throws {
    let process = try RelaunchHelper.start(
      bundle: bundle, marks: marks, open: opening(thenStarts: "false"), patience: [1, 1])
    RelaunchHelper.letGo()
    waitForTheEnd(of: process)

    XCTAssertEqual(process.terminationStatus, 1)
    XCTAssertEqual(openings.count, 2)
    XCTAssertFalse(FileManager.default.fileExists(atPath: pending.path))
    XCTAssertEqual(RelaunchMark.take(in: marks), .lost(attempts: 2, status: 1))
    XCTAssertFalse(FileManager.default.fileExists(atPath: lost.path), "read again next time")
    XCTAssertEqual(RelaunchMark.take(in: marks), RelaunchMark.Arrival.none)
  }

  /// The instance the helper opened takes the mark away, and the helper stops opening.
  func testTheInstanceARelaunchOpensTakesTheMarkAway() {
    XCTAssertEqual(RelaunchMark.take(in: marks), RelaunchMark.Arrival.none)
    RelaunchMark.leave(at: pending)
    XCTAssertTrue(FileManager.default.fileExists(atPath: pending.path))

    XCTAssertEqual(RelaunchMark.take(in: marks), .relaunched)
    XCTAssertFalse(FileManager.default.fileExists(atPath: pending.path))
  }

  /// The same bundle, opened the ordinary way: never `-n`, which starts a second instance and
  /// puts a second icon in the Dock, and no signal the sandbox refuses.
  func testTheHelperOpensWithoutANewInstance() {
    let script = RelaunchHelper.script()
    XCTAssertTrue(script.contains("open_app() { /usr/bin/open \"$@\"; }"), script)
    XCTAssertFalse(script.contains(" -n"))
    XCTAssertFalse(script.contains("kill"))
    XCTAssertGreaterThan(RelaunchHelper.patience.count, 1, "opened once, and never again")
  }
}

/// What a relaunch hands the instance it opens. A Debug app on a data set came back on the
/// build's own database: the arguments given to `open` from inside the sandbox never reach the
/// new instance, and it looked for the mark of the relaunch in another folder, too. The set goes
/// through the defaults now, for a minute.
final class RelaunchCarryTests: XCTestCase {
  private var suite: String!
  private var defaults: UserDefaults!

  override func setUp() {
    super.setUp()
    suite = "ohmymoney.tests.relaunch.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suite)
  }

  override func tearDown() {
    defaults?.removePersistentDomain(forName: suite)
    super.tearDown()
  }

  /// The data set and nothing else: never `--generate`, which would write the set anew.
  func testOnlyTheDataSetIsCarried() {
    let onSet = LaunchOptions(
      arguments: ["OhMyMoney", "--data-set", "sample", "--generate", "6", "--no-reminders"],
      debug: true)
    XCTAssertEqual(RelaunchCarry.arguments(onSet), ["--data-set", "sample"])
    let generated = LaunchOptions(arguments: ["OhMyMoney", "--generate", "large"], debug: true)
    XCTAssertEqual(RelaunchCarry.arguments(generated), ["--data-set", "sample-large"])
    XCTAssertEqual(
      RelaunchCarry.arguments(LaunchOptions(arguments: ["OhMyMoney"], debug: true)), [])
  }

  /// The instance a relaunch opens finds the set, once, and opens on it.
  func testTheNextInstanceOpensOnTheSetTheLastOneRanOn() {
    let moment = Date()
    RelaunchCarry.leave(["--data-set", "sample"], in: defaults, at: moment)

    let carried = RelaunchCarry.take(from: defaults, now: moment.addingTimeInterval(3))
    XCTAssertEqual(carried, ["--data-set", "sample"])
    XCTAssertEqual(LaunchOptions(arguments: ["OhMyMoney"] + carried, debug: false).dataSet, .sample)
    XCTAssertNil(defaults.object(forKey: RelaunchCarry.key), "left for the launch after it too")
    XCTAssertEqual(RelaunchCarry.take(from: defaults, now: moment.addingTimeInterval(4)), [])

    // What the command line says outranks what was carried.
    let named = LaunchOptions(
      arguments: ["OhMyMoney", "--data-set", "bench"] + carried, debug: true)
    XCTAssertEqual(named.dataSet, .bench)
  }

  /// A relaunch that never opened the app leaves the set behind; the owner's launch by hand
  /// the next morning opens the app's own data, and takes the leftover away.
  func testWhatWasLeftLongAgoIsNotARelaunch() {
    let moment = Date()
    RelaunchCarry.leave(["--data-set", "sample"], in: defaults, at: moment)
    XCTAssertEqual(RelaunchCarry.take(from: defaults, now: moment.addingTimeInterval(3_600)), [])
    XCTAssertNil(defaults.object(forKey: RelaunchCarry.key))

    // Nothing to carry takes away what an earlier relaunch left.
    RelaunchCarry.leave(["--data-set", "sample"], in: defaults, at: moment)
    RelaunchCarry.leave([], in: defaults, at: moment)
    XCTAssertNil(defaults.object(forKey: RelaunchCarry.key))
  }
}
