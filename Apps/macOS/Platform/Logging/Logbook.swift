import AppCore
import Foundation
import OSLog
import Synchronization

/// The app's journal: every event goes to the system log through `os.Logger` and to a file of
/// our own, which is what a problem report is built from.
///
/// Writing to the file is asynchronous and never blocks the interface; an `error` is put on
/// the platter before `AppLog.error` returns.
///
/// A serial queue, not an actor: a line is handed over in the caller's own turn, so the lines
/// reach the file in the order they were written, and `close()` comes after every line
/// written before it. An actor took each line from a task of its own, and those tasks ran in
/// no promised order and some time later — after the `close()` of a quit, which dropped the
/// exit lines, and never at all when a crash came in the same turn.
final class Logbook: Sendable {
  /// The test host never opens the app's journal — the tests open theirs on folders of their
  /// own — so there the lines of other tests are not held for the first of them to open.
  static let shared = Logbook(holdsEarlyLines: !AppEnvironment.isTestHost)

  private struct State {
    var writer: LogWriter?
    var threshold: LogLevel = .info
    /// Lines handed over before the journal was first opened, kept for it (`holdsEarlyLines`).
    var early: [LogEvent] = []
    /// How many did not fit into `early`.
    var earlyDropped = 0
    /// Set by the first `open`: after it a line without a file is a line after the close.
    var hasOpened = false
    /// The code of the error the last `open` failed with: `nil` while the file is open, and
    /// before the first `open` or after the `close`.
    var openFailure: Int?
  }

  /// At most this many lines are held until the journal opens. A launch writes a handful;
  /// the bound is there for a journal that is never opened at all.
  static let earlyLimit = 500

  /// Whether lines written before the first `open` are held and written when it comes. The
  /// journal opens from the `.task` of the first window, and that window is laid out before:
  /// its `window.opened`, and a stand-in firing in its first pass (`dependencies.missing`),
  /// would otherwise reach only the system log and never the file a report carries.
  private let holdsEarlyLines: Bool

  init(holdsEarlyLines: Bool = true) {
    self.holdsEarlyLines = holdsEarlyLines
  }

  /// The order of the journal: whatever is handed over first is done first, closing included.
  private let queue = DispatchQueue(label: "io.github.EvgenyBaulin.ohmymoney.logbook")
  /// Touched only from `queue`; the lock is what lets the compiler see it is never shared.
  private let state = Mutex(State())

  /// Opens the journal in a directory of its own. Called once at launch, and by a test on a
  /// temporary folder.
  func open(directory: URL, threshold: LogLevel) {
    let failure: Int? = queue.sync {
      state.withLock { state in
        state.writer?.close()
        state.threshold = threshold
        do {
          state.writer = try LogWriter(directory: directory)
          state.openFailure = nil
        } catch {
          state.writer = nil
          state.openFailure = (error as NSError).code
        }
        if !state.hasOpened {
          state.hasOpened = true
          writeEarlyLines(&state)
        }
        return state.openFailure
      }
    }
    // The file cannot say that it is missing; the system log can, and a report says it too
    // (`openFailure`). Written to the system log alone: the file is not there.
    if let failure {
      AppLog.system(
        LogEvent(
          at: Date(), level: .error, category: .app, name: "journal.unavailable",
          message: "the journal file could not be opened: only the system log has the lines",
          pairs: [LogPair("code", .count(failure))]))
    }
  }

  /// The lines held until the first `open`, written first and at the level it set.
  private func writeEarlyLines(_ state: inout State) {
    let early = state.early
    state.early = []
    for event in early where event.level >= state.threshold {
      state.writer?.append(LogLine.text(of: event), flush: event.level.isFlushedAtOnce)
    }
    if state.earlyDropped > 0 {
      let overflow = LogEvent(
        at: Date(), level: .warning, category: .app, name: "journal.overflow",
        message: "lines written before the journal opened were dropped",
        pairs: [LogPair("dropped", .count(state.earlyDropped))])
      state.writer?.append(LogLine.text(of: overflow), flush: false)
      state.earlyDropped = 0
    }
  }

