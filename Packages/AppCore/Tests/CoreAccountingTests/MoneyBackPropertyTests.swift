import CoreKit
import Foundation
import Testing

@testable import CoreAccounting

/// `amount × numerator ÷ denominator`, rounded half away from zero, in whole integers.
private func scaled(_ amount: AmountE4, _ numerator: AmountE4, _ denominator: AmountE4) -> AmountE4
{
  guard !denominator.isZero else { return .zero }
  let top = Int128(amount.raw) * Int128(numerator.raw)
  let bottom = Int128(denominator.raw)
  let magnitude = (abs(top) * 2 + abs(bottom)) / (abs(bottom) * 2)
  return AmountE4(raw: Int64((top < 0) != (bottom < 0) ? -magnitude : magnitude))
}

/// The tolerance for rate drift, written out: nothing in rubles alone, otherwise 1 % of the
/// part's rubles rounded to the stored unit, never below 1 ₽ nor above 50 ₽.
private func drift(_ partRub: AmountE4, foreign: Bool) -> AmountE4 {
  guard foreign else { return .zero }
  let percent = scaled(partRub.magnitude, AmountE4(raw: 1), AmountE4(raw: 100))
  return min(max(AmountE4(whole: 1), percent), AmountE4(whole: 50))
}

/// The model of the rule (`MoneyBackRuleModel`) for money back with no rate still provisional.
private enum MoneyBackModel {
  static func plan(
    received: AmountE4, currency: CurrencyCode, receivedRub: AmountE4, owed: [OwedPart]
  ) -> MoneyBackRuleModel {
    MoneyBackRuleModel.plan(
      received: received, currency: currency, receivedRub: receivedRub, rateProvisional: false,
      person: id(40), owed: owed, openDebts: [])
  }
}

/// Random people's debts — parts in rubles and in dollars at random rates, some already partly
/// back — and random money back, in rubles or dollars.
private struct Owing {
  var dice: MoneyDice
  let person = id(40)
  var parts: [OwedPart] = []

  init(seed: UInt64, rublesOnly: Bool, dollarsOnly: Bool = false) {
    dice = MoneyDice(seed: seed)
    let start = moment("2026-02-01")
    for index in 0..<dice.int(1...6) {
      let currency: CurrencyCode =
        dollarsOnly ? .usd : rublesOnly ? .rub : dice.pick([.rub, .usd])
      let amount = currency == .rub ? dice.amount(upTo: 9000) : dice.amount(upTo: 120)
      let rub =
        currency == .rub
        ? amount
        : MoneyDice.rounded(amount.decimal * Decimal(dice.int(700_000...1_109_999)) / 10_000)
      let returned =
        dice.chance(30) ? AmountE4(raw: Int64(dice.int(0...Int(rub.raw - 1)))) : AmountE4.zero
      parts.append(
        OwedPart(
          partId: id(100 + index), transactionId: id(1100 + index),
          occurredAt: start.addingTimeInterval(TimeInterval(dice.below(40) * 86_400)),
          debtorPersonId: person, forWhom: .friends, amountE4: amount, amountRubE4: rub,
          currency: currency, returnedRubE4: returned, accountId: id(1)))
    }
  }

  var totalRemaining: AmountE4 { AmountE4.sum(parts.map(\.remainingRubE4)) }
}

@Suite("Money back against a model of the rule")
struct MoneyBackPropertyTests {
  static let seeds: [UInt64] = Array(1...60)

