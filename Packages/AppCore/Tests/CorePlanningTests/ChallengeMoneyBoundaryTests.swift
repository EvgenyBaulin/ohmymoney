import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CorePlanning

@Suite("Challenges: money boundaries")
struct ChallengeMoneyBoundaryTests {
  typealias F = ChallengeFixture

  @Test func aLongChallengeWithAnAllowedBaselineDoesNotOverflowBeforeDivision() {
    let start = DateOnly(year: 2026, month: 1, day: 1)
    let end = DateOnly(year: 2027, month: 12, day: 31)
    let challenge = Challenge(
      title: "Synthetic two years", kind: .avoid, start: start, end: end,
      baseline: .inputLimit)
    // 584 of 730 days is exactly four fifths of the baseline.
    let midway = F.progress(challenge, [], today: start.adding(days: 583))
    #expect(midway.saved == AmountE4(raw: 8_000_000_000_000_000))
    #expect(F.progress(challenge, [], today: end).saved == .inputLimit)
  }

  @Test func theMedianOfLargePeriodsFitsEvenWhenTheirSumDoesNot() {
    let start = F.day(11, 16)
    let amount = AmountE4(raw: Int64.max / 2 + 1)
    let entries = [2, 1].map { back in
      let id = UUID()
      return TransactionEntry(
        transaction: Transaction(
          id: id, kind: .expense,
          occurredAt: F.calendar.noon(of: start.adding(days: -7 * back)),
          amountE4: amount),
        parts: [TransactionPart(transactionId: id, categoryId: F.food.id, amountE4: amount)])
    }
    let challenge = Challenge(
      title: "Synthetic median", kind: .avoid, start: start, end: start.adding(days: 6))
    #expect(ChallengeRules.baseline(for: challenge, ledger: F.ledger(entries))?.amount == amount)
  }

  @Test func prorationRoundsAHalfStoredUnitAwayFromZero() {
    let start = F.day(11, 1)
    let challenge = Challenge(
      title: "Synthetic half", kind: .avoid, start: start, end: start.adding(days: 1),
      baseline: AmountE4(raw: 1))
    #expect(F.progress(challenge, [], today: start).saved == AmountE4(raw: 1))
  }
}
