import AppCore
import Foundation
import SwiftUI

/// What the app was launched with, for the checks and the measurements of the build.
/// An owner who opens the app from the Dock passes none of these.
///
/// * `--data-set <sample|sample-large|bench|ui-test|demo>` — a folder of its own for synthetic
///   data (`AppPaths.DataSet`); the Debug and Release databases are never touched.
/// * `--generate <months|large>`, and the older `--generate-sample` for six months — Debug
///   only: the set's folder is made anew and filled with a generated history before the
///   app opens it. Without `--data-set` the set is `sample`, or `sample-large` for `large`.
/// * `--seed <n>` — Debug only: the seed that set is generated from, instead of the fixed one
///   (`DataSetGeneration.fixedSeed`). `make demo` passes a random one and prints it, so the
///   same demo can be made again on the same day and in the same interface language — the
///   history ends on the day of the launch and is named in that language; the journal says the
///   seed too (`dataset.generated`). A whole number from 0 up to `Int.max`, so the journal can
///   write it as a count; anything else is passed over.
/// * `--generate empty` — Debug only, with `--data-set`: the set's folder is made anew with an
///   empty database, and the questions of a first launch (the cards of the guide, the starter
///   set, the setup of the accounts) are asked on it as on a new install. Their memory is kept
///   apart from the Debug defaults (`FirstRunMemory`), so a run never changes what the Debug
///   build remembers.
/// * `--test-io` — Debug only: the file panels of the UI tests (the folder of the CSV export,
///   the statement to import, the file of a report) answer with files of a folder in the app's
///   own caches instead of opening, which an automated test cannot drive reliably. The test
///   runner is sandboxed too and cannot write into that folder, so the files it needs come in
///   the arguments: `--test-io-file <name>=<base64>`, once per file, written there at launch.
/// * `--generate-only` — Debug only: quit once the set is written (`make bench-app`).
/// * `--slow-pipeline` — Debug only: every step of the pipeline takes three seconds from the
///   run of the launch on, as Debug → Pipeline → «Slow down» makes it for ⌘R, so the
///   placeholders of the start can be seen (`make sample ARGS=--slow-pipeline`).
/// * `--open transactions,analytics,reports,whatif` — open these at launch (`transactions`,
///   `analytics` and `reports` are sections of the main window, chosen in place of the screen
///   it opens on; `whatif` is a window of its own);
///   `--analytics-section <id>` and `--analytics-period <month|year|12m>` choose what the
///   Analytics window shows, and only on a data set: the set keeps them under keys of its
///   own (`AnalyticsWindow.storageKey`), because the Debug build and the Release of
///   `make bench-app` share one domain of defaults — the Debug id — and the build's own
///   window is not the set's. They open windows and choose, never write data, and never
///   touch what the window outside the set shows. Outside Debug they are taken only together
///   with `--measure`, the measurement they serve.
/// * `--measure` — the Analytics window times every change (`AnalyticsMeasurement`);
///   `--measure-runs <n>` makes n changes by itself and quits (`make bench-app`).
/// * `--no-reminders` — Debug only: the sheet of the day's reminders stays away, so a UI test
///   clicks in the window rather than in a sheet over it.
/// * `--present period-chooser,inspector` — Debug only: shows by itself, three seconds after
///   its window appears, what otherwise takes a click — the period chooser of Analytics and
///   Reports, the inspector of Transactions on the newest operation (with `selection`, that
///   operation selected too, as after a double click), the card of the first debt (`debt`). The checks of the build
///   have no permission to click; this is how the crash of 19.09, a view shown in a host of
///   its own without the app's environment, is reproduced.
///
/// AppKit reads the arguments as `-key value` pairs: a flag without a value followed by
/// another flag takes it as its value, and the word after that is left without a key. AppKit
/// used to open such a word as a document, and a launch that opens a document makes no
/// window, so nothing started at all (found by `make bench-app`: `--measure --data-set bench`
/// opened the app without a window). The app now registers `NSTreatUnknownArgumentsAsOpen =
/// NO` (`OhMyMoneyApp.init`); the recipes still put flags without a value last.
struct LaunchOptions: Equatable, Sendable {
  /// How much history a set is generated with.
  enum Generation: Equatable, Sendable {
    /// Calendar months up to today, at the everyday density.
    case months(Int)
    /// The large set of the performance suite: about 20 000 operations over two years.
    case large
  }

  enum Window: String, CaseIterable, Sendable {
    case transactions, analytics, reports, whatif
  }

  /// What `--present` shows without a click.
  enum Presentation: String, CaseIterable, Sendable {
    case periodChooser = "period-chooser"
    case inspector
    case debt
    /// With `inspector`: the operation selected too, as the click of a double click does —
    /// the selection bar and the inspector at once.
    case selection
  }

  var dataSet: AppPaths.DataSet?
  var generation: Generation?
  /// `--seed`: what the generated set is drawn from; `nil` — the fixed seed.
  var seed: UInt64?
  var generatesOnly = false
  /// `--generate empty`: an empty set whose first-launch questions are asked (Debug).
  var startsEmpty = false
  /// `--test-io`: the file panels answer from the test folder (Debug).
  var usesTestIO = false
  /// `--test-io-file <name>=<base64>`: the files the test folder holds from the launch on.
  var testIOFiles: [String: Data] = [:]
  var slowsPipeline = false
  /// `--no-reminders`: the sheet of the day's reminders is not shown (Debug; the UI tests).
  var suppressesReminders = false
  var windows: [Window] = []
  var presents: Set<Presentation> = []
  /// `--section planning|debts` — Debug only: the main window opens on that section.
  var section: String?
  var analyticsSection: String?
  var analyticsPeriod: String?
  var measures = false
  var measureRuns: Int?

