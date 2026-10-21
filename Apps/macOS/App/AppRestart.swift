import AppCore
import Foundation

#if canImport(AppKit)
  import AppKit
#endif

#if os(macOS)
  /// Relaunches the app in place: the language switch, a restored backup, an imported archive,
  /// «Повторить» after a replacement that did not apply, and «Перезапустить» of a build that
  /// cannot update itself.
  ///
  /// The new instance is opened by a small helper, not by this process: the helper waits until
  /// this process has exited and only then opens the same bundle, the ordinary way. Opened from
  /// here, the new instance had to be forced beside the old one (`createsNewApplicationInstance`)
  /// — two icons in the Dock for a moment, and a second instance starting while the first still
  /// held the database.
  enum AppRestart {
    /// What a relaunch asks and does. The app's own answers stand here; a test hands in its
    /// own, because the real ones start a helper that reopens the app and quit the test host.
    @MainActor
    struct Steps {
      /// Starts what opens `bundle` again once this process has exited.
      var startHelper: @MainActor (_ bundle: URL) throws -> Void = { bundle in
        RelaunchCarry.leave(RelaunchCarry.next ?? RelaunchCarry.arguments(.current))
        do {
          try RelaunchHelper.start(bundle: bundle, marks: AppPaths.logsDirectory)
        } catch {
          RelaunchCarry.leave([])
          throw error
        }
      }
      var stop: @MainActor () async -> Void = { await AppLaunch.stopStarted() }
      var tell: @MainActor (Failure) -> Void = { AppRestart.tell($0) }
      var terminate: @MainActor () -> Void = { NSApplication.shared.terminate(nil) }
      var clock: AppQuit.Clock = AppQuit.timer
    }

    /// The helper could not be started. Nothing has been stopped by then, and the app keeps
    /// running; `reason` is what the system said, for the owner to read.
    struct Failure: Equatable, Sendable {
      let reason: String
    }

    @MainActor
    static func relaunch() {
      // The test host is this very app: a test that reached the real relaunch would start a
      // helper that opens the Debug app, and quit the run. It is counted instead, for a test.
      guard !AppEnvironment.isTestHost else {
        askedInTestHost += 1
        return
      }
      relaunch(using: Steps())
    }

    /// The relaunch that opens the app on another data set — the tutorial's, or with `nil` the
    /// owner's own data again (`GuideActions`). Nothing else changes about the relaunch.
    @MainActor
    static func relaunch(into dataSet: AppPaths.DataSet?) {
      RelaunchCarry.next = dataSet.map { ["--data-set", $0.rawValue] } ?? []
      relaunch()
    }

    /// How many times the real relaunch was asked for in the test host, where it does nothing.
    @MainActor private(set) static var askedInTestHost = 0

    /// How long the database may take to be put down before the app quits anyway. Longer than
    /// the two seconds of a quit (`AppQuit`): the owner asked for the app back, and a stop that
    /// waits for a long step of the pipeline is worth waiting for.
    static let limit: TimeInterval = 10

    /// The relaunch under way: a second press waits with it rather than starting a second
    /// helper and a second stop.
    @MainActor private static var underWay: AppQuit?

    /// Whether a relaunch has begun and not given up.
    @MainActor static var isUnderWay: Bool { underWay != nil }

    /// The helper first: when it cannot start, the owner is told why and nothing else happens —
    /// the database stays open and the app goes on as it was. Then the stop, within `limit`, and
    /// the quit. The helper opens the app only after this process is gone, so the new instance
    /// never meets a database still open here, even when the stop overran: by the time it
    /// starts, the process that held it has ended.
    @MainActor
    static func relaunch(using steps: Steps) {
      guard underWay == nil else { return }
      do {
        try steps.startHelper(Bundle.main.bundleURL)
      } catch {
        AppLog.error(
          "app.relaunchFailed", .app, "the helper that reopens the application did not start",
          [LogPair("error", .error(error))])
        steps.tell(Failure(reason: reason(of: error)))
        return
      }
      AppLog.info("app.relaunching", .app, "the helper waits for the application to quit")
      let relaunch = AppQuit(limit: limit, clock: steps.clock) { outcome in
        Task { @MainActor in
          if outcome == .overran {
            AppLog.warning(
              "app.relaunchOverran", .app, "the application quits before it was put down in full",
              [LogPair("limit", .milliseconds(Int(limit * 1000)))])
          }
          steps.terminate()
          underWay = nil
        }
      }
      underWay = relaunch
      relaunch.begin(steps.stop)
    }

    /// What the system said, without the full stop it ends with: the sentence of the alert goes on
    /// after it («…: %@. Nothing was closed…»).
    static func reason(of error: Error) -> String {
      var text = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
      while text.hasSuffix(".") { text.removeLast() }
      return text
    }

    /// What the owner reads when the relaunch could not begin, in the language of the interface.
    @MainActor
    static func tell(_ failure: Failure) {
      let language = AppLanguage()
      let alert = NSAlert()
      alert.alertStyle = .warning
      alert.messageText = language("relaunch.failed.title")
      alert.informativeText = language.format("relaunch.failed.helper", failure.reason)
      alert.addButton(withTitle: language("action.ok"))
      alert.runModal()
    }
  }

  /// A shell that outlives the app by a moment: it waits for this process to exit, then opens the
  /// bundle the way the Finder would, so there is one instance of the app at every moment.
  ///
  /// It waits on a pipe rather than on the process id. The app keeps the writing end open and
  /// never writes; the kernel closes it when the process ends, however it ends, and the helper's
  /// `read` returns. No signal is sent to anyone: the helper runs in the sandbox of the app, and a
  /// `kill -0` the sandbox refused would read as «gone» and open the app while it still runs.
  ///
  /// Then it opens the bundle until the new instance says it has started: the app leaves a mark
  /// beside its journal before the helper starts (`RelaunchMark`), and the instance that opens
  /// takes it away first thing. Launch Services may still list the instance that has just quit,
  /// and `open` then only activates what is gone; `open` may fail outright. Either way the mark
  /// stays, and the helper opens again, a little later each time. Never with `-n`: an instance
  /// that is merely slow to start would get a second one beside it. When no opening brought the
  /// app back, the mark becomes the mark of a relaunch that was lost, and the next launch —
  /// by hand — writes it into the journal.
  enum RelaunchHelper {
    /// What opens the bundle: `open`, handed the bundle alone. Arguments given after `--args` from
    /// inside the sandbox never reach the new instance; what it has to know goes through the
    /// defaults instead (`RelaunchCarry`).
    static let openCommand = #"/usr/bin/open "$@""#

    /// How long each opening is given to show that the app has started, in fifths of a second;
    /// one opening per value. About twenty seconds in all, a pause of half a second before each.
    static let patience = [10, 15, 20, 25, 30]

    /// The script of the helper. `$1` is the bundle, `$2` the mark the new instance takes away,
    /// `$3` the mark of a relaunch that was lost. `open` is the body of the command that opens
    /// the bundle.
    static func script(open: String = openCommand, patience: [Int] = patience) -> String {
      // `said`, not `status`: that name is taken in zsh, which /bin/sh may be.
      """
      open_app() { \(open); }
      bundle="$1"; mark="$2"; lost="$3"
      while read -r line; do :; done
      attempts=0; said=0
      for polls in \(patience.map(String.init).joined(separator: " ")); do
        attempts=$((attempts + 1))
        sleep 0.5
        open_app "$bundle"
        said=$?
        waited=0
        while [ -e "$mark" ] && [ "$waited" -lt "$polls" ]; do
          sleep 0.2
          waited=$((waited + 1))
        done
        [ -e "$mark" ] || exit 0
      done
      rm "$mark" 2>/dev/null && printf 'attempts %s status %s\\n' "$attempts" "$said" > "$lost"
      exit 1
      """
    }

    /// The writing end of the helper's pipe, held open until the process exits.
    @MainActor private static var held: FileHandle?

    /// The helper, started and waiting for this process to end; the mark it opens the app
    /// against is left first. Throws when `/bin/sh` could not be started, and then leaves no mark.
    /// `open` and `patience` are the tests' to change; the process is returned for them too.
    @MainActor
    @discardableResult
    static func start(
      bundle: URL, marks: URL, open: String = openCommand, patience: [Int] = patience
    ) throws -> Process {
      let mark = RelaunchMark.pending(in: marks)
      RelaunchMark.leave(at: mark)
      let pipe = Pipe()
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/bin/sh")
      let lines = script(open: open, patience: patience)
      let lost = RelaunchMark.lost(in: marks)
      process.arguments = ["-c", lines, "ohmymoney-relaunch", bundle.path, mark.path, lost.path]
      process.standardInput = pipe.fileHandleForReading
      process.standardOutput = FileHandle.nullDevice
      process.standardError = FileHandle.nullDevice
      do {
        try process.run()
      } catch {
        try? FileManager.default.removeItem(at: mark)
        throw error
      }
      // The reading end is the helper's now; this process keeps only the end it never writes to.
      try? pipe.fileHandleForReading.close()
      try? held?.close()
      held = pipe.fileHandleForWriting
      return process
    }

    /// Closes the end the helper waits on — what the end of this process does. For a test, which
    /// cannot end its host to see the helper go on.
    @MainActor
    static func letGo() {
      try? held?.close()
      held = nil
    }

  }