  /// Closes the file once every line handed over before this call is in it.
  func close() {
    queue.sync {
      state.withLock { state in
        state.writer?.close()
        state.writer = nil
        state.openFailure = nil
      }
    }
  }

  /// The code of the error the journal could not be opened with, if the last `open` failed:
  /// what a problem report says in place of the files it cannot carry.
  var openFailure: Int? {
    queue.sync { state.withLock { $0.openFailure } }
  }

  /// The files of the journal, newest first — what the problem report gathers. Every line
  /// written before the call is in them.
  func files() -> [URL] {
    queue.sync { state.withLock { $0.writer?.files ?? [] } }
  }

  /// Hands a line over. An `error` is on the platter when this returns; anything else is
  /// written off the caller's thread, in its turn.
  func write(_ event: LogEvent) {
    if event.level.isFlushedAtOnce {
      queue.sync { append(event) }
    } else {
      queue.async { self.append(event) }
    }
  }

  private func append(_ event: LogEvent) {
    state.withLock { state in
      if !state.hasOpened {
        // The level is decided when the journal opens: the build's threshold is not known
        // before.
        guard holdsEarlyLines else { return }
        if state.early.count < Self.earlyLimit {
          state.early.append(event)
        } else {
          state.earlyDropped += 1
        }
        return
      }
      guard event.level >= state.threshold else { return }
      state.writer?.append(LogLine.text(of: event), flush: event.level.isFlushedAtOnce)
    }
  }

  /// Every line of the journal, oldest file first. For the tests and the problem report.
  func lines() -> [String] {
    files().reversed()
      .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
      .flatMap { $0.split(separator: "\n").map(String.init) }
  }
}

/// How the rest of the app writes to the journal.
///
/// Nothing here takes a sum, a name or a description: `LogValue` has no case for one. What an
/// event carries is identifiers, counts, durations and short words of our own.
enum AppLog {
  /// The system log, by the categories of the app. The subsystem is the bundle id.
  private static let loggers: [LogCategory: Logger] = Dictionary(
    uniqueKeysWithValues: LogCategory.allCases.map {
      ($0, Logger(subsystem: "io.github.EvgenyBaulin.ohmymoney", category: $0.rawValue))
    })

  static func debug(
    _ name: String, _ category: LogCategory, _ message: String, _ pairs: [LogPair] = []
  ) {
    write(
      .init(
        at: Date(), level: .debug, category: category, name: name, message: message, pairs: pairs))
  }

  static func info(
    _ name: String, _ category: LogCategory, _ message: String, _ pairs: [LogPair] = []
  ) {
    write(
      .init(
        at: Date(), level: .info, category: category, name: name, message: message, pairs: pairs))
  }

  static func warning(
    _ name: String, _ category: LogCategory, _ message: String, _ pairs: [LogPair] = []
  ) {
    write(
      .init(
        at: Date(), level: .warning, category: category, name: name, message: message, pairs: pairs)
    )
  }

  /// A caught error: its type and where it was caught, never what it was about. `failure` is
  /// a stack — `Thread.callStackSymbols`, one frame a line — and never a description of the
  /// error: whatever is not a frame is written as `<not-a-frame>` (`LogValue.isFrame`).
  static func error(
    _ name: String, _ category: LogCategory, _ message: String, _ pairs: [LogPair] = [],
    failure: String? = nil
  ) {
    write(
      .init(
        at: Date(), level: .error, category: category, name: name, message: message, pairs: pairs,
        failure: failure))
  }

  static func write(_ event: LogEvent) {
    system(event)
    Logbook.shared.write(event)
  }

  /// The system log alone: what the journal says about its own file.
  static func system(_ event: LogEvent) {
    let line = LogLine.text(of: event)
    // The system log takes it at once and keeps it even when the app cannot write a file.
    let logger = loggers[event.category]
    switch event.level {
    case .debug: logger?.debug("\(line, privacy: .public)")
    case .info: logger?.info("\(line, privacy: .public)")
    case .warning: logger?.warning("\(line, privacy: .public)")
    case .error: logger?.error("\(line, privacy: .public)")
    }
  }

  /// What a build writes: everything in Debug, `info` and above in Release.
  static var threshold: LogLevel {
    #if DEBUG
      .debug
    #else
      .info
    #endif
  }
}
