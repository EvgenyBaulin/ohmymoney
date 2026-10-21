import CoreKit
import Foundation
import Testing

@testable import CoreAccounting

/// The edit of a saved operation against a model of what refunds and money back lean on, on
/// random purchases and refunds with random edits of every kind: an edit is refused exactly
/// when it breaks one of the rules, and the refusal names a rule it breaks.
@Suite("Edits refused by a model of what leans on them")
struct EditRefusalModelPropertyTests {
  /// A rule an edit may break.
  enum Rule: Hashable {
    case edit(EditRefusal)
    case linked(LinkedEditRefusal)
  }

  struct Case {
    var before: TransactionEntry
    var facts: EditFacts
  }

  static let rate: Decimal = 90

  func rubles(_ amount: AmountE4, _ currency: CurrencyCode) -> AmountE4 {
    currency == .rub ? amount : MoneyDice.rounded(amount.decimal * Self.rate)
  }

  /// A purchase of one to four parts: some of my own, some refunded in part or whole; some paid
  /// for somebody else — still waiting, some money already back, closed by money back, or
  /// written off.
  func purchase(_ dice: inout MoneyDice) -> Case {
    let currency = dice.pick([CurrencyCode.rub, .usd])
    var parts: [TransactionPart] = []
    var refunded: [UUID: AmountE4] = [:]
    var linked: [UUID: AmountE4] = [:]
    for index in 0..<dice.int(1...4) {
      let amount = currency == .rub ? dice.amount(upTo: 5000) : dice.amount(upTo: 60)
      let forOthers = dice.chance(50)
      let status: ReimbursementStatus? =
        forOthers ? dice.pick([.expected, .expected, .returned, .writtenOff]) : nil
      let part = TransactionPart(
        id: id(10 + index), transactionId: id(1), categoryId: id(110), amountE4: amount,
        amountRubE4: rubles(amount, currency), forWhom: forOthers ? .friends : .me,
        reimbursable: forOthers, debtorPersonId: forOthers ? id(300) : nil,
        reimbursementStatus: status)
      parts.append(part)
      if forOthers {
        if status == .expected, dice.chance(60) {
          linked[part.id] = AmountE4(raw: Int64(dice.int(1...Int(part.amountRubE4.raw - 1))))
        }
        if status == .returned { linked[part.id] = part.amountRubE4 }
      } else if dice.chance(60) {
        refunded[part.id] = AmountE4(raw: Int64(dice.int(1...Int(amount.raw))))
      }
    }
    let amount = AmountE4.sum(parts.map(\.amountE4))
    let before = TransactionEntry(
      transaction: Transaction(
        id: id(1), kind: .expense, occurredAt: moment("2026-03-02"), currency: currency,
        amountE4: amount, rate: currency == .rub ? nil : Self.rate,
        amountRubE4: AmountE4.sum(parts.map(\.amountRubE4)), paymentMethodId: id(1)),
      parts: parts)
    return Case(before: before, facts: EditFacts(linkedRubByPart: linked, refundedByPart: refunded))
  }

  /// A refund taking back from one or two purchase parts, with what is left of each of those to
  /// refund, its own amount not counted.
  func refund(_ dice: inout MoneyDice) -> Case {
    let currency = dice.pick([CurrencyCode.rub, .usd])
    var parts: [TransactionPart] = []
    var left: [UUID: RefundableRemainder] = [:]
    for index in 0..<dice.int(1...2) {
      let amount = currency == .rub ? dice.amount(upTo: 3000) : dice.amount(upTo: 40)
      let target = id(700 + index)
      parts.append(
        TransactionPart(
          id: id(20 + index), transactionId: id(2), categoryId: id(110), amountE4: amount,
          amountRubE4: rubles(amount, currency), refundOfPartId: target))
      left[target] = RefundableRemainder(
        remaining: amount + (dice.chance(50) ? dice.amount(upTo: 50) : .zero), currency: currency)
    }
    let before = TransactionEntry(
      transaction: Transaction(
        id: id(2), kind: .refund, occurredAt: moment("2026-03-12"), currency: currency,
        amountE4: AmountE4.sum(parts.map(\.amountE4)), rate: currency == .rub ? nil : Self.rate,
        amountRubE4: AmountE4.sum(parts.map(\.amountRubE4)), paymentMethodId: id(1)),
      parts: parts)
    return Case(before: before, facts: EditFacts(refundOf: left))
  }