  /// The options of this process, read once — with what a relaunch carried over from the
  /// instance before it (`RelaunchCarry`), which the arguments of the command line outrank. Not
  /// in the test host: the defaults there are the owner's Debug ones.
  static let current = LaunchOptions(
    arguments: ProcessInfo.processInfo.arguments
      + (AppEnvironment.isTestHost ? [] : RelaunchCarry.take()),
    debug: isDebug)

  static var isDebug: Bool {
    #if DEBUG
      true
    #else
      false
    #endif
  }

  /// Unknown words and values are passed over: a mistyped argument opens the app as usual
  /// rather than somewhere unexpected.
  init(arguments: [String], debug: Bool) {
    func value(after flag: String) -> String? {
      guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
        return nil
      }
      return arguments[index + 1]
    }

    measures = arguments.contains("--measure")
    measureRuns = value(after: "--measure-runs").flatMap(Int.init).filter { $0 > 0 }
    dataSet = value(after: "--data-set").flatMap(AppPaths.DataSet.init(rawValue:))

    if debug {
      if value(after: "--generate") == "empty", dataSet != nil, dataSet != .learn {
        startsEmpty = true
      } else if let text = value(after: "--generate") {
        generation = text == "large" ? .large : Int(text).filter { $0 > 0 }.map(Generation.months)
      } else if arguments.contains("--generate-sample") {
        generation = .months(6)
      }
      if generation != nil, dataSet == nil {
        dataSet = generation == .large ? .sampleLarge : .sample
      }
      generatesOnly = generation != nil && arguments.contains("--generate-only")
      seed = value(after: "--seed").flatMap { UInt64($0) }.filter { $0 <= UInt64(Int.max) }
      usesTestIO = arguments.contains("--test-io")
      for (index, word) in arguments.enumerated() where word == "--test-io-file" {
        guard index + 1 < arguments.count, let split = arguments[index + 1].firstIndex(of: "="),
          let data = Data(base64Encoded: String(arguments[index + 1][arguments[index + 1].index(after: split)...]))
        else { continue }
        testIOFiles[String(arguments[index + 1][..<split])] = data
      }
      slowsPipeline = arguments.contains("--slow-pipeline")
      suppressesReminders = arguments.contains("--no-reminders")
      presents = Set(
        value(after: "--present")?.split(separator: ",")
          .compactMap { Presentation(rawValue: String($0).trimmingCharacters(in: .whitespaces)) }
          ?? [])
      section = value(after: "--section")
    }

    guard debug || measures else { return }
    windows =
      value(after: "--open")?.split(separator: ",")
      .compactMap { Window(rawValue: String($0).trimmingCharacters(in: .whitespaces)) } ?? []
    // Without a set the choices would land in the owner's own Analytics window.
    guard dataSet != nil else { return }
    analyticsSection = value(after: "--analytics-section")
    analyticsPeriod = value(after: "--analytics-period")
  }
}

/// `--present`: waits until the window has been on screen a moment, then says whether to show
/// the thing by itself. Never true outside Debug (`LaunchOptions`).
enum LaunchPresentation {
  static func due(_ presentation: LaunchOptions.Presentation) async -> Bool {
    guard LaunchOptions.current.presents.contains(presentation) else { return false }
    try? await Task.sleep(for: .seconds(3))
    return !Task.isCancelled
  }
}

extension Optional {
  /// The value when it passes the test, nothing otherwise.
  fileprivate func filter(_ isIncluded: (Wrapped) -> Bool) -> Wrapped? {
    flatMap { isIncluded($0) ? $0 : nil }
  }
}

/// `--open` and the choices of the Analytics window, carried out once per process by the
/// first main window (LaunchOptions). The choices go where the Analytics window of the data
/// set keeps its own (`UserDefaults`, `AnalyticsWindow.storageKey`), before it opens, so the
/// window starts on them as if it had been left there — and can still be changed, which the
/// measurement needs. The owner's window, under the keys without a set, is never touched.
@MainActor
enum LaunchWindows {
  private static var done = false

  static func open(
    with openWindow: OpenWindowAction, options: LaunchOptions = .current, today: DateOnly
  ) {
    guard !done else { return }
    done = true
    let defaults = UserDefaults.standard
    if let section = options.analyticsSection.flatMap(AnalyticsSection.init(rawValue:)) {
      defaults.set(
        section.rawValue,
        forKey: AnalyticsWindow.storageKey(
          AnalyticsWindow.sectionStorageName, dataSet: options.dataSet))
    }
    if let kind = options.analyticsPeriod.flatMap(AnalyticsPeriod.Kind.init(launchName:)) {
      defaults.set(
        AnalyticsPeriod.current(kind, today: today).storage,
        forKey: AnalyticsWindow.storageKey(
          AnalyticsWindow.periodStorageName, dataSet: options.dataSet))
    }
    // Transactions, Analytics and Reports are screens of the main window, which chooses them
    // itself (`MainWindow`).
    for window in options.windows where window == .whatif {
      openWindow(id: window.rawValue)
    }
  }
}

extension AnalyticsPeriod.Kind {
  /// `--analytics-period month`, `year` or `12m`.
  init?(launchName: String) {
    switch launchName {
    case "month": self = .month
    case "year": self = .year
    case "12m", "twelveMonths": self = .twelveMonths
    default: return nil
    }
  }
}
