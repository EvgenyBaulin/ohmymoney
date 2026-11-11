import CoreKit
import Foundation

/// Manual minima belong to a particular bank statement, never to every month of a card.
public enum CreditMinimumRules {
  public enum Issue: Error, Equatable { case wrongStatement, negativeMinimum, invalidDeadline }

  public static func saving(
    _ value: CreditStatementOverride?, accountId: UUID, closesOn: DateOnly,
    in settings: DebtSettings
  ) throws -> DebtSettings {
    if let value {
      guard value.accountId == accountId, value.closesOn == closesOn else {
        throw Issue.wrongStatement
      }
      guard !value.minimumE4.isNegative else { throw Issue.negativeMinimum }
      guard value.due > closesOn else { throw Issue.invalidDeadline }
    }
    var result = settings
    result.statementOverrides.removeAll { $0.accountId == accountId && $0.closesOn == closesOn }
    if let value { result.statementOverrides.append(value) }
    return result
  }
}
