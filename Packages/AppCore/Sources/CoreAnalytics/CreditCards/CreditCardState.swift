import CoreAccounting
import CoreKit
import Foundation

/// Where a credit card stands: a plain card, a card with its grace period running, or a debt.
public enum CreditCardPhase: String, Hashable, Sendable {
  /// Nothing is owed.
  case clear
  /// Something is owed, and paying it by its day costs no interest: the card is a card with a
  /// reminder «внести до».
  case grace
  /// A statement of the card was not paid in time: all that the card owes is a debt.
  case debt
}

/// A credit card on a day, in the three things its screens, «Долги» and «Стоит посмотреть» say.
/// Worked out from the card alone: the money is still counted once, on the account.
public struct CreditCardState: Hashable, Sendable {
  public var phase: CreditCardPhase
  /// All the card owes, in the currency of the account, never below zero.
  public var debtE4: AmountE4
  /// The due day of the latest statement that was missed; `nil` unless the phase is `debt`.
  public var missedDue: DateOnly?
  /// The interest the card will likely charge: an estimate, grey and never money.
  public var estimate: CreditInterestEstimate?
  /// How far the card is over its limit today: zero while within it or without a limit.
  public var overLimitE4: AmountE4

  public init(
    phase: CreditCardPhase = .clear, debtE4: AmountE4 = .zero, missedDue: DateOnly? = nil,
    estimate: CreditInterestEstimate? = nil, overLimitE4: AmountE4 = .zero
  ) {
    self.phase = phase
    self.debtE4 = debtE4
    self.missedDue = missedDue
    self.estimate = estimate
    self.overLimitE4 = overLimitE4
  }

  /// Whether the card is a debt of «Долги» now.
  public var isDebt: Bool { phase == .debt }
}

public enum CreditCardStates {
  /// The state of a card from its day (`CreditStatements.now`) and its statements: a debt once
  /// the grace period is lost with something still owed, a card in grace while it holds, clear
  /// without debt. A card without a limit is never over it.
  public static func state(now: CreditCardNow, statements: [CreditStatement]) -> CreditCardState {
    var state = CreditCardState(estimate: now.estimate, overLimitE4: overLimit(now))
    state.debtE4 = now.debtE4
    guard now.debtE4.raw > 0 else { return state }
    if now.graceKept {
      state.phase = .grace
    } else {
      state.phase = .debt
      state.missedDue = statements.last { $0.state == .missed }?.due
    }
    return state
  }

  /// How far the card is over its limit today, zero without a limit.
  public static func overLimit(_ now: CreditCardNow) -> AmountE4 {
    guard now.limitE4.raw > 0, now.availableE4.raw < 0 else { return .zero }
    return -now.availableE4
  }

  /// How far over the limit the card would be after `spendE4` more is charged to it: zero when
  /// it stays within the limit or the card has none.
  public static func overshoot(now: CreditCardNow, spendE4: AmountE4) -> AmountE4 {
    guard now.limitE4.raw > 0, spendE4.raw > 0 else { return .zero }
    let over = spendE4 - now.availableE4
    return over.raw > 0 ? over : .zero
  }
}
