import AppCore
import Foundation

/// Which blocks of «Из чего складывается» the owner opened. Every block starts folded into its
/// one row — the name, the share and the total —; a click lists what it is made of. What is open
/// is a habit of this Mac: kept in `UserDefaults` (`capital.expanded`, a list of the ids of the
/// blocks), never in the archive.
struct CapitalExpansion: Hashable, Sendable {
  static let storageKey = "capital.expanded"

  /// The ids of the open blocks (`CapitalViewModel.Group.id`).
  private(set) var open: Set<String>

  init(open: Set<String> = []) {
    self.open = Set(open.filter(Self.isGroupId))
  }

  func isOpen(_ id: String) -> Bool { open.contains(id) }

  /// Opens a folded block, folds an open one.
  mutating func toggle(_ id: String) {
    guard Self.isGroupId(id) else { return }
    if open.remove(id) == nil { open.insert(id) }
  }

  /// What `defaults` keeps; an id that names no block a column could have is dropped.
  static func stored(in defaults: UserDefaults = .standard) -> CapitalExpansion {
    CapitalExpansion(open: Set(defaults.stringArray(forKey: storageKey) ?? []))
  }

  func store(in defaults: UserDefaults = .standard) {
    defaults.set(open.sorted(), forKey: Self.storageKey)
  }

  /// Whether `id` is shaped like the id of a block: a kind of the core alone; an out-of-summary
  /// block with the UUID of its group; a block of property with its kind.
  static func isGroupId(_ id: String) -> Bool {
    let parts = id.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
    guard let kind = parts.first.flatMap({ CapitalLine.Group(rawValue: String($0)) }) else {
      return false
    }
    guard parts.count == 2 else { return true }
    let rest = String(parts[1])
    switch kind {
    case .outOfSummary: return UUID(uuidString: rest) != nil
    case .assets: return AssetKind(rawValue: rest) != nil
    default: return false
    }
  }
}
