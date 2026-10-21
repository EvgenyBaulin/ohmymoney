import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation

/// «Остаток сентября — X»: what is left of the month just past, and where to put it.
public struct MonthRestOffer: Hashable, Sendable {
  /// The month the rest is of.
  public var month: MonthKey
  public var amountE4: AmountE4
  /// `nil`: ask the owner and remember.
  public var target: MonthRestTarget?

  public init(month: MonthKey, amountE4: AmountE4, target: MonthRestTarget?) {
    self.month = month
    self.amountE4 = amountE4
    self.target = target
  }
}

/// The rest of the month just past: «Остаток сентября — X».
public enum MonthRest {
  /// The last day of a month the offer is made on.
  public static let lastOfferDay = 10

  /// From the 1st through the 10th, until the owner allocated or declined it
  /// (`monthRestDone`): what can be spent now less the payments and the dues of debts the free
  /// sum holds back through its day, never below zero; nothing to offer at zero or with no
  /// count. Where to: the cushion while it has a goal not reached, else the target the owner
  /// chose last (a goal only while it is live), else `nil` — the owner is asked.
  public static func offer(
    today: DateOnly, free: FreeMoney, settings: AllocationSettings, cushion: CushionStatus,
    goals: [GoalStatus]
  ) -> MonthRestOffer? {
    guard today.day <= lastOfferDay else { return nil }
    let month = today.monthKey.previous
    guard settings.monthRestDone != month, let main = free.main else { return nil }
    let amount = main - free.plan.scheduled - free.plan.debts
    guard amount.raw > 0 else { return nil }
    var target: MonthRestTarget?
    if let goal = cushion.goal, !goal.reached, cushion.state != .noAccounts {
      target = .cushion
    } else {
      switch settings.monthRestTarget {
      case .cushion?: target = cushion.state == .noAccounts ? nil : .cushion
      case .goal(let id)?:
        target = goals.contains { $0.goal.id == id && !$0.goal.archived } ? .goal(id) : nil
      case nil: target = nil
      }
    }
    return MonthRestOffer(month: month, amountE4: amount, target: target)
  }
}
