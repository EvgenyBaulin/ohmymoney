import CoreKit
import Foundation
import Testing

@testable import CoreCSV

struct StatementReviewTests {
  @Test func closingBalanceMismatchOrMissingAnchorWaitsForADecision() throws {
    let account = UUID()
    let closing = AmountE4(whole: 1_000)
    #expect(
      StatementReview.make(
        importID: "equal", accountID: account, fileName: "a.pdf",
        checks: [], closingBalance: closing, ledgerBalance: closing, currency: .rub) == nil)
    let mismatch = try #require(
      StatementReview.make(
        importID: "different", accountID: account,
        fileName: "a.pdf", checks: [], closingBalance: closing, ledgerBalance: AmountE4(whole: 900),
        currency: .rub))
    #expect(mismatch.closingBalance == closing)
    #expect(mismatch.ledgerBalance == AmountE4(whole: 900))
    #expect(StatementReview.decode(try StatementReview.encode([mismatch])) == [mismatch])
    #expect(
      StatementReview.make(
        importID: "unknown", accountID: account, fileName: "a.pdf",
        checks: [], closingBalance: closing, currency: .rub) != nil)
  }
  @Test func onlyFailedTotalsNeedReviewAndSurviveReopening() throws {
    let failed = StatementCheck(
      kind: .footerTotals, passed: false, blocking: true,
      missingIncome: AmountE4(whole: 20), missingExpense: AmountE4(whole: 10))
    let review = try #require(
      StatementReview.make(
        importID: UUID().uuidString,
        accountID: UUID(), fileName: "synthetic.pdf", checks: [failed]))
    let encoded = try StatementReview.encode([review])
    #expect(StatementReview.decode(encoded) == [review])
    #expect(review.checks[0].missingIncome == AmountE4(whole: 20))
    #expect(
      StatementReview.make(
        importID: "ok", accountID: UUID(), fileName: "ok.pdf",
        checks: [StatementCheck(kind: .footerTotals, passed: true, blocking: true)]) == nil)
  }
}