  /// Some random edit of the operation: parts removed, amounts up or down, rubles moved by a new
  /// rate, «за другого» switched, a status changed, the currency, the kind or credit changed.
  func edited(_ before: TransactionEntry, _ dice: inout MoneyDice) -> TransactionEntry {
    var after = before
    for _ in 0..<dice.int(1...3) {
      guard !after.parts.isEmpty else { break }
      let index = dice.below(after.parts.count)
      switch dice.below(9) {
      case 0: after.parts.remove(at: index)
      case 1:
        let amount = after.parts[index].amountE4
        let factor = Decimal(dice.int(1...200)) / 100
        let new = max(AmountE4(raw: 1), MoneyDice.rounded(amount.decimal * factor))
        after.parts[index].amountE4 = new
        after.parts[index].amountRubE4 = rubles(new, after.transaction.currency)
      case 2:
        let rub = after.parts[index].amountRubE4
        after.parts[index].amountRubE4 = MoneyDice.rounded(
          rub.decimal * Decimal(dice.int(50...150)) / 100)
      case 3:
        after.parts[index].reimbursable.toggle()
        after.parts[index].reimbursementStatus = after.parts[index].reimbursable ? .expected : nil
        after.parts[index].debtorPersonId = after.parts[index].reimbursable ? id(300) : nil
      case 4:
        if after.parts[index].reimbursable {
          after.parts[index].reimbursementStatus = dice.pick([.expected, .returned, .writtenOff])
        }
      case 5: after.transaction.currency = after.transaction.currency == .rub ? .usd : .rub
      case 6:
        after.transaction.kind = dice.pick(
          TransactionKind.allCases.filter {
            $0 != after.transaction.kind
          })
      case 7: after.transaction.creditDebtId = id(201)
      default:
        after.parts[index].refundOfPartId =
          after.parts[index].refundOfPartId == nil ? nil : dice.pick([nil, id(700), id(701)])
      }
    }
    after.transaction.amountE4 = AmountE4.sum(after.parts.map(\.amountE4))
    return after
  }

  /// The rules the edit breaks, written out from what leans on the operation.
  func broken(
    _ before: TransactionEntry, _ after: TransactionEntry, _ facts: EditFacts
  ) -> Set<
    Rule
  > {
    var rules: Set<Rule> = []
    let old = before.transaction
    let new = after.transaction
    let kindOrCurrency = old.kind != new.kind || old.currency != new.currency
    let now = Dictionary(uniqueKeysWithValues: after.parts.map { ($0.id, $0) })
    for part in before.parts {
      let edited = now[part.id]
      // Closed by money back: stays, and stays as it was.
      if part.reimbursementStatus == .returned {
        guard let edited else {
          rules.insert(.edit(.closedPartRemoved))
          continue
        }
        if kindOrCurrency || !edited.reimbursable || edited.reimbursementStatus != .returned
          || edited.amountE4 != part.amountE4
        {
          rules.insert(.edit(.closedPartChanged))
        }
      }
      // Refunds took money back from it: stays, keeps its currency and kind, goes on no credit,
      // becomes no part «за другого», and never cheaper than what came back.
      let refunded = facts.refundedByPart[part.id] ?? .zero
      if refunded.raw > 0 {
        guard let edited else {
          rules.insert(.linked(.refundedPartRemoved))
          continue
        }
        if kindOrCurrency || (old.creditDebtId == nil && new.creditDebtId != nil)
          || (edited.reimbursable && !part.reimbursable)
        {
          rules.insert(.linked(.refundedPartChanged))
        }
        if edited.amountE4 < refunded { rules.insert(.linked(.refundedPartReduced)) }
      }
      // Some money back came for it while it still waits: its money stays as it was; its
      // rubles may change (the money back is balanced again in the same write).
      let linked = facts.linkedRubByPart[part.id] ?? .zero
      if part.reimbursable, (part.reimbursementStatus ?? .expected) == .expected, linked.raw > 0 {
        if kindOrCurrency {
          rules.insert(.linked(.partlyReturnedPartChanged))
        } else if let edited {
          if edited.amountE4 != part.amountE4 || edited.reimbursable != part.reimbursable {
            rules.insert(.linked(.partlyReturnedPartChanged))
          }
        } else {
          rules.insert(.linked(.partlyReturnedPartChanged))
        }
      }
    }
    // A refund taken back from a purchase stays a refund in the purchase's currency, and asks
    // no more of any part than is left of it.
    if before.parts.contains(where: { $0.refundOfPartId != nil }), new.kind != .refund {
      rules.insert(.linked(.linkedRefundChanged))
    }
    var asked: [UUID: AmountE4] = [:]
    for part in after.parts {
      if let target = part.refundOfPartId { asked[target, default: .zero] += part.amountE4 }
    }
    for (target, amount) in asked {
      guard let left = facts.refundOf[target] else { continue }
      if new.kind != .refund || new.currency != left.currency || amount > left.remaining {
        rules.insert(.linked(.linkedRefundChanged))
      }
    }
    return rules
  }

