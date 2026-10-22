import CoreAccounting
import CoreKit
import Foundation
import Testing

@testable import CoreAnalytics

@Suite("Spending by tag")
struct TagReportTests {
  private let day = Date(timeIntervalSince1970: 1_760_000_000)

  private func entry(
    _ rub: Int64, kind: TransactionKind = .expense, reimbursable: Bool = false
  ) -> TransactionEntry {
    let transaction = Transaction(
      kind: kind, occurredAt: day, amountE4: AmountE4(whole: rub))
    let part = TransactionPart(
      transactionId: transaction.id, amountE4: AmountE4(whole: rub), reimbursable: reimbursable,
      reimbursementStatus: reimbursable ? .expected : nil)
    return TransactionEntry(transaction: transaction, parts: [part])
  }

  @Test func anOperationWithTwoTagsIsInEachAndTheRowsSayTheyOverlap() {
    let trip = UUID(), turkey = UUID()
    let dinner = entry(3_500)
    let taxi = entry(500)
    let links = [
      PartTag(partId: dinner.parts[0].id, tagId: trip),
      PartTag(partId: dinner.parts[0].id, tagId: turkey),
      PartTag(partId: taxi.parts[0].id, tagId: trip),
    ]
    let report = TagReport.compute(entries: [dinner, taxi], links: links)
    #expect(report.rows.map(\.tagId) == [trip, turkey])
    #expect(report.rows.map(\.myRubE4) == [AmountE4(whole: 4_000), AmountE4(whole: 3_500)])
    #expect(report.distinctRubE4 == AmountE4(whole: 4_000))
    #expect(report.sumOfRowsRubE4 == AmountE4(whole: 7_500))
    #expect(report.rowsOverlap)
    #expect(report.rows[0].operations == 2 && report.rows[1].operations == 1)
  }

  @Test func withOneTagPerPartTheRowsAddUpToTheTotal() {
    let a = UUID(), b = UUID()
    let one = entry(100), two = entry(250)
    let links = [
      PartTag(partId: one.parts[0].id, tagId: a), PartTag(partId: two.parts[0].id, tagId: b),
    ]
    let report = TagReport.compute(entries: [one, two], links: links)
    #expect(!report.rowsOverlap)
    #expect(report.sumOfRowsRubE4 == report.distinctRubE4)
  }

  @Test func onlyMySpendingCountsAndRefundsTakeOff() {
    let tag = UUID()
    let mine = entry(1_000)
    let forOther = entry(700, reimbursable: true)
    var refund = entry(300, kind: .refund)
    refund.parts[0].refundOfPartId = mine.parts[0].id
    let income = entry(9_000, kind: .income)
    let links = [mine, forOther, refund, income].map { PartTag(partId: $0.parts[0].id, tagId: tag) }
    let report = TagReport.compute(entries: [mine, forOther, refund, income], links: links)
    #expect(report.rows.first?.myRubE4 == AmountE4(whole: 700))
  }

  @Test func deletedOperationsAndUntaggedPartsAreLeftOut() {
    let tag = UUID()
    var gone = entry(500)
    gone.transaction.deletedAt = day
    let untagged = entry(800)
    let report = TagReport.compute(
      entries: [gone, untagged], links: [PartTag(partId: gone.parts[0].id, tagId: tag)])
    #expect(report.rows.isEmpty && report.distinctRubE4.isZero)
  }

  @Test func theFilterTakesOperationsByTheirPartsTags() {
    let a = UUID(), b = UUID()
    let both = entry(1), onlyA = entry(2), none = entry(3)
    let links = [
      PartTag(partId: both.parts[0].id, tagId: a), PartTag(partId: both.parts[0].id, tagId: b),
      PartTag(partId: onlyA.parts[0].id, tagId: a),
    ]
    let all = [both, onlyA, none]
    #expect(TagFilter.entries(all, links: links, matching: [a]).map(\.id) == [both.id, onlyA.id])
    #expect(TagFilter.entries(all, links: links, matching: [a, b], mode: .any).count == 2)
    #expect(
      TagFilter.entries(all, links: links, matching: [a, b], mode: .all).map(\.id) == [both.id])
    #expect(
      TagFilter.entries(all, links: links, matching: []).count == 3, "no tag chosen, no filter")
  }

  @Test func aSplitTagsOnlyThePartThatCarriesIt() {
    let tag = UUID()
    let transaction = Transaction(kind: .expense, occurredAt: day, amountE4: AmountE4(whole: 6_000))
    let food = TransactionPart(transactionId: transaction.id, amountE4: AmountE4(whole: 4_000))
    let gift = TransactionPart(transactionId: transaction.id, amountE4: AmountE4(whole: 2_000))
    let receipt = TransactionEntry(transaction: transaction, parts: [food, gift])
    let report = TagReport.compute(
      entries: [receipt], links: [PartTag(partId: gift.id, tagId: tag)])
    #expect(report.rows.first?.myRubE4 == AmountE4(whole: 2_000))
  }
}
