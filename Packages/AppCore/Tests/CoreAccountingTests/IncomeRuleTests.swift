import CoreKit
import Foundation
import Testing

@testable import CoreAccounting

struct IncomeRuleTests {
  @Test func onlyReconciliationSurplusesAreExcludedFromIncome() {
    #expect(!IncomeRule.isIncome(kind: .income, link: .reconciliation(UUID())))
    #expect(
      !IncomeRule.isIncome(
        kind: .income,
        link: .reconciledBalance(reconciliation: UUID(), balance: UUID())))
    #expect(IncomeRule.isIncome(kind: .income, link: nil))
    #expect(IncomeRule.isIncome(kind: .income, link: .surplus(reimbursement: UUID().uuidString)))
    #expect(!IncomeRule.isIncome(kind: .expense, link: nil))
  }
}
