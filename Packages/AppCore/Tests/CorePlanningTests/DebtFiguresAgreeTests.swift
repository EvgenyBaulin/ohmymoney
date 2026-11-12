import CoreAccounting
import CoreAnalytics
import CoreKit
import CoreSample
import Foundation
import Testing

@testable import CorePlanning

/// «Owed to me» and «I owe» are said on three screens — the Overview tiles, the Debts summary
/// and the Capital. On one sample they may differ only by what each says it counts, and the
/// differences are exactly those: the parts paid for others (Overview and Debts, not Capital),
/// the interest charged and not yet paid (Capital, not the Debts balances).
@Suite("The debt figures of the Overview, the Debts and the Capital agree")
struct DebtFiguresAgreeTests {
  static let cases = SampleLoanAndSavingsPlanningTests.cases

  @Test(arguments: cases)
  func owedToMeIsThePartsAndTheDebtsToMe(_ testCase: SampleLoanAndSavingsPlanningTests.Case) {
    let set = SampleLoanAndSavingsPlanningTests.set(testCase)
    let ledger = SampleLoanAndSavingsPlanningTests.ledger(set)
    let planning = SampleLoanAndSavingsPlanningTests.snapshot(set)
    let parts = OwedParts(ledger)
    let groupedParts = planning.debts.owedToMe.flatMap(\.parts)
    // The Debts list the very parts the Overview counts.
    #expect(AmountE4.sum(groupedParts.map(\.amountRub)) == parts.total, "\(testCase)")
    #expect(groupedParts.count == parts.parts.count, "\(testCase)")
    // Debts total = those parts + the debts owed to me, which the Capital counts alone.
    #expect(
      planning.debts.totalOwedToMeRub == parts.total + planning.capital.now.owedToMeRub,
      "\(testCase)")
  }

  @Test(arguments: cases)
  func iOweDiffersByTheUnpaidInterestOnly(_ testCase: SampleLoanAndSavingsPlanningTests.Case) {
    let set = SampleLoanAndSavingsPlanningTests.set(testCase)
    let planning = SampleLoanAndSavingsPlanningTests.snapshot(set)
    #expect(
      planning.debts.totalIOweRub + planning.debts.accruedInterestRub
        == planning.capital.now.iOweRub, "\(testCase)")
    // The same debts are listed: the Capital's lines are the Debts' open ones I owe.
    #expect(planning.capital.breakdown.owe.count == planning.debts.iOwe.count, "\(testCase)")
  }
}
