import Foundation

/// The installation's origin and the memory of a synthetic first run. A launch with
/// `--generate empty` keeps the guide and starter-set answers in a suite of its own, new at
/// every launch, so it never changes what the Debug build remembers for the owner.
enum FirstRunMemory {
  /// Local installation origin, captured before opening or generating a database. `true`
  /// means this installation started with the Warm default (0571); `false` preserves the
  /// system default of an older installation. Never exported or exchanged between devices.
  static let installationKey = "app.installation.startedWithWarmTheme"

  @MainActor
  static func installationIsNew(in defaults: UserDefaults, databaseExists: Bool) -> Bool {
    if let marked = defaults.object(forKey: installationKey) as? Bool { return marked }
    let existingKeys = [
      GuideStore.progressKey, StarterSetActions.askedKey,
      AppTheme.schemeKey, AppTheme.accentKey, AppTheme.themeKey,
    ]
    let isNew = !databaseExists && !existingKeys.contains { defaults.object(forKey: $0) != nil }
    defaults.set(isNew, forKey: installationKey)
    return isNew
  }

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
