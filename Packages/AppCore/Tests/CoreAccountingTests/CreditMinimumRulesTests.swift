import CoreKit
import Foundation
import Testing

@testable import CoreAccounting

@Suite("Credit statement minimum input")
struct CreditMinimumRulesTests {
  @Test func replacementKeepsOtherAccountsAndStatements() throws {
    let account = UUID()
    let other = UUID()
    let close = DateOnly(iso: "2026-11-05")!
    let due = DateOnly(iso: "2026-11-30")!
    let first = CreditStatementOverride(
      accountId: account, closesOn: close, minimumE4: AmountE4(whole: 2400), due: due)
    let second = CreditStatementOverride(
      accountId: other, closesOn: close, minimumE4: AmountE4(whole: 1200), due: due)
    var settings = DebtSettings(statementOverrides: [first, second])
    var edited = first
    edited.minimumE4 = AmountE4(whole: 3000)
    settings = try CreditMinimumRules.saving(
      edited, accountId: account, closesOn: close, in: settings)
    #expect(settings.statementOverrides == [second, edited])
    settings = try CreditMinimumRules.saving(nil, accountId: account, closesOn: close, in: settings)
    #expect(settings.statementOverrides == [second])
    edited.minimumE4 = AmountE4(whole: -1)
    #expect(throws: CreditMinimumRules.Issue.self) {
      try CreditMinimumRules.saving(edited, accountId: account, closesOn: close, in: settings)
    }
    edited.minimumE4 = .zero
    edited.due = close
    #expect(throws: CreditMinimumRules.Issue.self) {
      try CreditMinimumRules.saving(edited, accountId: account, closesOn: close, in: settings)
    }
  }
}
