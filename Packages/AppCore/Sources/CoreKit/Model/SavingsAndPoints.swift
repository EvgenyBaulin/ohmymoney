import Foundation

/// Points the bank will burn: the day and how many, in the currency of the account that holds
/// them (`PaymentMethod.pointsBurn`). Typed from the bank's own app; the app does not guess when
/// points burn.
public struct PointsBurn: Hashable, Sendable, Codable {
  public var on: DateOnly
  /// How many points burn that day; `nil` — the owner did not say, which reads as all of them.
  public var amountE4: AmountE4?

  public init(on: DateOnly, amountE4: AmountE4? = nil) {
    self.on = on
    self.amountE4 = amountE4
  }
}

/// Why a debt pauses its payments.
public enum DebtPauseKind: String, Hashable, Sendable, Codable, CaseIterable {
  /// A credit holiday the bank gave for some months.
  case holiday
  /// The loan was restructured: the payments wait while the new terms start.
  case restructuring
}

/// A stretch of days with no due on a debt, and why. A due that falls from `from` through `to`
/// is not owed; every later due moves on by as many months as were skipped, so the term is
/// carried over (`DebtDueState.due(_:)`).
public struct DebtPause: Hashable, Sendable, Codable {
  public var from: DateOnly
  public var to: DateOnly
  public var kind: DebtPauseKind

  public init(from: DateOnly, to: DateOnly, kind: DebtPauseKind = .holiday) {
    self.from = from
    self.to = to
    self.kind = kind
  }

  /// Whether `day` falls inside the pause, both ends included.
  public func contains(_ day: DateOnly) -> Bool { day >= from && day <= to }

  /// A pause must end on or after the day it starts.
  public var isValid: Bool { to >= from }
}