#endif

/// What a relaunch carries over to the instance it opens: the data set this one runs on, so a
/// Debug app on a set comes back on the same set and not on the build's own database — and
/// looks for the mark of the relaunch in the same folder. Through the defaults of the app, not
/// the arguments of `open`: from inside the sandbox those never reach the new instance.
///
/// What is left counts only for a minute: a relaunch opens the app within seconds, and a launch
/// by hand later on is not a relaunch. The new instance reads it once and takes it away
/// (`LaunchOptions.current`).
enum RelaunchCarry {
  static let key = "app.relaunch.carried"
  /// What the next relaunch carries instead of this instance's own set (`relaunch(into:)`).
  @MainActor static var next: [String]?
  static let freshness: TimeInterval = 60

  /// The arguments this instance hands on: `--data-set` and nothing else. Never `--generate`:
  /// the set would be written anew and its history lost.
  static func arguments(_ options: LaunchOptions) -> [String] {
    options.dataSet.map { ["--data-set", $0.rawValue] } ?? []
  }

  /// Left for the next instance; nothing to carry takes away what was there.
  static func leave(
    _ arguments: [String], in defaults: UserDefaults = .standard, at moment: Date = Date()
  ) {
    guard !arguments.isEmpty else {
      defaults.removeObject(forKey: key)
      return
    }
    defaults.set(["arguments": arguments, "at": moment], forKey: key)
  }

