import CoreKit
import Foundation

/// The name of a live goal is taken once: the entry line, the pickers and the analytics tell
/// goals apart by name, and two live ones of one name are told apart by nothing.
extension GoalRules {
  /// The live goal that already has the name `name`, the names compared as the entry line
  /// compares them (case, «ё»/«е», the spaces around). `excluding` is the goal being saved,
  /// renamed or brought back from the archive: it is no namesake of itself. Goals in the
  /// archive do not count here — they have an answer of their own (`archivedNamesake`). Nil for
  /// a name that says nothing.
  public static func liveNamesake(
    of name: String, excluding id: UUID? = nil, among goals: [Goal]
  ) -> Goal? {
    let key = NameKey.fold(name)
    guard !key.isEmpty else { return nil }
    return goals.first { !$0.archived && $0.id != id && NameKey.fold($0.name) == key }
  }
}
