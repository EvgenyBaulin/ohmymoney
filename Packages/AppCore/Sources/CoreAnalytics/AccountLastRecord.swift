import CoreAccounting
import CoreKit
import Foundation

/// The moment the owner last wrote an operation down on each account: the latest `createdAt`
/// of its live operations — the moment of writing, as «Последняя запись» of Overview reads it
/// (`OverviewSummary.lastRecordedAt`): a purchase of last week typed now is written now, and an
/// edit or ⌘Z moves nothing. The lines the app writes to keep the books right do not count, and
/// neither do transfers: a transfer, and the fee written with it, is no operation of an account.
/// An operation that names no account is on the main one, as its balance counts it.
public enum AccountLastRecord {
  public static func byAccount(_ dataset: Dataset) -> [UUID: Date] {
    let mainId = dataset.paymentMethods.first { $0.isDefault && !$0.archived }?.id
    var latest: [UUID: Date] = [:]
    for entry in dataset.entries where !entry.transaction.isDeleted {
      let link = OperationLink(externalId: entry.transaction.externalId)
      if link?.isBookkeeping == true { continue }
      if case .transferFee = link { continue }
      guard let account = entry.transaction.paymentMethodId ?? mainId else { continue }
      let moment = entry.transaction.createdAt
      if latest[account].map({ moment > $0 }) ?? true { latest[account] = moment }
    }
    return latest
  }

  /// The latest of `accounts` — a group's, or every account of the summary.
  public static func latest(of accounts: some Sequence<UUID>, in moments: [UUID: Date]) -> Date? {
    accounts.compactMap { moments[$0] }.max()
  }
}
