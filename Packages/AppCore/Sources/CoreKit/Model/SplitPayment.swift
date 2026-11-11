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

/// Explicit due dates of a split; amounts live in the debt's instalment rows.
public struct SplitDueDates: Hashable, Sendable, Codable {
  public var debtId: UUID
  public var days: [DateOnly]

  public init(debtId: UUID, days: [DateOnly]) {
    self.debtId = debtId
    self.days = days
  }
}

/// The bank's minimum and deadline for one statement, in the account's main currency.
public struct CreditStatementOverride: Hashable, Sendable, Codable {
  public var accountId: UUID
  public var closesOn: DateOnly
  public var minimumE4: AmountE4
  public var due: DateOnly

  public init(accountId: UUID, closesOn: DateOnly, minimumE4: AmountE4, due: DateOnly) {
    self.accountId = accountId
    self.closesOn = closesOn
    self.minimumE4 = minimumE4
    self.due = due
  }
}
