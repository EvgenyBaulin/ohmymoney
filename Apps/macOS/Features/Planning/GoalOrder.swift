import AppCore
import Foundation

/// The order the goals of the Planning section stand in. Until the owner drags a goal, the
/// nearest by its day comes first, as always; the first drag numbers every goal (`sort` from 1)
/// and from then on the owner's order is the order.
enum GoalOrder {
  static let payloadPrefix = "ohmymoney.planning.goal:"

  static func hasOwnerOrder(_ goals: [Goal]) -> Bool { goals.contains { $0.sort > 0 } }

  /// The goals as they stand on screen: the owner's order (the one the statuses come in), or
  /// the nearest first.
  static func shown(_ goals: [GoalStatus]) -> [GoalStatus] {
    if hasOwnerOrder(goals.map(\.goal)) { return goals }
    return PlanningShortList.nearestFirst(goals, date: { $0.goal.targetDate })
  }

  static func payload(of id: UUID) -> String { payloadPrefix + id.uuidString }

  static func goal(in payload: String) -> UUID? {
    payload.hasPrefix(payloadPrefix)
      ? UUID(uuidString: String(payload.dropFirst(payloadPrefix.count))) : nil
  }

  /// The ids with `moved` taken out and put in the place of `target`: before it when it came
  /// from below, after it when it came from above — the place the drop lands on.
  static func ids(moving moved: UUID, onto target: UUID, in order: [UUID]) -> [UUID]? {
    guard moved != target, let from = order.firstIndex(of: moved),
      let to = order.firstIndex(of: target)
    else { return nil }
    var result = order
    result.remove(at: from)
    result.insert(moved, at: to)
    return result
  }
}
