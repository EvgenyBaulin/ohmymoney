import CoreAccounting
import CoreKit
import Foundation

/// A refund of a purchase that the owner is waiting for (a marketplace has not paid it back yet):
/// the operation exists and stays out of the spending and out of the balances until it is credited
/// (`Transaction.refundWaitingUntil`).
public struct WaitingRefund: Hashable, Sendable, Identifiable {
  public var transactionId: UUID
  /// The day the refund was recorded.
  public var recordedOn: DateOnly
  /// The day the money is expected on the account.
  public var expectedBy: DateOnly
  public var amountE4: AmountE4
  public var amountRubE4: AmountE4
  public var currency: CurrencyCode
  public var note: String?
  /// What it will take off each category once credited (rubles).
  public var byCategory: [UUID: AmountE4]
  public var uncategorizedRubE4: AmountE4
  public var id: UUID { transactionId }

  public init(
    transactionId: UUID, recordedOn: DateOnly, expectedBy: DateOnly, amountE4: AmountE4,
    amountRubE4: AmountE4, currency: CurrencyCode, note: String?, byCategory: [UUID: AmountE4],
    uncategorizedRubE4: AmountE4
  ) {
    self.transactionId = transactionId
    self.recordedOn = recordedOn
    self.expectedBy = expectedBy
    self.amountE4 = amountE4
    self.amountRubE4 = amountRubE4
    self.currency = currency
    self.note = note
    self.byCategory = byCategory
    self.uncategorizedRubE4 = uncategorizedRubE4
  }

  /// Days from `today` to the expected day: negative once it is late.
  public func daysLeft(today: DateOnly) -> Int { today.days(to: expectedBy) }
  public func isLate(today: DateOnly) -> Bool { today > expectedBy }
  /// Days since the refund was recorded.
  public func daysWaiting(today: DateOnly) -> Int { max(0, recordedOn.days(to: today)) }
}

/// The list «Ждут зачисления».
public struct WaitingRefunds: Hashable, Sendable {
  /// The soonest expected day first, then the larger amount.
  public var items: [WaitingRefund]

  public init(items: [WaitingRefund]) { self.items = items }

  public var totalRubE4: AmountE4 { AmountE4.sum(items.map(\.amountRubE4)) }

  /// What the waiting refunds will take off each category when credited.
  public var impactByCategory: [UUID: AmountE4] {
    var result: [UUID: AmountE4] = [:]
    for item in items { for (id, amount) in item.byCategory { result[id, default: .zero] += amount } }
    return result
  }

  /// Whether the operation is a refund still waited for.
  public static func isWaiting(_ transaction: Transaction) -> Bool {
    transaction.kind == .refund && transaction.refundWaitingUntil != nil && !transaction.isDeleted
  }

  public static func list(entries: [TransactionEntry], calendar: CalendarContext) -> WaitingRefunds {
    var items: [WaitingRefund] = []
    for entry in entries where isWaiting(entry.transaction) {
      let transaction = entry.transaction
      guard let until = transaction.refundWaitingUntil else { continue }
      var byCategory: [UUID: AmountE4] = [:]
      var none = AmountE4.zero
      for part in entry.parts {
        if let category = part.categoryId {
          byCategory[category, default: .zero] += part.amountRubE4
        } else {
          none += part.amountRubE4
        }
      }
      items.append(
        WaitingRefund(
          transactionId: transaction.id,
          recordedOn: calendar.day(of: transaction.occurredAt, recordedIn: transaction.timeZoneId),
          expectedBy: until, amountE4: transaction.amountE4, amountRubE4: transaction.amountRubE4,
          currency: transaction.currency, note: transaction.note, byCategory: byCategory,
          uncategorizedRubE4: none))
    }
    items.sort { left, right in
      if left.expectedBy != right.expectedBy { return left.expectedBy < right.expectedBy }
      if left.amountRubE4 != right.amountRubE4 { return left.amountRubE4 > right.amountRubE4 }
      return left.transactionId.uuidString < right.transactionId.uuidString
    }
    return WaitingRefunds(items: items)
  }

  /// The edit that says the refund was credited: the wait ends and the operation counts as an
  /// ordinary refund from now on.
  public static func credited(_ transaction: Transaction) -> Transaction {
    var copy = transaction
    copy.refundWaitingUntil = nil
    return copy
  }

  /// The edit that moves the expected day.
  public static func expecting(_ transaction: Transaction, by day: DateOnly) -> Transaction {
    var copy = transaction
    copy.refundWaitingUntil = day
    return copy
  }
}
