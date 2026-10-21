import CoreKit
import Foundation
import Testing

@testable import CoreAccounting

/// Random debts of a person in rubles, dollars, euros and tenge — some partly back already, some
/// on a rate still provisional — and random money back in any of those currencies, at a rate of
/// its own that may itself be provisional; the person may also owe on «Мне должны» debts.
private struct OwingBook {
  static let kzt = CurrencyCode("KZT")
  var dice: MoneyDice
  let person = id(40)
  let stranger = id(41)
  var parts: [OwedPart] = []
  var debts: [Debt] = []

  /// Rubles for one unit, at random: dollars 70–111, euros 80–120, tenge 0.15–0.25.
  mutating func rate(of currency: CurrencyCode) -> Decimal {
    switch currency {
    case .rub: 1
    case .usd: Decimal(dice.int(700_000...1_109_999)) / 10_000
    case .eur: Decimal(dice.int(800_000...1_199_999)) / 10_000
    default: Decimal(dice.int(1500...2500)) / 10_000
    }
  }

  mutating func amount(in currency: CurrencyCode) -> AmountE4 {
    switch currency {
    case .rub: dice.amount(upTo: 9000)
    case .usd, .eur: dice.amount(upTo: 120)
    default: dice.amount(upTo: 50_000)
    }
  }

  init(seed: UInt64, provisional: Int = 20, nothingOwed: Int = 10) {
    dice = MoneyDice(seed: seed)
    let start = moment("2026-02-01")
    let currencies = [CurrencyCode.rub, .usd, .eur, Self.kzt]
    let owesNothing = dice.chance(nothingOwed)
    for index in 0..<dice.int(1...6) {
      let currency = dice.pick(currencies)
      let amount = amount(in: currency)
      let rub = currency == .rub ? amount : MoneyDice.rounded(amount.decimal * rate(of: currency))
      let returned: AmountE4 =
        owesNothing
        ? rub : dice.chance(30) ? AmountE4(raw: Int64(dice.int(0...Int(rub.raw - 1)))) : .zero
      parts.append(
        OwedPart(
          partId: id(100 + index), transactionId: id(1100 + index),
          occurredAt: start.addingTimeInterval(TimeInterval(dice.below(40) * 86_400)),
          debtorPersonId: person, forWhom: .friends, amountE4: amount, amountRubE4: rub,
          currency: currency, rateProvisional: dice.chance(provisional), returnedRubE4: returned,
          accountId: id(1)))
    }
    for index in 0..<dice.int(0...3) {
      debts.append(
        Debt(
          id: id(200 + index), direction: dice.pick([.owedToMe, .owedToMe, .iOwe]),
          type: .personal, name: dice.pick(["Loan to a friend", "Rent share", "Car"]),
          personId: dice.pick([person, person, stranger]), closed: dice.chance(30)))
    }
  }

  /// Money back in a random currency at a random rate of its own.
  mutating func money() -> (received: AmountE4, currency: CurrencyCode, rub: AmountE4) {
    let currency = dice.pick([CurrencyCode.rub, .usd, .eur, Self.kzt])
    let received =
      switch currency {
      case .rub: dice.amount(upTo: 30_000)
      case .usd, .eur: dice.amount(upTo: 400)
      default: dice.amount(upTo: 150_000)
      }
    let rub = currency == .rub ? received : MoneyDice.rounded(received.decimal * rate(of: currency))
    return (received, currency, rub)
  }
}

@Suite("Money back in any currency, against a model of the rule")
struct MoneyBackCurrenciesPropertyTests {
  static let seeds: [UInt64] = Array(1...150)

  /// Whatever the currencies of the parts and of the money — a third currency, tenge worth less
  /// than a ruble —, whatever is provisional and whatever the person owes on debts, the plan is
  /// the one the rule gives: the same links, parts closed and left, surplus, parts passed over,
  /// and the same refusal.
  @Test(arguments: seeds)
  func thePlanIsWhatTheRuleSaysInAnyCurrency(seed: UInt64) {
    var book = OwingBook(seed: seed)
    let money = book.money()
    let provisional = book.dice.chance(10)
    let plan = MoneyBack.plan(
      received: money.received, currency: money.currency, receivedRub: money.rub,
      rateProvisional: provisional, person: book.person, owed: book.parts, openDebts: book.debts)
    let model = MoneyBackRuleModel.plan(
      received: money.received, currency: money.currency, receivedRub: money.rub,
      rateProvisional: provisional, person: book.person, owed: book.parts, openDebts: book.debts)
    #expect(MoneyBackRuleModel(plan) == model, "seed \(seed)")
    #expect(plan.currency == money.currency, "seed \(seed)")
  }

