import Foundation

/// «Вернёт ли человек деньги?» is asked every time somebody else is chosen, and the answer given
/// for a person is the one offered next time: a friend who always pays back is «Вернёт» at once,
/// a gift to a parent is «Нет» at once. Kept on this Mac, by the id of the person — the answer
/// of a question, not a record of money — and never as text of a name.
struct PaysBackMemory {
  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  static let keyPrefix = "entry.paysBack."

  /// What was answered for `person` last time; `nil` when nothing was.
  func answer(for person: UUID) -> Bool? {
    let key = Self.keyPrefix + person.uuidString.lowercased()
    return defaults.object(forKey: key) == nil ? nil : defaults.bool(forKey: key)
  }

  func remember(_ paysBack: Bool, for person: UUID) {
    defaults.set(paysBack, forKey: Self.keyPrefix + person.uuidString.lowercased())
  }
}