  /// What a relaunch left, if it was left within the last minute; taken away either way.
  static func take(from defaults: UserDefaults = .standard, now: Date = Date()) -> [String] {
    guard let carried = defaults.dictionary(forKey: key) else { return [] }
    defaults.removeObject(forKey: key)
    guard let moment = carried["at"] as? Date,
      (0..<freshness).contains(now.timeIntervalSince(moment)),
      let arguments = carried["arguments"] as? [String]
    else { return [] }
    return arguments
  }
}

/// The two marks a relaunch leaves beside the journal (`AppPaths.logsDirectory`). A file, like
/// the mark of a running session (`SessionMarker`): the helper is a shell, and the journal is
/// not open in the instance that reads them until its first window starts.
///
/// * `relaunch.pending` — left before the helper starts; the instance that opens takes it away,
///   and the helper stops opening.
/// * `relaunch.lost` — the pending mark that no opening took away, left by the helper when it
///   gave up. The next launch, by hand, writes it into the journal.
enum RelaunchMark {
  static func pending(in directory: URL) -> URL {
    directory.appendingPathComponent("relaunch.pending")
  }

  static func lost(in directory: URL) -> URL {
    directory.appendingPathComponent("relaunch.lost")
  }

  /// What a launch found beside the journal.
  enum Arrival: Equatable, Sendable {
    /// No relaunch opened this instance, and none was lost.
    case none
    /// A relaunch opened this instance.
    case relaunched
    /// A relaunch before this launch never brought the app back: the helper opened it
    /// `attempts` times, and `open` last said `status`.
    case lost(attempts: Int, status: Int)
  }

  /// Leaves the pending mark: the moment, and nothing else. Without it the helper opens the app
  /// once and stops, as if the first opening had worked — said in the journal.
  static func leave(at url: URL, moment: Date = Date()) {
    do {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data("relaunch \(LogLine.stamp(moment, in: .current))\n".utf8).write(
        to: url, options: .atomic)
    } catch {
      AppLog.warning(
        "app.relaunchMarkFailed", .app, "the relaunch mark was not left: the helper opens once",
        [LogPair("error", .error(error))])
    }
  }

  /// Takes both marks away at launch, the pending one first: the helper is waiting for it.
  static func take(in directory: URL) -> Arrival {
    let files = FileManager.default
    var arrival = Arrival.none
    let pendingMark = pending(in: directory)
    if files.fileExists(atPath: pendingMark.path) {
      arrival = .relaunched
      do {
        try files.removeItem(at: pendingMark)
      } catch {
        // The helper goes on opening what is already open, which only brings it forward, and
        // at the end calls the relaunch lost: the next launch reads a relaunch that was not.
        AppLog.warning(
          "app.relaunchMarkStayed", .app, "the relaunch mark stayed after the relaunch",
          [LogPair("error", .error(error))])
      }
    }
    let lostMark = lost(in: directory)
    if let text = try? String(contentsOf: lostMark, encoding: .utf8) {
      try? files.removeItem(at: lostMark)
      // «attempts 5 status 1»: each number after its word.
      let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
      let numbers = Dictionary(
        zip(words, words.dropFirst().map { Int($0) }).compactMap { word, number in
          number.map { (word, $0) }
        },
        uniquingKeysWith: { first, _ in first })
      arrival = .lost(attempts: numbers["attempts"] ?? 0, status: numbers["status"] ?? 0)
    }
    return arrival
  }

  /// What the launch of this process found; the journal is written once it is open.
  @MainActor static var arrival = Arrival.none

  /// The finding, into the journal — once, when it opens (`AppLaunch.start`).
  @MainActor
  static func writeArrival() {
    switch arrival {
    case .none:
      break
    case .relaunched:
      AppLog.info("app.relaunched", .app, "the helper of a relaunch opened this instance")
    case .lost(let attempts, let status):
      AppLog.error(
        "app.relaunchLost", .app,
        "a relaunch before this launch did not bring the application back",
        [LogPair("attempts", .count(attempts)), LogPair("status", .count(status))])
    }
    arrival = .none
  }
}