  /// Nothing is written for a refused plan; otherwise no link is above what was left of its part,
  /// every link is above zero, a closed part missed its rubles by no more than the drift, a part
  /// passed over for its rate gets nothing, and money is over only when no part waits.
  @Test(arguments: seeds)
  func whatIsWrittenKeepsToTheRule(seed: UInt64) {
    var book = OwingBook(seed: seed)
    let money = book.money()
    let plan = MoneyBack.plan(
      received: money.received, currency: money.currency, receivedRub: money.rub,
      rateProvisional: false, person: book.person, owed: book.parts, openDebts: book.debts)
    if plan.refusal != nil {
      #expect(plan.allocations.isEmpty && plan.closes.isEmpty, "seed \(seed)")
      #expect(plan.surplus == .zero, "seed \(seed)")
      return
    }
    let passed = Set(plan.skippedProvisional)
    #expect(
      passed
        == Set(book.parts.filter { $0.rateProvisional && $0.remainingRubE4.raw > 0 }.map(\.partId)))
    for allocation in plan.allocations {
      guard let part = book.parts.first(where: { $0.partId == allocation.partId }) else {
        Issue.record("seed \(seed): a link to a part nobody owes")
        continue
      }
      #expect(!passed.contains(part.partId), "seed \(seed)")
      #expect(allocation.amountE4.raw > 0, "seed \(seed)")
      #expect(allocation.amountE4 <= part.remainingRubE4, "seed \(seed)")
      if plan.closes.contains(part.partId) {
        let foreign = part.currency != .rub || money.currency != .rub
        #expect(
          part.remainingRubE4 - allocation.amountE4
            <= MoneyBackRuleModel.drift(part.amountRubE4, foreign: foreign), "seed \(seed)")
      }
    }
    if plan.surplus.raw > 0 {
      #expect(Set(plan.stillOwed.map(\.partId)).isEmpty, "seed \(seed)")
      #expect(plan.surplusRub.raw > 0, "seed \(seed)")
    }
  }

  /// A person who owes no part: money back from them is a repayment of their own open «Мне
  /// должны» debt when there is one — never another person's, never a closed one, never one I
  /// owe —, else income.
  @Test(arguments: seeds)
  func aPersonWhoOwesNoPartIsSentToTheirDebtOrToIncome(seed: UInt64) {
    var book = OwingBook(seed: seed, nothingOwed: 100)
    let money = book.money()
    let plan = MoneyBack.plan(
      received: money.received, currency: money.currency, receivedRub: money.rub,
      rateProvisional: book.dice.chance(50), person: book.person, owed: book.parts,
      openDebts: book.debts)
    let theirs = book.debts.filter {
      $0.personId == book.person && $0.direction == .owedToMe && !$0.closed
    }
    if let debt = theirs.min(by: { ($0.name, $0.id.uuidString) < ($1.name, $1.id.uuidString) }) {
      #expect(plan.refusal == .owesOnDebt(debt.id), "seed \(seed)")
    } else {
      #expect(plan.refusal == .owesNothing, "seed \(seed)")
    }
    #expect(plan.allocations.isEmpty, "seed \(seed)")
  }

  /// Tenge back for parts bought in tenge — a tenge worth less than a ruble — close them by their
  /// own amount at any rate of the money back, with nothing open and nothing over.
  @Test(arguments: Array(1...60) as [UInt64])
  func tengeBackForTengePartsCloseThemAtAnyRate(seed: UInt64) {
    var dice = MoneyDice(seed: seed)
    var parts: [OwedPart] = []
    for index in 0..<dice.int(1...5) {
      let amount = dice.amount(upTo: 50_000)
      let rub = MoneyDice.rounded(amount.decimal * Decimal(dice.int(1500...2500)) / 10_000)
      parts.append(
        OwedPart(
          partId: id(100 + index), transactionId: id(1100 + index),
          occurredAt: moment("2026-02-01").addingTimeInterval(TimeInterval(index * 86_400)),
          debtorPersonId: id(40), amountE4: amount, amountRubE4: rub, currency: OwingBook.kzt))
    }
    let owed = AmountE4.sum(parts.map(\.amountE4))
    let rate = Decimal(dice.int(1000...3000)) / 10_000
    let plan = MoneyBack.plan(
      received: owed, currency: OwingBook.kzt, receivedRub: MoneyDice.rounded(owed.decimal * rate),
      rateProvisional: false, person: id(40), owed: parts, openDebts: [])
    #expect(Set(plan.closes) == Set(parts.map(\.partId)), "seed \(seed)")
    #expect(plan.stillOwed.isEmpty && plan.surplus == .zero, "seed \(seed)")
    #expect(plan.allocatedRubE4 == AmountE4.sum(parts.map(\.amountRubE4)), "seed \(seed)")
  }

  /// A part of 10 dollars (900 ₽) of which 899.998 ₽ already came back owes less than half a cent:
  /// nothing in dollars. Money back of 5 dollars for an older part of 5 dollars and this one
  /// closes both — the older by its 5 dollars, this one by its crumbs of rubles, though no dollar
  /// is left for it.
  @Test func aPartWithNothingLeftInTheMoneysCurrencyClosesWithItsCrumbs() {
    let older = OwedPart(
      partId: id(100), transactionId: id(1100), occurredAt: moment("2026-02-01"),
      debtorPersonId: id(40), amountE4: money(5), amountRubE4: money(450), currency: .usd)
    let crumbs = OwedPart(
      partId: id(101), transactionId: id(1101), occurredAt: moment("2026-02-02"),
      debtorPersonId: id(40), amountE4: money(10), amountRubE4: money(900), currency: .usd,
      returnedRubE4: money("899.998"))
    let plan = MoneyBack.plan(
      received: money(5), currency: .usd, receivedRub: money(460), rateProvisional: false,
      person: id(40), owed: [older, crumbs], openDebts: [])
    #expect(plan.closes == [id(100), id(101)])
    #expect(
      plan.allocations == [
        ReimbursementAllocation(partId: id(100), amountE4: money(450)),
        ReimbursementAllocation(partId: id(101), amountE4: money("0.002")),
      ])
    #expect(plan.stillOwed.isEmpty && plan.surplus == .zero)
  }

  /// Euros back for a part bought in dollars go through rubles at the money back's own rate:
  /// 50 € at 100 ₽ is 5 000 ₽ against a part of 55.56 $ worth 5 000 ₽ — it closes exactly, and
  /// nothing is over.
  @Test func eurosForADollarPartGoThroughRubles() {
    let part = OwedPart(
      partId: id(100), transactionId: id(1100), occurredAt: moment("2026-02-01"),
      debtorPersonId: id(40), amountE4: money("55.56"), amountRubE4: money(5000), currency: .usd)
    let plan = MoneyBack.plan(
      received: money(50), currency: .eur, receivedRub: money(5000), rateProvisional: false,
      person: id(40), owed: [part], openDebts: [])
    #expect(plan.closes == [id(100)])
    #expect(plan.allocations == [ReimbursementAllocation(partId: id(100), amountE4: money(5000))])
    #expect(plan.surplus == .zero && plan.stillOwed.isEmpty)
  }

  /// Money that runs out just short of a part — or just over what it needs of it — in any
  /// currency: the plan is the model's. So a part missing its rubles by less than the drift
  /// closes with no shortfall, and one missing more stays open with the rest.
  @Test(arguments: seeds)
  func moneyRunningOutNearAPartIsWhatTheRuleSays(seed: UInt64) {
    let near = nearAPart(seed: seed)
    #expect(MoneyBackRuleModel(near.plan) == near.model, "seed \(seed)")
  }

  struct NearAPart {
    var plan: MoneyBackPlan
    var model: MoneyBackRuleModel
    var parts: [OwedPart]
    /// The money is more than every part needs.
    var over: Bool
  }

  /// Money back of a random currency and rate that covers the first parts of a random book
  /// whole and ends a few rubles either side of what the next part needs.
  func nearAPart(seed: UInt64) -> NearAPart {
    var book = OwingBook(seed: seed, provisional: 0, nothingOwed: 0)
    let currency = book.dice.pick([CurrencyCode.rub, .usd, .eur, OwingBook.kzt])
    let rate = book.rate(of: currency)
    // The rate is fixed first; the needs follow from it, whatever the money turns out to be.
    let unit = AmountE4(whole: 1000)
    let unitRub = currency == .rub ? unit : MoneyDice.rounded(unit.decimal * rate)
    let parts = book.parts.filter { $0.remainingRubE4.raw > 0 }.sorted(
      by: MyExpensesRule.oldestFirst)
    let needs = parts.map {
      MoneyBackRuleModel.need(of: $0, currency: currency, received: unit, receivedRub: unitRub)
    }
    let stop = book.dice.below(parts.count)
    let upTo = AmountE4.sum(needs.prefix(stop + 1))
    // A few rubles either side of the end of that part, in the money's currency.
    let rubles = Decimal(book.dice.int(-8000...2000)) / 100
    let shift = currency == .rub ? rubles : rubles / rate
    let received = max(AmountE4(raw: 1), MoneyDice.rounded(upTo.decimal + shift))
    let receivedRub =
      currency == .rub
      ? received : MoneyDice.rounded(received.decimal * unitRub.decimal / unit.decimal)
    let plan = MoneyBack.plan(
      received: received, currency: currency, receivedRub: receivedRub, rateProvisional: false,
      person: book.person, owed: book.parts, openDebts: [])
    let model = MoneyBackRuleModel.plan(
      received: received, currency: currency, receivedRub: receivedRub, rateProvisional: false,
      person: book.person, owed: book.parts, openDebts: [])
    return NearAPart(
      plan: plan, model: model, parts: book.parts, over: received > AmountE4.sum(needs))
  }

  /// Those books close a part within the drift, leave one open just over it, and turn money a
  /// few rubles over everything into income, each more than once — the corners the rule is
  /// about are reached.
  @Test func moneyRunningOutNearAPartReachesTheDrift() {
    var closedWithin = 0
    var leftJustOver = 0
    var overIsIncome = 0
    for seed in Self.seeds {
      let near = nearAPart(seed: seed)
      for allocation in near.plan.allocations {
        guard let part = near.parts.first(where: { $0.partId == allocation.partId }) else {
          continue
        }
        let rest = part.remainingRubE4 - allocation.amountE4
        if near.plan.closes.contains(part.partId), rest.raw > 0 { closedWithin += 1 }
        if !near.plan.closes.contains(part.partId), rest <= AmountE4(whole: 100) {
          leftJustOver += 1
        }
      }
      if near.over, near.plan.surplus.raw > 0 { overIsIncome += 1 }
    }
    #expect(
      closedWithin > 5 && leftJustOver > 5 && overIsIncome > 5,
      "\(closedWithin), \(leftJustOver), \(overIsIncome)")
  }

  /// The random books reach every refusal, parts passed over for their rate, tenge and a third
  /// currency — so the properties above are not green for want of cases.
  @Test func theRandomBooksReachEveryCase() {
    var refusals: Set<String> = []
    var passedOver = 0
    var third = 0
    var surplus = 0
    for seed in Self.seeds {
      var book = OwingBook(seed: seed)
      let money = book.money()
      let provisional = book.dice.chance(10)
      let plan = MoneyBack.plan(
        received: money.received, currency: money.currency, receivedRub: money.rub,
        rateProvisional: provisional, person: book.person, owed: book.parts,
        openDebts: book.debts)
      refusals.insert(plan.refusal.map { "\($0)" } ?? "none")
      if !plan.skippedProvisional.isEmpty, plan.refusal == nil { passedOver += 1 }
      if plan.surplus.raw > 0 { surplus += 1 }
      if plan.refusal == nil,
        book.parts.contains(where: { $0.currency != money.currency && $0.currency != .rub }),
        money.currency != .rub
      {
        third += 1
      }
    }
    for wanted in [
      "none", "owesNothing", "onlyProvisional", "provisionalRate", "provisionalPartsOwed",
    ] {
      #expect(refusals.contains { $0.hasPrefix(wanted) }, "\(wanted) never happens: \(refusals)")
    }
    #expect(refusals.contains { $0.hasPrefix("owesOnDebt") }, "\(refusals)")
    #expect(passedOver > 5 && third > 5 && surplus > 5, "\(passedOver), \(third), \(surplus)")
  }
}
