import CoreAnalytics
import CoreInsights
import CoreKit
import Foundation
import Testing

@Suite("Warranty after a purchase refund")
struct WarrantyRefundTests {
  private let today = DateOnly(year: 2026, month: 11, day: 17)

  private func entries(
    refund: Int64, waiting: Bool = false, deleted: Bool = false
  )
    -> [TransactionEntry]
  {
    let purchase = Transaction(
      kind: .expense, occurredAt: CalendarContext.utc.noon(of: today),
      amountE4: AmountE4(whole: 100), warrantyUntil: today, returnUntil: today)
    let part = TransactionPart(transactionId: purchase.id, amountE4: AmountE4(whole: 100))
    var returned = Transaction(
      kind: .refund, occurredAt: purchase.occurredAt,
      amountE4: AmountE4(whole: refund))
    if waiting { returned.refundWaitingUntil = today }
    if deleted { returned.deletedAt = purchase.occurredAt }
    let refundPart = TransactionPart(
      transactionId: returned.id,
      amountE4: AmountE4(whole: refund), refundOfPartId: part.id)
    return [
      .init(transaction: purchase, parts: [part]),
      .init(transaction: returned, parts: [refundPart]),
    ]
  }

  @Test func aFullRefundMovesThePurchaseToReturnedAndSilencesBothTerms() throws {
    let items = WarrantyList.items(from: entries(refund: 100))
    #expect(try #require(items.first).isReturned)
    #expect(WarrantyReminders.list(items, today: today).isEmpty)
    #expect(items.first?.nextEnd(today: today) == nil)
  }

  @Test func aPartialRefundSilencesOnlyTheReturnTerm() throws {
    let items = WarrantyList.items(from: entries(refund: 10))
    let item = try #require(items.first)
    #expect(!item.isReturned)
    #expect(item.returnUntil == nil)
    #expect(item.warrantyUntil == today)
    #expect(WarrantyReminders.list(items, today: today).count == 1)
  }

  @Test func aWaitingOrDeletedRefundDoesNotCloseTheTerms() throws {
    for entries in [entries(refund: 100, waiting: true), entries(refund: 100, deleted: true)] {
      let items = WarrantyList.items(from: entries)
      #expect(!(try #require(items.first)).isReturned)
      #expect(WarrantyReminders.list(items, today: today).count == 2)
    }
  }
}
