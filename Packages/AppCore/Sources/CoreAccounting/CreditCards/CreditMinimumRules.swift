import CoreKit
import Foundation

/// Manual minima belong to a particular bank statement, never to every month of a card.
public enum CreditMinimumRules {
  public enum Issue: Error, Equatable { case wrongStatement, negativeMinimum, invalidDeadline }

  /// The rows a save of `value` writes and deletes. A statement already typed is written over
  /// under its own id, so the pair (account, statement) stays one row; `nil` takes the typed
  /// minimum of that statement away.
  public struct Change: Equatable, Sendable {
    public var upsert: CreditStatementOverride?
    public var deleteId: UUID?
  }

  public static func saving(
    _ value: CreditStatementOverride?, accountId: UUID, closesOn: DateOnly,
    among existing: [CreditStatementOverride]
  ) throws -> Change {
    let current = existing.first { $0.accountId == accountId && $0.closesOn == closesOn }
    guard var value else { return Change(upsert: nil, deleteId: current?.id) }
    guard value.accountId == accountId, value.closesOn == closesOn else {
      throw Issue.wrongStatement
    }
    guard !value.minimumE4.isNegative else { throw Issue.negativeMinimum }
    guard value.due > closesOn else { throw Issue.invalidDeadline }
    if let current { value.id = current.id }
    return Change(upsert: value, deleteId: nil)
  }
}
