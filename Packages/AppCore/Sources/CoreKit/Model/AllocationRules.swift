import Foundation

/// Where a rule of allocation sends its share of an income.
public enum AllocationTarget: Hashable, Sendable, Codable {
  /// A contribution to the goal.
  case goal(UUID)
  /// A transfer to the account.
  case account(UUID)
  /// A transfer to the safety cushion: to this account, or — `nil` — to the cushion account the
  /// sheet asks for.
  case cushion(UUID?)

  /// The word the schema keeps it as (`allocation_rules.target`).
  public var storedKind: String {
    switch self {
    case .goal: "goal"
    case .account: "account"
    case .cushion: "cushion"
    }
  }
}

/// How much a rule of allocation takes.
public enum AllocationAmount: Hashable, Sendable, Codable {
  /// A percent of the income after the tax of self-employment.
  case percent(Decimal)
  /// A fixed sum in its currency.
  case fixed(AmountE4, CurrencyCode)
}

/// How the owner usually allocates an income (`allocation_rules`): one rule per goal, one for
/// the cushion. Rules only suggest — nothing is written without the owner.
public struct AllocationRule: Identifiable, Hashable, Sendable, Codable {
  public var id: UUID
  public var target: AllocationTarget
  public var amount: AllocationAmount
  public var sort: Int
  public var active: Bool

  public init(
    id: UUID = UUID(), target: AllocationTarget, amount: AllocationAmount, sort: Int = 0,
    active: Bool = true
  ) {
    self.id = id
    self.target = target
    self.amount = amount
    self.sort = sort
    self.active = active
  }
}
