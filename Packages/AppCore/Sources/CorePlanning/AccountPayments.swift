import CoreKit
import Foundation

/// The block «Платежи и подписки» of an account's screen.
public enum AccountPayments {
  /// The active scheduled payments paid from the account: those that name it — a card they name
  /// is always a card of it —, and, on the main account, those that name no account. By the
  /// next due date nothing has paid yet, then by name, then by id.
  public static func on(
    _ accountId: UUID, statuses: [ScheduledStatus], mainAccountId: UUID?
  ) -> [ScheduledStatus] {
    statuses.filter { status in
      guard status.payment.active else { return false }
      if let own = status.payment.paymentMethodId { return own == accountId }
      return accountId == mainAccountId
    }
    .sorted { left, right in
      if left.nextUnpaid != right.nextUnpaid { return left.nextUnpaid < right.nextUnpaid }
      switch left.payment.name.compare(right.payment.name, options: [.caseInsensitive]) {
      case .orderedAscending: return true
      case .orderedDescending: return false
      case .orderedSame: return left.payment.id.uuidString < right.payment.id.uuidString
      }
    }
  }
}