  /// In rubles alone the spread is exact: oldest first, every ruble reaching a part or the
  /// surplus, a part covered only partly still waiting with the rest, nothing within any
  /// tolerance.
  @Test(arguments: seeds)
  func inRublesEveryRubleIsAccountedFor(seed: UInt64) {
    var owing = Owing(seed: seed, rublesOnly: true)
    let received =
      owing.dice.chance(20)
      ? owing.totalRemaining + owing.dice.amount(upTo: 500)
      : AmountE4(raw: Int64(owing.dice.int(1...Int(owing.totalRemaining.raw + 10_000))))
    let plan = MoneyBack.plan(
      received: received, currency: .rub, receivedRub: received, rateProvisional: false,
      person: owing.person, owed: owing.parts, openDebts: [])
    let model = MoneyBackModel.plan(
      received: received, currency: .rub, receivedRub: received, owed: owing.parts)
    #expect(plan.refusal == nil, "seed \(seed)")
    #expect(plan.allocations == model.allocations, "seed \(seed)")
    #expect(plan.closes == model.closes, "seed \(seed)")
    #expect(plan.stillOwed == model.stillOwed, "seed \(seed)")
    #expect(plan.surplus == model.surplus, "seed \(seed)")
    #expect(plan.allocatedRubE4 + plan.surplus == received, "seed \(seed)")
    for allocation in plan.allocations {
      guard let part = owing.parts.first(where: { $0.partId == allocation.partId }) else {
        Issue.record("seed \(seed): a share for a part nobody owes")
        continue
      }
      #expect(allocation.amountE4 <= part.remainingRubE4, "seed \(seed)")
      #expect(
        plan.closes.contains(part.partId) == (allocation.amountE4 == part.remainingRubE4),
        "seed \(seed): in rubles a part closes exactly when all of it is back")
    }
  }

  /// With dollars about — parts in dollars, money back in dollars at its own rate — the plan is
  /// what the rule says, the drift of rates included.
  @Test(arguments: seeds)
  func withDollarsThePlanIsWhatTheRuleSays(seed: UInt64) {
    var owing = Owing(seed: seed, rublesOnly: false)
    let inDollars = owing.dice.chance(60)
    let rate = Decimal(owing.dice.int(700_000...1_109_999)) / 10_000
    let received = inDollars ? owing.dice.amount(upTo: 400) : owing.dice.amount(upTo: 30_000)
    let receivedRub = inDollars ? MoneyDice.rounded(received.decimal * rate) : received
    let currency: CurrencyCode = inDollars ? .usd : .rub
    let plan = MoneyBack.plan(
      received: received, currency: currency, receivedRub: receivedRub, rateProvisional: false,
      person: owing.person, owed: owing.parts, openDebts: [])
    let model = MoneyBackModel.plan(
      received: received, currency: currency, receivedRub: receivedRub, owed: owing.parts)
    #expect(plan.refusal == nil, "seed \(seed)")
    #expect(plan.allocations == model.allocations, "seed \(seed)")
    #expect(plan.closes == model.closes, "seed \(seed)")
    #expect(plan.stillOwed == model.stillOwed, "seed \(seed)")
    #expect(plan.surplus == model.surplus, "seed \(seed)")
    #expect(plan.surplusRub == model.surplusRub, "seed \(seed)")
  }

  /// Whatever the money: every part waiting is either closed or still owed, never both; a link
  /// is never more than what was left of its part; nothing falls short; money is left over only
  /// once every part is closed; the outcome writes a link per share and the surplus on the
  /// account the money came onto, in its currency.
  @Test(arguments: seeds)
  func theSpreadKeepsItsPromises(seed: UInt64) {
    var owing = Owing(seed: seed, rublesOnly: false)
    let currency: CurrencyCode = owing.dice.pick([.rub, .usd])
    let received = currency == .rub ? owing.dice.amount(upTo: 40_000) : owing.dice.amount(upTo: 500)
    let receivedRub =
      currency == .rub
      ? received : MoneyDice.rounded(received.decimal * Decimal(owing.dice.int(60...120)))
    let plan = MoneyBack.plan(
      received: received, currency: currency, receivedRub: receivedRub, rateProvisional: false,
      person: owing.person, owed: owing.parts, openDebts: [])
    let waiting = Set(owing.parts.filter { $0.remainingRubE4.raw > 0 }.map(\.partId))
    let closed = Set(plan.closes)
    let open = Set(plan.stillOwed.map(\.partId))
    #expect(closed.isDisjoint(with: open), "seed \(seed)")
    #expect(closed.union(open) == waiting, "seed \(seed)")
    #expect(closed.isSubset(of: Set(plan.allocations.map(\.partId))), "seed \(seed)")
    let order = owing.parts.sorted(by: MyExpensesRule.oldestFirst).map(\.partId)
    let allocated = plan.allocations.map(\.partId)
    #expect(allocated == order.filter(allocated.contains), "seed \(seed): oldest first")
    for allocation in plan.allocations {
      let part = owing.parts.first { $0.partId == allocation.partId }
      #expect(allocation.amountE4.raw > 0, "seed \(seed)")
      #expect(allocation.amountE4 <= part?.remainingRubE4 ?? .zero, "seed \(seed)")
    }
    for remainder in plan.stillOwed {
      let part = owing.parts.first { $0.partId == remainder.partId }
      let link = plan.allocations.first { $0.partId == remainder.partId }?.amountE4 ?? .zero
      #expect(remainder.remainingRubE4 == (part?.remainingRubE4 ?? .zero) - link, "seed \(seed)")
    }
    if plan.surplus.raw > 0 { #expect(open.isEmpty, "seed \(seed)") }

    let outcome = MoneyBack.outcome(plan, reimbursementTxId: id(9), accountId: id(7))
    #expect(outcome.shortfalls.isEmpty, "seed \(seed)")
    #expect(outcome.links.map(\.partId) == plan.allocations.map(\.partId), "seed \(seed)")
    #expect(outcome.links.map(\.amountE4) == plan.allocations.map(\.amountE4), "seed \(seed)")
    #expect(outcome.closedPartIds == plan.closes, "seed \(seed)")
    if plan.surplus.raw > 0 {
      #expect(outcome.surplus?.accountId == id(7), "seed \(seed)")
      #expect(outcome.surplus?.currency == currency, "seed \(seed)")
      #expect(outcome.surplus?.amountE4 == plan.surplus, "seed \(seed)")
    } else {
      #expect(outcome.surplus == nil, "seed \(seed)")
    }
  }

  /// Dollars back for parts bought in dollars close them by their own amount, at any rate of
  /// the money back: exactly what is owed in dollars leaves nothing open and nothing over.
  @Test(arguments: seeds)
  func dollarsBackForDollarPartsCloseThemAtAnyRate(seed: UInt64) {
    var owing = Owing(seed: seed, rublesOnly: false, dollarsOnly: true)
    for index in owing.parts.indices { owing.parts[index].returnedRubE4 = .zero }
    let owedDollars = AmountE4.sum(owing.parts.map(\.amountE4))
    let rate = Decimal(owing.dice.int(300_000...2_000_000)) / 10_000
    let plan = MoneyBack.plan(
      received: owedDollars, currency: .usd,
      receivedRub: MoneyDice.rounded(owedDollars.decimal * rate),
      rateProvisional: false, person: owing.person, owed: owing.parts, openDebts: [])
    #expect(Set(plan.closes) == Set(owing.parts.map(\.partId)), "seed \(seed)")
    #expect(plan.stillOwed.isEmpty, "seed \(seed)")
    #expect(plan.surplus == .zero, "seed \(seed)")
    #expect(plan.allocatedRubE4 == AmountE4.sum(owing.parts.map(\.amountRubE4)), "seed \(seed)")
  }

  /// Money back in instalments — each spread over what is left after the ones before — closes
  /// the same parts with the same rubles as the whole sum at once, in rubles alone; once all
  /// is back, more money is refused as owing nothing.
  @Test(arguments: seeds)
  func inRublesInstalmentsAddUpToTheWhole(seed: UInt64) {
    var owing = Owing(seed: seed, rublesOnly: true)
    var parts = owing.parts
    var linked: [UUID: AmountE4] = [:]
    var surplus = AmountE4.zero
    var paid = AmountE4.zero
    var closed: Set<UUID> = []
    for _ in 0..<owing.dice.int(1...5) {
      let received = owing.dice.amount(upTo: 6000)
      paid += received
      let plan = MoneyBack.plan(
        received: received, currency: .rub, receivedRub: received, rateProvisional: false,
        person: owing.person, owed: parts.filter { !closed.contains($0.partId) }, openDebts: [])
      if plan.refusal == .owesNothing {
        surplus += received
        continue
      }
      #expect(plan.refusal == nil, "seed \(seed)")
      for allocation in plan.allocations {
        linked[allocation.partId, default: .zero] += allocation.amountE4
        if let index = parts.firstIndex(where: { $0.partId == allocation.partId }) {
          parts[index].returnedRubE4 += allocation.amountE4
        }
      }
      closed.formUnion(plan.closes)
      surplus += plan.surplus
    }
    let whole = MoneyBack.plan(
      received: paid, currency: .rub, receivedRub: paid, rateProvisional: false,
      person: owing.person, owed: owing.parts, openDebts: [])
    #expect(Set(whole.closes) == closed, "seed \(seed)")
    for allocation in whole.allocations {
      #expect(linked[allocation.partId] == allocation.amountE4, "seed \(seed)")
    }
    #expect(whole.surplus == surplus, "seed \(seed)")
    for part in parts {
      #expect(part.returnedRubE4 <= part.amountRubE4, "seed \(seed): more back than paid")
    }
  }

  /// The tolerance: nothing in rubles alone; otherwise 1 % of the part, from 1 ₽ to 50 ₽.
  @Test(arguments: seeds)
  func theToleranceIsOnePercentBetweenOneAndFiftyRubles(seed: UInt64) {
    var dice = MoneyDice(seed: seed)
    let partRub = dice.chance(30) ? dice.fineAmount(upTo: 200) : dice.fineAmount(upTo: 20_000)
    #expect(MoneyBack.tolerance(partRub: partRub, foreignInvolved: false) == .zero)
    #expect(
      MoneyBack.tolerance(partRub: partRub, foreignInvolved: true)
        == drift(partRub, foreign: true), "seed \(seed): \(partRub.decimal)")
  }
}

