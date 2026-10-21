import AppKit
import Foundation

/// Quitting waits for the app to put the database down, but never for long.
///
/// `applicationShouldTerminate` answers `.terminateLater` and the app finishes what it is
/// doing — the pipeline stops, the database closes (`AppLaunch.stop`) — before the answer is
/// given. A stop that hangs must not hang the quit with it, so the answer also comes on a
/// limit, and it is given exactly once whichever arrives first.
@MainActor
final class AppQuit {
  /// How the stop ended: before the limit, or not by then.
  enum Outcome: Equatable, Sendable {
    case stopped
    case overran
  }

  /// Given the limit in seconds and what to do then, does it once the limit has passed: a
  /// timer in the app, a switch the test throws in a test, so no test measures its margins
  /// against a loaded machine.
  typealias Clock = @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Void

  static let timer: Clock = { limit, fire in
    DispatchQueue.main.asyncAfter(deadline: .now() + limit) {
      MainActor.assumeIsolated { fire() }
    }
  }

  private let limit: TimeInterval
  private let clock: Clock
  private let reply: (Outcome) -> Void
  private var replied = false

  init(
    limit: TimeInterval = 2, clock: @escaping Clock = AppQuit.timer,
    reply: @escaping (Outcome) -> Void
  ) {
    self.limit = limit
    self.clock = clock
    self.reply = reply
  }

  /// Starts the stop and the clock. Whatever comes first answers, and the other is ignored.
  func begin(_ stop: @escaping () async -> Void) {
    clock(limit) { [weak self] in
      self?.answer(.overran)
    }
    Task { @MainActor [weak self] in
      await stop()
      self?.answer(.stopped)
    }
  }

  private func answer(_ outcome: Outcome) {
    guard !replied else { return }
    replied = true
    reply(outcome)
  }
}

/// The delegate exists for two things: the app is asked to quit and the database is put down in
/// order before it does — by ⌘Q, by the Dock, or by closing the main window (`AppWindows`) —, and
/// the chosen light or dark is on the app before the first window and the first alert.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private var quitting: AppQuit?

  /// The AppKit half of the theme, set before anything is drawn. A fresh `AppTheme` on
  /// purpose: `AppEnvironment` need not be built yet, and both instances read the same two
  /// keys of `UserDefaults`, so they cannot disagree.
  func applicationWillFinishLaunching(_ notification: Notification) {
    AppTheme().applyAppearance()
    // First thing, before any window: the helper of a relaunch opens the app until this
    // instance takes its mark away. Not in the test host, whose folders are the tests' own.
    if !AppEnvironment.isTestHost {
      RelaunchMark.arrival = RelaunchMark.take(in: AppPaths.logsDirectory)
    }
  }

  /// What quitting asks and does. The app's own answers stand here; a test hands in its
  /// own, because `NSApplication.shared.reply(toApplicationShouldTerminate:)` may be sent
  /// exactly once and there is no way to see that it was.
  var hasStarted: @MainActor () -> Bool = { AppLaunch.hasStarted }
  var stop: @MainActor () async -> Void = { await AppLaunch.stopStarted() }
  var answer: @MainActor (Bool) -> Void = {
    NSApplication.shared.reply(toApplicationShouldTerminate: $0)
  }
  var clock: AppQuit.Clock = AppQuit.timer
  /// What the quit does when the stop is still running at the limit, just before it answers.
  var overran: @MainActor () -> Void = { AppLaunch.quitPastTheLimit() }

  func applicationShouldTerminate(
    _ sender: NSApplication
  ) -> NSApplication.TerminateReply {
    AppWindows.noteQuitting()
    guard hasStarted() else { return .terminateNow }
    // ⌘Q pressed twice while the first stop is still running. `AppLaunch.hasStarted` stays
    // true until it finishes, so without this a second `AppQuit` would replace the first —
    // a second shutdown running beside the first one, over the same database, and a second
    // `reply(toApplicationShouldTerminate:)` on its heels, which AppKit does not allow.
    // The first shutdown is already under way and will answer; this one only waits with it.
    if quitting != nil { return .terminateLater }
    let answer = self.answer
    let overran = self.overran
    let quit = AppQuit(clock: clock) { outcome in
      if outcome == .overran { overran() }
      answer(true)
    }
    quitting = quit
    quit.begin(stop)
    return .terminateLater
  }
}
