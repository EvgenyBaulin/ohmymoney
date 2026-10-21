import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CoreInsights
@testable import CoreModel

/// A refund taken back from a purchase carries the purchase's category because the app copied
/// it there, not because the owner filed it: the model learns the purchase once.
@Suite("What refunds teach the model")
struct RefundTrainingTests {
  private let clothes = UUID()
  private let shop = UUID()

  private func purchase(_ id: UUID, part: UUID) -> TransactionEntry {
    TransactionEntry(
      transaction: Transaction(
        id: id, kind: .expense, occurredAt: Date(timeIntervalSince1970: 1_780_000_000),
        amountE4: AmountE4(raw: 50_000_000), note: "jacket", placeId: shop),
      parts: [
        TransactionPart(
          id: part, transactionId: id, categoryId: clothes, categorySource: .manual,
          amountE4: AmountE4(raw: 50_000_000))
      ])
  }

  private func refund(_ id: UUID, of part: UUID?) -> TransactionEntry {
    TransactionEntry(
      transaction: Transaction(
        id: id, kind: .refund, occurredAt: Date(timeIntervalSince1970: 1_780_500_000),
        amountE4: AmountE4(raw: 20_000_000), note: "jacket", placeId: shop),
      parts: [
        // What `RefundRules` writes: the purchase part's category and its source, copied.
        TransactionPart(
          transactionId: id, categoryId: clothes, categorySource: .manual,
          amountE4: AmountE4(raw: 20_000_000), refundOfPartId: part)
      ])
  }

  private var categories: [CoreKit.Category] {
    [CoreKit.Category(id: clothes, kind: .expense, name: "Clothes")]
  }

  /// One jacket bought and partly taken back is one example, the purchase's.
  @Test func aRefundTakenBackFromAPurchaseIsNoSecondExample() {
    let bought = UUID()
    let part = UUID()
    let dataset = Dataset(
      entries: [purchase(bought, part: part), refund(UUID(), of: part)], categories: categories)

    let examples = LedgerTraining.examples(of: dataset, calendar: .utc)
    #expect(examples.map(\.partId) == [part])
  }

  /// A refund of no purchase is filed by the owner: its category is theirs, and it teaches.
  @Test func aRefundOfNoPurchaseStillTeaches() {
    let back = UUID()
    let dataset = Dataset(entries: [refund(back, of: nil)], categories: categories)

    let examples = LedgerTraining.examples(of: dataset, calendar: .utc)
    #expect(examples.count == 1)
  }

  /// A refund whose purchase was deleted stands alone again and is read like any refund
  /// of no purchase — the ledger does the same (`RefundIndex` links only live purchases).
  @Test func aRefundOfADeletedPurchaseStandsAlone() {
    let bought = UUID()
    let part = UUID()
    var gone = purchase(bought, part: part)
    gone.transaction.deletedAt = Date(timeIntervalSince1970: 1_780_600_000)
    let dataset = Dataset(entries: [gone, refund(UUID(), of: part)], categories: categories)

    let examples = LedgerTraining.examples(of: dataset, calendar: .utc)
    #expect(examples.count == 1)
    #expect(examples.first?.partId != part)
  }
}
