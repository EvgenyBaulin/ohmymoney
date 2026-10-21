import AppCore
import Foundation

/// A line of a day in a list of what happened: an operation, or a transfer between the owner's
/// own accounts.
enum DayItem: Identifiable, Sendable {
  case operation(TransactionEntry)
  case transfer(Transfer)

  var id: String {
    switch self {
    case .operation(let entry): "op.\(entry.id.uuidString)"
    case .transfer(let transfer): "tr.\(transfer.id.uuidString)"
    }
  }

  var occurredAt: Date {
    switch self {
    case .operation(let entry): entry.transaction.occurredAt
    case .transfer(let transfer): transfer.occurredAt
    }
  }

  var createdAt: Date {
    switch self {
    case .operation(let entry): entry.transaction.createdAt
    case .transfer(let transfer): transfer.createdAt
    }
  }

  /// The operation, when the line is one.
  var entry: TransactionEntry? {
    if case .operation(let entry) = self { return entry }
    return nil
  }

  /// The transfer, when the line is one.
  var movedBetweenAccounts: Transfer? {
    if case .transfer(let transfer) = self { return transfer }
    return nil
  }

  /// The id a list selects the line by: the operation's or the transfer's own.
  var selectableId: UUID {
    switch self {
    case .operation(let entry): entry.id
    case .transfer(let transfer): transfer.id
    }
  }

  /// Newest first: by the moment it happened, then the later written first, then by id, so
  /// two lines of one moment keep their places on every read.
  static func newestFirst(_ left: DayItem, _ right: DayItem) -> Bool {
    if left.occurredAt != right.occurredAt { return left.occurredAt > right.occurredAt }
    if left.createdAt != right.createdAt { return left.createdAt > right.createdAt }
    return left.id < right.id
  }
}
