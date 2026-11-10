import Foundation

/// What a launch with `--generate empty` (a new install on a set of synthetic data) remembers:
/// the guide's progress and whether the starter set was asked live in a suite of their own,
/// new at every launch, so the run asks the first-launch questions every time and never
/// changes what the Debug build remembers for the owner.
enum FirstRunMemory {
  /// A name of its own per process: a suite emptied and written again within a launch is not
  /// reliably empty at the next one.
  static let suiteName = "ohmymoney.firstrun.\(ProcessInfo.processInfo.processIdentifier)"

  /// Whether this process pretends to be a first launch.
  static var isOn: Bool { LaunchOptions.current.startsEmpty }

  /// The suite when the launch is a first run, the app's defaults otherwise.
  nonisolated(unsafe) static let defaults: UserDefaults = {
    guard isOn, let suite = UserDefaults(suiteName: suiteName) else { return .standard }
    return suite
  }()

  /// The data set the first-launch questions look at: none on a first run, so they are asked.
  static var questionsDataSet: AppPaths.DataSet? { isOn ? nil : AppPaths.dataSet }
}
