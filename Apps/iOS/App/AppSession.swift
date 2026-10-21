import AppCore
import Foundation
import Observation

/// The three objects every screen needs, made for one data set and thrown away when the owner
/// switches to the other: an environment is closed for good once it has stopped
/// (`AppEnvironment.isClosed`), so a switch puts the old one down in order — pipeline, store,
/// database — and builds a new one on the other set's folder.
///
/// Nothing here opens the database of the set that is not chosen. Switching to the demo never
/// touches the real file, and the other way round; the only thing that changes in between is
/// where `AppPaths` points.
@MainActor
@Observable
final class AppSession {
  private(set) var profile: DataProfile
  private(set) var deps: AppDependencies
  /// Raised by every switch, so the root view starts from nothing for the new set.
  private(set) var generation = 0
  /// A switch is under way: the old set is being put down.
  private(set) var isSwitching = false

  @ObservationIgnored private let profiles: ProfileStore
  @ObservationIgnored private let root: URL
  @ObservationIgnored private let launches: Bool
  @ObservationIgnored private var started = false

  /// `launches` false builds the objects and points `AppPaths` but opens nothing: what a test
  /// of the switching asks for.
  init(
    profiles: ProfileStore = ProfileStore(), root: URL = DataProfile.defaultRoot,
    launches: Bool = !AppEnvironment.isTestHost
  ) {
    self.profiles = profiles
    self.root = root
    self.launches = launches
    let chosen = profiles.current
    profile = chosen
    deps = Self.make(chosen, in: root)
  }

  private static func make(_ profile: DataProfile, in root: URL) -> AppDependencies {
    // Before the environment: it reads the data set when it is made (the lock, the mirror).
    AppPaths.placement = profile.placement(in: root)
    return AppDependencies(
      environment: AppEnvironment(), store: TransactionsStore(),
      compute: ComputeStore(calendar: .system))
  }

  /// The history of the demo: the options a `--data-set demo` launch would have, so it carries
  /// what the showcase adds on top of the sample.
  private static let demoOptions = LaunchOptions(
    arguments: ["--data-set", "demo"], debug: false)

  /// Opens the set. Once for the process; a switch starts the new set itself.
  func start() async {
    guard !started else { return }
    started = true
    await open()
  }

  private func open() async {
    guard launches else { return }
    let deps = self.deps
    // The demo is made once and kept; generating it again would wipe whatever was played with.
    if profile == .demo, !FileManager.default.fileExists(atPath: AppPaths.databaseURL.path) {
      await DataSetGeneration.start(
        deps.environment, generation: .months(6), options: Self.demoOptions)
    }
    await AppLaunch.start(deps.environment, store: deps.store, compute: deps.compute)
  }

  /// Puts the current set down and opens the other. Nothing of the set left behind is touched
  /// after it has been closed.
  func switchProfile(to next: DataProfile) async {
    guard next != profile, !isSwitching else { return }
    isSwitching = true
    defer { isSwitching = false }
    if launches {
      await AppLaunch.stop(deps.environment, compute: deps.compute, store: deps.store)
    }
    profiles.current = next
    profile = next
    deps = Self.make(next, in: root)
    generation += 1
    await open()
  }
}
