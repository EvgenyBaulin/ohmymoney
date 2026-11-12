import CoreKit
import Foundation

/// What is wrong with a pause of the payments of a debt (a credit holiday, a restructuring).
public enum DebtPauseIssue: Hashable, Sendable {
  /// The pause ends before the day it starts.
  case endsBeforeStart
  /// Only a debt I owe has payments to pause.
  case notMine
  /// The debt has no dues: there is nothing to put off.
  case noDues
}

/// The pause of a debt's payments: the dues that fall inside it are not owed, and every later due
/// moves on by the months skipped (`DebtDueState.due(_:)`), so the term is carried over.
public enum DebtPauseRules {
  /// What keeps `pause` from being a pause of `debt`. Only said, never refused: the app records
  /// what the bank agreed to (0560).
  public static func issues(_ pause: DebtPause, for debt: Debt) -> [DebtPauseIssue] {
    var found: [DebtPauseIssue] = []
    if !pause.isValid { found.append(.endsBeforeStart) }
    if debt.direction != .iOwe { found.append(.notMine) }
    if !debt.hasDues { found.append(.noDues) }
    return found
  }

  /// The debt with the pause set, or taken away with `nil`. A pause that does not end on or after
  /// its start is not set.
  public static func applying(_ pause: DebtPause?, to debt: Debt) -> Debt {
    var result = debt
    result.pause = pause.flatMap { $0.isValid ? $0 : nil }
    return result
  }

  /// How the term moves.
  public struct TermShift: Hashable, Sendable {
    /// The last due without the pause, and with it.
    public var lastDueBefore: DateOnly
    public var lastDueAfter: DateOnly
    /// How many dues the pause skips.
    public var skippedDues: Int
  }

  /// The last due of the debt with and without its pause, and how many dues the pause skips;
  /// `nil` for a debt without a pause, or whose end is not known (no balance, or dues with no
  /// sums: nothing says when it is paid off).
  public static func termShift(of state: DebtDueState) -> TermShift? {
    guard state.pause != nil, state.balanceE4 != nil, !state.instalments.isEmpty else {
      return nil
    }
    let far = DateOnly(year: 2200, month: 1, day: 1)
    var plain = state
    plain.pause = nil
    let before = plain.unpaid(through: far)
    let after = state.unpaid(through: far)
    guard let lastBefore = before.last, let lastAfter = after.last else { return nil }
    return TermShift(
      lastDueBefore: lastBefore, lastDueAfter: lastAfter,
      skippedDues: before.filter { day in state.pause?.contains(day) == true }.count)
  }
}
