import AppCore
import Foundation

/// The two sets of data one phone app holds side by side: a synthetic `demo` that anyone can
/// play with, and the owner's `real` books. Each has a folder of its own inside the app's
/// sandbox, so switching to one never opens, writes or even lists the other's database.
/// Neither is ever placed in iCloud or in the folder the owner chose for copies.
enum DataProfile: String, CaseIterable, Sendable {
  case demo
  case real

  /// Where the sets live: `Application Support/OhMyMoney` of the sandbox.
  static var defaultRoot: URL {
    let base =
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSTemporaryDirectory())
    return base.appendingPathComponent("OhMyMoney", isDirectory: true)
  }

  /// The folder of the set under `root`. The demo sits in `Sets/demo`, like every synthetic set
  /// of the Mac app (`DataSetGeneration` makes only folders under `Sets`).
  func directory(in root: URL) -> URL {
    switch self {
    case .demo:
      root.appendingPathComponent("Sets", isDirectory: true).appendingPathComponent(
        "demo", isDirectory: true)
    case .real: root.appendingPathComponent("Real", isDirectory: true)
    }
  }

  /// What `AppPaths` is told before an environment is made. The demo is the `demo` data set,
  /// which is how the whole app already knows a synthetic book (no lock of the Mac kind, no
  /// mirrored copies, no starter tree); the real books are no data set at all.
  func placement(in root: URL) -> AppPaths.Placement {
    AppPaths.Placement(dataSet: self == .demo ? .demo : nil, directory: directory(in: root))
  }
}

/// Which set the owner works in, remembered between launches. The demo until the owner turns
/// the real books on.
struct ProfileStore {
  static let key = "ios.dataProfile"
  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  var current: DataProfile {
    get { defaults.string(forKey: Self.key).flatMap(DataProfile.init(rawValue:)) ?? .demo }
    nonmutating set { defaults.set(newValue.rawValue, forKey: Self.key) }
  }
}
