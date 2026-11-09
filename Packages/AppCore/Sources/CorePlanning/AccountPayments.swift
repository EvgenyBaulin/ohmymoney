import CoreAnalytics
import CoreKit
import Foundation

/// The block «Платежи и подписки» of an account's screen.
public enum AccountPayments {
  /// The active scheduled payments paid from the account: those that name it — a card they name
  /// is always a card of it —, and those that name no account: on the account their latest
  /// charge came off (`chargedFrom`), else on the main account. A payment saved with no
  /// account — the form shows the main account until another is picked and writes none — whose
  /// charges come off a dollar account is paid from that account, so its screen lists it. By
  /// the next due date nothing has paid yet, then by name, then by id.
  public static func on(
    _ accountId: UUID, statuses: [ScheduledStatus], mainAccountId: UUID?,
    chargedFrom: [UUID: UUID] = [:]
  ) -> [ScheduledStatus] {
    statuses.filter { status in
      guard status.payment.active else { return false }
      if let own = status.payment.paymentMethodId { return own == accountId }
      if let charged = chargedFrom[status.payment.id] { return charged == accountId }
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

  /// The account the latest charge of each payment came off, by payment id: of the operation
  /// «Провести» wrote (`lastCharge`) and those that pay a due date by matching
  /// (`matchedDues`), the one of the latest day — the account it names, else the account of
  /// the card it names. An operation that names neither tells nothing, and the payment is not
  /// in the result.
  public static func chargedFrom(statuses: [ScheduledStatus], ledger: Ledger) -> [UUID: UUID] {
    let cardAccounts = Dictionary(
      ledger.dataset.cards.map { ($0.id, $0.accountId) }, uniquingKeysWith: { first, _ in first })
    var result: [UUID: UUID] = [:]
    for status in statuses {
      var latest: (day: Date, account: UUID)?
      let operations =
        [status.lastCharge?.transactionId].compactMap { $0 } + Array(status.matchedDues.values)
      for id in operations {
        guard let transaction = ledger.entry(id)?.transaction, transaction.deletedAt == nil,
          let account = transaction.paymentMethodId
            ?? transaction.cardId.flatMap({ cardAccounts[$0] })
        else { continue }
        if latest.map({ transaction.occurredAt > $0.day }) ?? true {
          latest = (transaction.occurredAt, account)
        }
      }
      if let latest { result[status.payment.id] = latest.account }
    }
    return result
  }
}
