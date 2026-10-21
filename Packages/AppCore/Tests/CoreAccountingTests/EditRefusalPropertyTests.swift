import CoreKit
import Foundation
import Testing

@testable import CoreAccounting

/// What the edit of a saved operation may not do when refunds and money back lean on it, on
/// random purchases, refunds and links.
@Suite("Edits that refunds and money back lean on, on random operations")
struct EditRefusalPropertyTests {
  let categories = StartingCategories()

  struct Case {
    var purchase: TransactionEntry
    var facts: EditFacts
  }

  /// A purchase of two or three parts: some refunded in part, some paid for somebody else with
  /// some money back.
  func randomCase(_ dice: inout MoneyDice) -> Case {
    var parts: [TransactionPart] = []
    var refunded: [UUID: AmountE4] = [:]
    var linked: [UUID: AmountE4] = [:]
    for index in 0..<dice.int(2...3) {
      let amount = dice.amount(upTo: 5000)
      let forOthers = dice.chance(40)
      let part = TransactionPart(
        id: id(10 + index), transactionId: id(1), categoryId: categories.groceries,
        amountE4: amount, forWhom: forOthers ? .friends : .me, reimbursable: forOthers,
        debtorPersonId: forOthers ? id(300) : nil,
        reimbursementStatus: forOthers ? .expected : nil)
      parts.append(part)
      if forOthers {
        if dice.chance(60) {
          linked[part.id] = AmountE4(raw: Int64(dice.int(1...Int(amount.raw - 1))))
        }
      } else if dice.chance(60) {
        refunded[part.id] = AmountE4(raw: Int64(dice.int(1...Int(amount.raw))))
      }
    }
    let purchase = TransactionEntry(
      transaction: Transaction(
        id: id(1), kind: .expense, occurredAt: moment("2026-03-02"),
        amountE4: AmountE4.sum(parts.map(\.amountE4)), paymentMethodId: id(1)),
      parts: parts)
    return Case(
      purchase: purchase, facts: EditFacts(linkedRubByPart: linked, refundedByPart: refunded))
  }

  /// Nothing that decides the money — the description, the category, the quality, «на кого»,
  /// the event, the place, the account, the day — is ever refused.
  @Test(arguments: Array(1...80) as [UInt64])
  func whatDoesNotTouchTheMoneyIsNeverRefused(seed: UInt64) {
    var dice = MoneyDice(seed: seed)
    let random = randomCase(&dice)
    var after = random.purchase
    after.transaction.note = "edited"
    after.transaction.placeId = id(500)
    after.transaction.paymentMethodId = id(2)
    after.transaction.occurredAt = moment("2026-04-15")
    for index in after.parts.indices {
      after.parts[index].categoryId = categories.fuel
      after.parts[index].quality = .bad
      after.parts[index].eventId = id(400)
      if !after.parts[index].reimbursable { after.parts[index].forWhom = .partner }
    }
    #expect(
      OperationEditRule.refusal(editing: random.purchase, into: after, facts: random.facts) == nil,
      "seed \(seed)")
  }

  /// A part refunds took money back from never becomes cheaper than what they took, never goes,
  /// and the purchase keeps its currency and kind and never goes on credit; a part some money
  /// came back for keeps its money. Any edit of that kind is refused, whichever part it touches.
  @Test(arguments: Array(1...80) as [UInt64])
  func whatARefundOrMoneyBackLeansOnIsKept(seed: UInt64) {
    var dice = MoneyDice(seed: seed)
    let random = randomCase(&dice)
    let leanedOn = random.purchase.parts.filter {
      (random.facts.refundedByPart[$0.id]?.raw ?? 0) > 0
        || (random.facts.linkedRubByPart[$0.id]?.raw ?? 0) > 0
    }
    guard let target = leanedOn.first,
      let index = random.purchase.parts.firstIndex(where: { $0.id == target.id })
    else { return }
    let refundedAmount = random.facts.refundedByPart[target.id] ?? .zero
    var edits: [TransactionEntry] = []
    var gone = random.purchase
    gone.parts.remove(at: index)
    edits.append(gone)
    var currency = random.purchase
    currency.transaction.currency = .usd
    edits.append(currency)
    var kind = random.purchase
    kind.transaction.kind = .income
    edits.append(kind)
    if refundedAmount.raw > 0 {
      var cheaper = random.purchase
      cheaper.parts[index].amountE4 = AmountE4(raw: refundedAmount.raw - 1)
      edits.append(cheaper)
      var credit = random.purchase
      credit.transaction.creditDebtId = id(201)
      edits.append(credit)
    } else {
      var other = random.purchase
      other.parts[index].amountE4 = AmountE4(raw: target.amountE4.raw + 100)
      edits.append(other)
      var mine = random.purchase
      mine.parts[index].reimbursable = false
      edits.append(mine)
    }
    for edit in edits {
      #expect(
        OperationEditRule.refusal(editing: random.purchase, into: edit, facts: random.facts)
          != nil, "seed \(seed)")
    }
    // A refunded part may still grow, or be as cheap as what came back.
    if refundedAmount.raw > 0 {
      var same = random.purchase
      same.parts[index].amountE4 = refundedAmount
      let mayGrow = random.purchase.parts.allSatisfy {
        (random.facts.linkedRubByPart[$0.id]?.raw ?? 0) == 0
      }
      if mayGrow {
        #expect(
          OperationEditRule.refusal(editing: random.purchase, into: same, facts: random.facts)
            == nil, "seed \(seed)")
      }
    }
  }
}