  func rule(of error: (any Error & Sendable)?) -> Rule? {
    switch error {
    case let refusal as EditRefusal: .edit(refusal)
    case let refusal as LinkedEditRefusal: .linked(refusal)
    default: nil
    }
  }

  /// An edit of a purchase is refused exactly when it breaks a rule, whichever part it touches
  /// — any closed, refunded, partly returned or plain part, one or several at once —, and the
  /// refusal names one of the rules it breaks.
  @Test(arguments: Array(1...150) as [UInt64])
  func aPurchaseEditIsRefusedExactlyWhenItBreaksARule(seed: UInt64) {
    var dice = MoneyDice(seed: seed)
    let random = purchase(&dice)
    for _ in 0..<8 {
      let after = edited(random.before, &dice)
      let rules = broken(random.before, after, random.facts)
      let refusal = rule(
        of: OperationEditRule.refusal(editing: random.before, into: after, facts: random.facts))
      if let refusal {
        #expect(rules.contains(refusal), "seed \(seed): \(refusal) is none of \(rules)")
      } else {
        #expect(rules.isEmpty, "seed \(seed): let through, breaking \(rules)")
      }
    }
  }

  /// An edit of a refund taken back from purchases: refused exactly when it takes more than is
  /// left of a part, changes the currency or stops being a refund.
  @Test(arguments: Array(1...150) as [UInt64])
  func aRefundEditIsRefusedExactlyWhenItBreaksARule(seed: UInt64) {
    var dice = MoneyDice(seed: seed)
    let random = refund(&dice)
    for _ in 0..<8 {
      let after = edited(random.before, &dice)
      let rules = broken(random.before, after, random.facts)
      let refusal = rule(
        of: OperationEditRule.refusal(editing: random.before, into: after, facts: random.facts))
      if let refusal {
        #expect(rules.contains(refusal), "seed \(seed): \(refusal) is none of \(rules)")
      } else {
        #expect(rules.isEmpty, "seed \(seed): let through, breaking \(rules)")
      }
    }
  }

  /// The random edits break every rule somewhere, and leave some edits with nothing broken, so
  /// the two properties above are not green for want of cases.
  @Test func theRandomEditsReachEveryRule() {
    var seen: Set<Rule> = []
    var allowed = 0
    for seed in 1...150 as ClosedRange<UInt64> {
      var dice = MoneyDice(seed: seed)
      let purchase = purchase(&dice)
      let refund = refund(&dice)
      for random in [purchase, refund] {
        for _ in 0..<8 {
          let rules = broken(random.before, edited(random.before, &dice), random.facts)
          seen.formUnion(rules)
          if rules.isEmpty { allowed += 1 }
        }
      }
    }
    let every: Set<Rule> = [
      .edit(.closedPartRemoved), .edit(.closedPartChanged), .linked(.refundedPartRemoved),
      .linked(.refundedPartReduced), .linked(.refundedPartChanged),
      .linked(.partlyReturnedPartChanged), .linked(.linkedRefundChanged),
    ]
    #expect(every.isSubset(of: seen), "\(every.subtracting(seen))")
    #expect(allowed > 100, "\(allowed)")
  }
}
