import AppCore
import Foundation

/// A new person's Overview: the ten tiles of the answer instead of every tile there is. «New»
/// is what the starter set already means — an open database of the real data, outside the unit
/// tests and the synthetic sets, whose accounts were not set up and whose starter set was not
/// asked — and nothing of Overview chosen yet: whoever chose a layout, or lives on the list of
/// the builds before groups, keeps it as it is.
@MainActor
enum OverviewFirstRun {
  static func isNewPerson(
    _ environment: AppEnvironment, defaults: UserDefaults = .standard,
    isTestHost: Bool = AppEnvironment.isTestHost, dataSet: AppPaths.DataSet? = AppPaths.dataSet
  ) -> Bool {
    environment.state == .ready && !isTestHost && dataSet == nil
      && environment.accountSetup == nil && !StarterSetActions.wasAsked(in: defaults)
      && defaults.string(forKey: AppEnvironment.overviewLayoutKey) == nil
      && defaults.string(forKey: AppEnvironment.overviewTilesKey) == nil
  }

  /// Gives a new person the ten tiles — written at once, so the choice stays whatever the starter
  /// set does after. Returns whether it did.
  @discardableResult
  static func seed(
    _ environment: AppEnvironment, defaults: UserDefaults = .standard,
    isTestHost: Bool = AppEnvironment.isTestHost, dataSet: AppPaths.DataSet? = AppPaths.dataSet
  ) -> Bool {
    guard
      isNewPerson(environment, defaults: defaults, isTestHost: isTestHost, dataSet: dataSet)
    else { return false }
    environment.overviewLayout = .firstRun
    return true
  }
}
