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
    let existing = [first, second]
    var edited = first
    edited.id = UUID()
    edited.minimumE4 = AmountE4(whole: 3000)
    let change = try CreditMinimumRules.saving(
      edited, accountId: account, closesOn: close, among: existing)
    #expect(change.deleteId == nil)
    #expect(change.upsert?.id == first.id, "the pair stays one row: the typed row is written over")
    #expect(change.upsert?.minimumE4 == AmountE4(whole: 3000))
    let removed = try CreditMinimumRules.saving(
      nil, accountId: account, closesOn: close, among: existing)
    #expect(removed == CreditMinimumRules.Change(upsert: nil, deleteId: first.id))
    let nothing = try CreditMinimumRules.saving(
      nil, accountId: account, closesOn: DateOnly(iso: "2026-12-05")!, among: existing)
    #expect(nothing == CreditMinimumRules.Change(upsert: nil, deleteId: nil))
    let settings = existing
    edited.minimumE4 = AmountE4(whole: -1)
    #expect(throws: CreditMinimumRules.Issue.self) {
      try CreditMinimumRules.saving(edited, accountId: account, closesOn: close, among: settings)
    }
    edited.minimumE4 = .zero
    edited.due = close
    #expect(throws: CreditMinimumRules.Issue.self) {
      try CreditMinimumRules.saving(edited, accountId: account, closesOn: close, among: settings)
    }
  }
}
