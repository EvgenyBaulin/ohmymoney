import AppCore
import Foundation

/// Finds the running app for a command that came from outside a window. A command of «Быстрые
/// команды» may launch the app: the database opens and the first figures are worked out a moment
/// later, so the command waits for them — a few seconds at most — instead of answering «not
/// ready» to a launch that is still under way.
@MainActor
enum MacCommandsHost {
  /// How long a command waits for the database and the first figures of a fresh launch.
  static let patience: Duration = .seconds(15)

  static func commands() async -> MacCommands? {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: patience)
    while clock.now < deadline {
      if let dependencies = AppLaunch.startedDependencies,
        dependencies.compute.wholeSnapshot != nil
      {
        return MacCommands(dependencies: dependencies)
      }
      try? await Task.sleep(for: .milliseconds(200))
    }
    return AppLaunch.startedDependencies.map { MacCommands(dependencies: $0) }
  }

  /// The words of «the app is not ready» when there is not even an environment to ask for them.
  static var notReady: String {
    let language = AppLanguage()
    return language("mac.command.notReady", table: MacCommands.table)
  }
}