/// «Вручную…»: money back settled by hand over what is still owed, on random parts and shares.
@Suite("Money back settled by hand, against the rule")
struct ManualMoneyBackPropertyTests {
  /// Every part ticked is settled: what it was given is linked, what it lacks of what was still
  /// owed is a shortfall — never the money that came back earlier —, what nobody was given is
  /// the surplus. The money adds up both ways.
  @Test(arguments: Array(1...60) as [UInt64])
  func everyTickedPartIsSettledAndTheMoneyAddsUp(seed: UInt64) throws {
    var owing = Owing(seed: seed, rublesOnly: false)
    let parts = owing.parts.map(\.inRubles)
    var shares: [ReimbursementAllocation] = []
    for part in parts {
      let share = AmountE4(raw: Int64(owing.dice.int(0...Int(part.amountE4.raw))))
      shares.append(ReimbursementAllocation(partId: part.partId, amountE4: share))
    }
    let given = AmountE4.sum(shares.map(\.amountE4))
    let received = given + (owing.dice.chance(40) ? owing.dice.amount(upTo: 500) : .zero)
    let outcome = try ReimbursementResolver.resolve(
      reimbursementTxId: id(9), amountE4: received, closing: parts, allocation: shares,
      accountId: id(7))
    #expect(Set(outcome.closedPartIds) == Set(parts.map(\.partId)), "seed \(seed)")
    #expect(outcome.allocatedE4 + outcome.surplusE4 == received, "seed \(seed)")
    #expect(
      outcome.allocatedE4 + outcome.shortfallTotalE4
        == AmountE4.sum(owing.parts.map(\.remainingRubE4)), "seed \(seed)")
    for shortfall in outcome.shortfalls {
      let part = owing.parts.first { $0.partId == shortfall.partId }
      let share = shares.first { $0.partId == shortfall.partId }?.amountE4 ?? .zero
      #expect(shortfall.amountE4 == (part?.remainingRubE4 ?? .zero) - share, "seed \(seed)")
      #expect(shortfall.accountId == part?.accountId, "seed \(seed)")
    }
    if outcome.surplusE4.raw > 0 { #expect(outcome.surplus?.accountId == id(7), "seed \(seed)") }
  }

  /// A share above what is still owed on its part, or shares above the money, are refused.
  @Test(arguments: Array(1...60) as [UInt64])
  func tooMuchIsRefused(seed: UInt64) {
    let owing = Owing(seed: seed, rublesOnly: false)
    let parts = owing.parts.map(\.inRubles)
    guard let first = parts.first else { return }
    let over = [
      ReimbursementAllocation(partId: first.partId, amountE4: AmountE4(raw: first.amountE4.raw + 1))
    ]
    #expect(throws: ReimbursementError.allocationExceedsPart(first.partId)) {
      try ReimbursementResolver.resolve(
        reimbursementTxId: id(9), amountE4: AmountE4(raw: first.amountE4.raw + 1), closing: parts,
        allocation: over)
    }
    let whole = [ReimbursementAllocation(partId: first.partId, amountE4: first.amountE4)]
    #expect(throws: ReimbursementError.allocationExceedsAmount) {
      try ReimbursementResolver.resolve(
        reimbursementTxId: id(9), amountE4: AmountE4(raw: first.amountE4.raw - 1), closing: parts,
        allocation: whole)
    }
  }
}
