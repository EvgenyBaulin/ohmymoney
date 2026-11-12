import Foundation

/// A payment copied from an instalment service, including any commission.
public struct SplitPayment: Hashable, Sendable, Codable, Identifiable {
  public var id: UUID
  public var day: DateOnly
  public var amountE4: AmountE4

  public init(id: UUID = UUID(), day: DateOnly, amountE4: AmountE4) {
    self.id = id
    self.day = day
    self.amountE4 = amountE4
  }
}

/// The bank's minimum and deadline for one statement, in the account's main currency
/// (`credit_statements`); one per account and statement.
public struct CreditStatementOverride: Hashable, Sendable, Codable, Identifiable {
  public var id: UUID
  public var accountId: UUID
  public var closesOn: DateOnly
  public var minimumE4: AmountE4
  public var due: DateOnly

  public init(
    id: UUID = UUID(), accountId: UUID, closesOn: DateOnly, minimumE4: AmountE4, due: DateOnly
  ) {
    self.id = id
    self.accountId = accountId
    self.closesOn = closesOn
    self.minimumE4 = minimumE4
    self.due = due
  }
}
