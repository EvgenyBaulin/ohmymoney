import CoreKit
import Foundation
import Testing

@testable import CoreAccounting

/// What the edit of one saved operation may not do (the inspector, the edit sheet).
@Suite("What an edit of one operation may not do")
struct OperationEditRuleTests {
  private func reimbursement(_ amount: Int, note: String? = nil) -> TransactionEntry {
    entry(
      id(1), kind: .reimbursement, note: note, parts: [part(id(2), amount: money(amount))])
  }

  /// The money a reimbursement worked its links out from — how much, in what, and that it is
  /// money given back — is not edited in place; everything else is.
  @Test func theMoneyOfAReimbursementThatSettledPartsStaysAsItWasWorkedOut() {
    let before = reimbursement(1_500)
    #expect(
      OperationEditRule.refusal(editing: before, into: reimbursement(1_400), settles: true)
        == .settledReimbursement)
    var income = before
    income.transaction.kind = .income
    #expect(
      OperationEditRule.refusal(editing: before, into: income, settles: true)
        == .settledReimbursement)
    var dollars = before
    dollars.transaction.currency = .usd
    #expect(
      OperationEditRule.refusal(editing: before, into: dollars, settles: true)
        == .settledReimbursement)

    #expect(
      OperationEditRule.refusal(
        editing: before, into: reimbursement(1_500, note: "cash"), settles: true) == nil)
    // Money given back on a debt settles nothing but its journal line, which follows it.
    #expect(
      OperationEditRule.refusal(editing: before, into: reimbursement(1_400), settles: false)
        == nil)
  }

  @Test func theSurplusAndTheShortfallOfAReimbursementKeepTheirMoneyToo() {
    var shortfall = entry(id(3), parts: [part(id(4), amount: money(200))])
    shortfall.transaction.externalId = ReimbursementCompanions.shortfallKey(
      of: id(1), partId: id(5))
    var changed = shortfall
    changed.transaction.amountE4 = money(100)
    changed.parts[0].amountE4 = money(100)
    #expect(
      OperationEditRule.refusal(editing: shortfall, into: changed, settles: false)
        == .settledReimbursement)

    var surplus = entry(id(6), kind: .income, parts: [part(id(7), amount: money(300))])
    surplus.transaction.externalId = ReimbursementCompanions.surplusKey(of: id(1))
    #expect(OperationEditRule.isCompanion(surplus.transaction))
    #expect(!OperationEditRule.isCompanion(reimbursement(1_500).transaction))
  }

  /// A part someone gave the money back for stays in its operation; one still owed, written
  /// off or mine goes like any other.
  @Test func aPartAReimbursementClosedIsNotTakenAway() {
    func dinner(_ status: ReimbursementStatus) -> TransactionEntry {
      entry(
        id(1),
        parts: [
          part(id(11), amount: money(600)),
          part(id(12), amount: money(400), reimbursable: true, status: status, debtor: id(50)),
        ])
    }
    func withoutTheirHalf(_ entry: TransactionEntry) -> TransactionEntry {
      var changed = entry
      changed.parts.removeLast()
      changed.parts[0].amountE4 = money(1_000)
      return changed
    }
    let closed = dinner(.returned)
    #expect(
      OperationEditRule.refusal(editing: closed, into: withoutTheirHalf(closed), settles: false)
        == .closedPartRemoved)
    for status in [ReimbursementStatus.expected, .writtenOff] {
      let open = dinner(status)
      #expect(
        OperationEditRule.refusal(editing: open, into: withoutTheirHalf(open), settles: false)
          == nil)
    }
    // Its note or its category may change: the part stays.
    var renamed = closed
    renamed.parts[1].note = "their half"
    #expect(OperationEditRule.refusal(editing: closed, into: renamed, settles: false) == nil)
  }

  /// The money of a closed part stays as the reimbursement found it: still paid for somebody
  /// else, still closed, the same amount, in the same currency, of the same type. Whom it was
  /// for, my own part and the rest of the operation stay editable; a part still owed is
  /// changed like any other.
  @Test func theMoneyOfAPartAReimbursementClosedStaysAsItWas() {
    func dinner(_ status: ReimbursementStatus) -> TransactionEntry {
      entry(
        id(1),
        parts: [
          part(id(11), amount: money(600)),
          part(id(12), amount: money(400), reimbursable: true, status: status, debtor: id(50)),
        ])
    }
    let closed = dinner(.returned)
    var unticked = closed
    unticked.parts[1].reimbursable = false
    unticked.parts[1].reimbursementStatus = nil
    var resized = closed
    resized.parts[0].amountE4 = money(700)
    resized.parts[1].amountE4 = money(300)
    var dollars = closed
    dollars.transaction.currency = .usd
    var income = closed
    income.transaction.kind = .income
    for changed in [unticked, resized, dollars, income] {
      #expect(
        OperationEditRule.refusal(editing: closed, into: changed, settles: false)
          == .closedPartChanged)
    }

    var forFamily = closed
    forFamily.parts[1].forWhom = .family
    forFamily.parts[0].note = "mine"
    forFamily.transaction.note = "dinner"
    #expect(OperationEditRule.refusal(editing: closed, into: forFamily, settles: false) == nil)

    let open = dinner(.expected)
    var openUnticked = open
    openUnticked.parts[1].reimbursable = false
    openUnticked.parts[1].reimbursementStatus = nil
    #expect(OperationEditRule.refusal(editing: open, into: openUnticked, settles: false) == nil)
  }
}
