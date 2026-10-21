import Foundation
import OSLog
import XCTest

/// Reads back what this process wrote to the system log while a test ran.
///
/// The failures these tests hunt are announced by AppKit, SwiftUI and libsqlite3 in the log and
/// nowhere else: «has continued for 300 iterations», «reentrant operation in its NSTableView
/// delegate», «Invalid view geometry», «vnode unlinked while in use». A test that only looks at
/// the view tree sees none of them, so it would pass over a window that survives by a whisker.
///
/// The probe is honest about its own blindness: before it says a message is absent it logs a
/// marker of its own and waits until it can read it back. Without that proof `didSee` says
/// nothing, and the caller is told so rather than given a green light (`isBlind`).
@MainActor
struct LogProbe {
  /// Messages the probe looks for. A test names the ones it cares about.
  enum Message {
    static let layoutLoop = "has continued for 300 iterations"
    static let updateConstraints = "Update Constraints in Window passes"
    static let reentrantTable = "reentrant operation in its NSTableView delegate"
    static let focusedValue = "FocusedValue update tried to update multiple times"
    static let invalidGeometry = "Invalid view geometry"
    static let layoutWhileLayingOut = "already being laid out"
    static let vnodeUnlinked = "vnode unlinked while in use"
    static let customUnitPoint = "Custom UnitPoint values are not supported"
    /// SwiftUI says this when a view writes state while a body is being evaluated. A size
    /// written back into the layout of its own branch is one way to earn it,
    /// so the layout tests watch for it alongside the loop messages.
    static let stateDuringUpdate = "Modifying state during view update"
  }

  private static let log = Logger(
    subsystem: "io.github.EvgenyBaulin.ohmymoney.tests", category: "probe")

  private let started: Date
  private let marker: String
  /// Set once the marker has been read back: only then does an absent message mean anything.
  private(set) var isBlind = true

  /// Proved once per process: the wait for the marker is what makes a probe slow, and the
  /// answer cannot change from test to test.
  private nonisolated(unsafe) static var proven = false

  /// Starts a probe and proves it can read this process's log, waiting up to `timeout`.
  init(_ label: String = #function, timeout: TimeInterval = 2) {
    // A moment before the marker, so the marker itself is inside the range.
    let started = Date().addingTimeInterval(-0.05)
    let marker = "log-probe \(label) \(UUID().uuidString)"
    self.started = started
    self.marker = marker
    // The logger takes its message as an autoclosure, so it is given a local copy: `self` is
    // still being initialised here.
    Self.log.notice("\(marker, privacy: .public)")
    if Self.proven {
      isBlind = false
      return
    }
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
      if Self.entries(since: started).contains(where: { $0.message.contains(marker) }) {
        isBlind = false
        Self.proven = true
        return
      }
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    } while Date() < deadline
  }

  /// Every message of this process since the probe started.
  func messages() -> [String] {
    Self.entries(since: started).map(\.message)
  }

  /// How many times each message has been logged so far. A test takes this before a step and
  /// compares after it: the dates os_log stamps entries with run a little behind the wall
  /// clock, so counting from a moment in time misses messages that were written just after it.
  func counts(of needles: [String]) -> [String: Int] {
    let lines = Self.entries(since: started)
    return Dictionary(
      uniqueKeysWithValues: needles.map { needle in
        (needle, lines.filter { $0.message.contains(needle) }.count)
      })
  }

  /// How many times a message has been logged since the probe started.
  func count(_ needle: String) -> Int { counts(of: [needle])[needle] ?? 0 }

  /// Whether a message appeared. Always false while the probe is blind, so callers check
  /// `isBlind` before they read anything into it.
  func didSee(_ needle: String) -> Bool {
    messages().contains { $0.contains(needle) }
  }

  /// The messages of this run that the caller cares about, counting only what was logged
  /// after `before` was taken.
  func seen(of needles: [String], comparedWith before: [String: Int] = [:]) -> [String] {
    let now = counts(of: needles)
    return needles.filter { (now[$0] ?? 0) > (before[$0] ?? 0) }
  }

  /// Fails the test when any of the messages appeared. A blind probe cannot fail a test — it
  /// prints why, so the run says plainly that this check proved nothing.
  func assertQuiet(
    about needles: [String], comparedWith before: [String: Int] = [:], _ what: String = "",
    file: StaticString = #filePath, line: UInt = #line
  ) {
    guard !isBlind else {
      print("log probe: blind (the process log could not be read back); \(what) not checked")
      return
    }
    let found = seen(of: needles, comparedWith: before)
    guard found.isEmpty else {
      XCTFail("the log says: \(found.joined(separator: " | ")) \(what)", file: file, line: line)
      return
    }
  }

  /// For a watchdog on another thread: what the log says right now, without the main actor.
  nonisolated static func report(of needles: [String], since: Date) -> String {
    let lines = entries(since: since)
    let counts = needles.map { needle in
      "\(needle): \(lines.filter { $0.message.contains(needle) }.count)"
    }
    return counts.joined(separator: "; ")
  }

  private struct Line {
    let date: Date
    let message: String
  }

  nonisolated private static func entries(since: Date) -> [Line] {
    guard let store = try? OSLogStore(scope: .currentProcessIdentifier) else { return [] }
    let position = store.position(date: since)
    guard let entries = try? store.getEntries(at: position) else { return [] }
    return entries.map { Line(date: $0.date, message: $0.composedMessage) }
  }
}

/// The probe has to prove itself before any test leans on it.
@MainActor
final class LogProbeTests: XCTestCase {
  func testTheProbeReadsBackWhatThisProcessLogged() {
    let probe = LogProbe()
    XCTAssertFalse(probe.isBlind, "the probe cannot read this process's own log")
    let logger = Logger(subsystem: "io.github.EvgenyBaulin.ohmymoney.tests", category: "probe")
    let needle = "probe self-test \(UUID().uuidString)"
    logger.notice("\(needle, privacy: .public)")
    let deadline = Date().addingTimeInterval(2)
    while !probe.didSee(needle), Date() < deadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    XCTAssertTrue(probe.didSee(needle))
  }

  func testAMessageThatWasNeverLoggedIsNotFound() {
    let probe = LogProbe()
    XCTAssertFalse(probe.didSee("this message is never logged \(UUID().uuidString)"))
  }
}
