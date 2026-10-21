import CoreKit
import Foundation
import Testing

@testable import CoreAccounting

/// The rubles of money back add up: what the money came to in rubles is what reaches the parts
/// plus the rubles of the surplus, to the last ten-thousandth — the surplus is not the leftover
/// currency converted again, which misses by the rounding of every part's share. The drift of
/// rates between a purchase and its money back stays neither income nor spending.
@Suite("Money back in rubles")
struct MoneyBackRublesTests {
  let categories = StartingCategories()
  let anya = id(40)

  func owed(
    _ number: Int, rubles: String, on iso: String, currency: CurrencyCode = .rub,
    amount: String? = nil
  ) -> OwedPart {
    OwedPart(
      partId: id(number), transactionId: id(number + 1000), occurredAt: moment(iso),
      debtorPersonId: anya, categoryId: categories.groceries, forWhom: .friends,
      amountE4: money(amount ?? rubles), amountRubE4: money(rubles), currency: currency,
      rateProvisional: false, returnedRubE4: .zero, accountId: id(1))
  }

  func plan(
    _ received: String, _ currency: CurrencyCode, rubles: String, owed: [OwedPart]
  )
    -> MoneyBackPlan
  {
    MoneyBack.plan(
      received: money(received), currency: currency, receivedRub: money(rubles),
      rateProvisional: false, person: anya, owed: owed, openDebts: [])
  }

  /// 50 $ at 95 ₽ (4,750 ₽) against a part of 4,500 ₽: the part takes 47.3684 $, and the 2.6316 $
  /// over used to be converted again into 250.0020 ₽ — 4,750.0020 ₽ written for 4,750 ₽ received.
  @Test func dollarsOverARublePartLeaveExactlyTheRublesNotSpent() {
    let result = plan("50", .usd, rubles: "4750", owed: [owed(1, rubles: "4500", on: "2026-03-01")])
    #expect(result.closes == [id(1)])
    #expect(result.allocatedRubE4 == money(4500))
    #expect(result.surplus == money("2.6316"))
    #expect(result.surplusRub == money(250))
    #expect(result.allocatedRubE4 + result.surplusRub == money(4750))
  }

  /// Two ruble parts with kopecks against 20 $ at 97.30 ₽: the shares of both are rounded, and
  /// still the links and the surplus come to the 1,946 ₽ received.
  @Test func severalRoundedSharesStillAddUpToWhatCameIn() {
    let result = plan(
      "20", .usd, rubles: "1946",
      owed: [
        owed(1, rubles: "1000.01", on: "2026-03-01"), owed(2, rubles: "333.33", on: "2026-03-02"),
      ])
    #expect(result.closes == [id(1), id(2)])
    #expect(result.allocatedRubE4 == money("1333.34"))
    #expect(result.surplusRub == money("612.66"))
    #expect(result.allocatedRubE4 + result.surplusRub == money(1946))
  }

  /// A 50 $ part bought at 95 ₽ closed by 60 $ at 92 ₽: the part's link is its own 4,750 ₽, and
  /// the 10 $ over are 920 ₽ at the money back's rate. The 150 ₽ the dollar fell by in between is
  /// drift of the rate: not income in «Доплаты».
  @Test func theDriftOfASameCurrencyPartIsNotTurnedIntoIncome() {
    let result = plan(
      "60", .usd, rubles: "5520",
      owed: [owed(1, rubles: "4750", on: "2026-03-01", currency: .usd, amount: "50")])
    #expect(result.closes == [id(1)])
    #expect(result.allocatedRubE4 == money(4750))
    #expect(result.surplus == money(10))
    #expect(result.surplusRub == money(920))
  }

  /// In rubles there is nothing to round: the surplus is the rubles left, as before.
  @Test func rublesOverRublePartsAreTheRublesLeft() {
    let result = plan(
      "2000", .rub, rubles: "2000",
      owed: [
        owed(1, rubles: "999.99", on: "2026-03-01"), owed(2, rubles: "0.02", on: "2026-03-02"),
      ]
    )
    #expect(result.surplus == money("999.99"))
    #expect(result.surplusRub == money("999.99"))
  }
}

/// The part the money runs out on takes what is left of the rubles received.
@Suite("Money back running out")
struct MoneyBackRunningOutTests {
  let categories = StartingCategories()
  let anya = id(40)

  func owed(_ number: Int, rubles: Int, on iso: String) -> OwedPart {
    OwedPart(
      partId: id(number), transactionId: id(number + 1000), occurredAt: moment(iso),
      debtorPersonId: anya, categoryId: categories.groceries, forWhom: .friends,
      amountE4: money(rubles), amountRubE4: money(rubles), currency: .rub,
      rateProvisional: false, returnedRubE4: .zero, accountId: id(1))
  }

  /// 20 $ that came in as 1,850 ₽ (92.50 ₽ a dollar) against 1,000 ₽ and 1,500 ₽: the first
  /// closes with its 1,000 ₽, the second gets exactly the 850 ₽ left and waits for 650 ₽ — not
  /// 850.0010 ₽ and 649.9990 ₽, the rest of the dollars converted again.
  @Test func thePartTheMoneyRunsOutOnTakesTheRublesLeft() {
    let result = MoneyBack.plan(
      received: money(20), currency: .usd, receivedRub: money(1850), rateProvisional: false,
      person: anya,
      owed: [owed(1, rubles: 1000, on: "2026-03-01"), owed(2, rubles: 1500, on: "2026-03-02")],
      openDebts: [])
    #expect(result.closes == [id(1)])
    #expect(result.allocations.map(\.amountE4) == [money(1000), money(850)])
    #expect(result.stillOwed == [OwedRemainder(partId: id(2), remainingRubE4: money(650))])
    #expect(result.allocatedRubE4 == money(1850))
  }

  /// 10.5263 $ that came in as 1,000.0030 ₽ against 1,000 ₽ and 500 ₽: the dollars are exactly
  /// what the first part needs, so it closes with its own 1,000 ₽ and the second waits whole.
  /// The 0.0030 ₽ between is the drift of the rate, within the tolerance of the part: a link
  /// may not take more than the part's rubles, and so little is no income either.
  @Test func moneyEndingExactlyOnAPartsNeedLeavesOnlyTheDrift() {
    let result = MoneyBack.plan(
      received: money("10.5263"), currency: .usd, receivedRub: money("1000.003"),
      rateProvisional: false, person: anya,
      owed: [owed(1, rubles: 1000, on: "2026-03-01"), owed(2, rubles: 500, on: "2026-03-02")],
      openDebts: [])
    #expect(result.closes == [id(1)])
    #expect(result.allocations.map(\.amountE4) == [money(1000)])
    #expect(result.stillOwed == [OwedRemainder(partId: id(2), remainingRubE4: money(500))])
    #expect(result.surplus == .zero)
    #expect(result.surplusRub == .zero)
    let drift = money("1000.003") - result.allocatedRubE4
    #expect(drift == money("0.003"))
    #expect(drift <= MoneyBack.tolerance(partRub: money(1000), foreignInvolved: true))
  }
}

/// A plan that mixes a part bought in the money's own currency with a ruble part: the part in
/// the same currency is closed at its own rate — its link is its own rubles —, the ruble part at
/// the money's rate, and the surplus gets the rubles received less both at the money's rate.
@Suite("Money back over mixed parts")
struct MoneyBackMixedPartsTests {
  let categories = StartingCategories()
  let anya = id(40)

  func owed(
    _ number: Int, rubles: String, on iso: String, currency: CurrencyCode = .rub,
    amount: String? = nil
  ) -> OwedPart {
    OwedPart(
      partId: id(number), transactionId: id(number + 1000), occurredAt: moment(iso),
      debtorPersonId: anya, categoryId: categories.groceries, forWhom: .friends,
      amountE4: money(amount ?? rubles), amountRubE4: money(rubles), currency: currency,
      rateProvisional: false, returnedRubE4: .zero, accountId: id(1))
  }

  /// 10 $ bought at 92 ₽ (920 ₽) and a 1,000 ₽ dinner, closed by 30 $ at 95 ₽ (2,850 ₽): the
  /// dollar part closes with its 920 ₽, the dinner with its 1,000 ₽ (10.5263 $), and the
  /// 9.4737 $ over are 900 ₽ — 2,850 ₽ less 950 ₽ (the 10 $ at 95) and 1,000 ₽. The 30 ₽ the
  /// dollar rose by since the purchase are neither income nor spending.
  @Test func aDollarPartAndARublePartClosedByDollars() {
    let result = MoneyBack.plan(
      received: money(30), currency: .usd, receivedRub: money(2850), rateProvisional: false,
      person: anya,
      owed: [
        owed(1, rubles: "920", on: "2026-03-01", currency: .usd, amount: "10"),
        owed(2, rubles: "1000", on: "2026-03-02"),
      ],
      openDebts: [])
    #expect(result.closes == [id(1), id(2)])
    #expect(result.allocations.map(\.amountE4) == [money(920), money(1000)])
    #expect(result.surplus == money("9.4737"))
    #expect(result.surplusRub == money(900))
    // Received = the ruble parts' links + the dollar part at the money's rate + the surplus.
    #expect(money(1000) + money(950) + result.surplusRub == money(2850))
  }
}

/// Whatever the parts — dollars bought at their own rates, rubles — and whatever dollars come
/// back: when money is over, everything owed closes; a part bought in dollars links its own
/// rubles; and the rubles received are exactly the ruble parts' links, plus the dollar parts'
/// dollars at the money's rate, plus the surplus.
@Suite("Money back over mixed parts, any amounts")
struct MoneyBackMixedPartsPropertyTests {
  static let seeds: [UInt64] = Array(1...300)

  @Test(arguments: seeds)
  func theRublesReceivedAreTheLinksAtTheMoneysRateAndTheSurplus(seed: UInt64) {
    var dice = MoneyDice(seed: seed)
    let categories = StartingCategories()
    let person = id(40)
    let count = dice.int(2...4)
    let parts = (0..<count).map { index -> OwedPart in
      // At least one part of each kind.
      let inDollars = index == 0 ? true : index == 1 ? false : dice.chance(50)
      let amount = inDollars ? dice.amount(upTo: 150) : dice.amount(upTo: 9000)
      let rate = Decimal(dice.int(700_000...1_109_999)) / 10_000
      let rubles = inDollars ? MoneyDice.rounded(amount.decimal * rate) : amount
      return OwedPart(
        partId: id(index + 1), transactionId: id(index + 100),
        occurredAt: moment("2026-03-0\(index + 1)"), debtorPersonId: person,
        categoryId: categories.groceries, forWhom: .friends, amountE4: amount,
        amountRubE4: rubles, currency: inDollars ? .usd : .rub, rateProvisional: false,
        returnedRubE4: .zero, accountId: id(1))
    }
    let rate = Decimal(dice.int(700_000...1_109_999)) / 10_000
    let received = dice.fineAmount(upTo: 400)
    let receivedRub = MoneyDice.rounded(received.decimal * rate)
    let plan = MoneyBack.plan(
      received: received, currency: .usd, receivedRub: receivedRub, rateProvisional: false,
      person: person, owed: parts, openDebts: [])
    guard plan.refusal == nil, plan.surplus.raw > 0 else { return }
    // The money's own rate is what its rubles make of it, not the rate they were rounded from.
    let moneysRate = receivedRub.decimal / received.decimal

    #expect(Set(plan.closes) == Set(parts.map(\.partId)), "seed \(seed)")
    #expect(plan.stillOwed.isEmpty, "seed \(seed)")
    let links = Dictionary(uniqueKeysWithValues: plan.allocations.map { ($0.partId, $0.amountE4) })
    var atTheMoneysRate = AmountE4.zero
    for part in parts {
      if part.currency == .usd {
        #expect(links[part.partId] == part.amountRubE4, "seed \(seed): own rubles")
        atTheMoneysRate = atTheMoneysRate + MoneyDice.rounded(part.amountE4.decimal * moneysRate)
      } else {
        #expect(links[part.partId] == part.amountRubE4, "seed \(seed): the part whole")
        atTheMoneysRate = atTheMoneysRate + part.amountRubE4
      }
    }
    #expect(atTheMoneysRate + plan.surplusRub == receivedRub, "seed \(seed)")
    // The surplus in rubles is the dollars over at the money's rate, but for the rounding of
    // each part's share: the dollars a ruble part takes are rounded to a ten-thousandth, which
    // is at most half a ten-thousandth of a dollar at the rate, plus one for each conversion.
    let again = MoneyDice.rounded(plan.surplus.decimal * moneysRate)
    // NSDecimalNumber(decimal:), not `as NSDecimalNumber`: Linux has no bridging casts.
    let halfRate = NSDecimalNumber(decimal: rate / 2).int64Value
    let crumbs = Int64(parts.count + 1) * (halfRate + 2)
    #expect((plan.surplusRub - again).magnitude.raw <= crumbs, "seed \(seed): surplus")
  }
}

/// Money that ends exactly on what the owed parts need, in dollars, whatever the rate: every
/// part it covers closes, the next waits whole, and what the rubles received and the links
/// miss by is only the drift of the rate — within the tolerance of the part the money ended on.
@Suite("Money back ending on a part's need")
struct MoneyBackEndingOnANeedPropertyTests {
  static let seeds: [UInt64] = Array(1...200)

  @Test(arguments: seeds)
  func whatTheLinksMissIsOnlyTheDrift(seed: UInt64) {
    var dice = MoneyDice(seed: seed)
    let categories = StartingCategories()
    let person = id(40)
    let parts = (0..<dice.int(2...4)).map { index -> OwedPart in
      let amount = dice.amount(upTo: 9000)
      return OwedPart(
        partId: id(index + 1), transactionId: id(index + 100),
        occurredAt: moment("2026-03-0\(index + 1)"), debtorPersonId: person,
        categoryId: categories.groceries, forWhom: .friends, amountE4: amount,
        amountRubE4: amount, currency: .rub, rateProvisional: false, returnedRubE4: .zero,
        accountId: id(1))
    }
    let rate = Decimal(dice.int(700_000...1_109_999)) / 10_000
    let covered = dice.int(1...(parts.count - 1))
    // Exactly the dollars the first `covered` parts need, each rounded as the plan rounds it.
    let received = parts.prefix(covered).reduce(AmountE4.zero) {
      $0 + MoneyDice.rounded($1.amountRubE4.decimal / rate)
    }
    let receivedRub = MoneyDice.rounded(received.decimal * rate)
    let plan = MoneyBack.plan(
      received: received, currency: .usd, receivedRub: receivedRub, rateProvisional: false,
      person: person, owed: parts, openDebts: [])
    #expect(plan.refusal == nil, "seed \(seed)")
    #expect(plan.closes == parts.prefix(covered).map(\.partId), "seed \(seed)")
    #expect(plan.surplus == .zero, "seed \(seed)")
    #expect(
      plan.stillOwed.map(\.partId) == parts.dropFirst(covered).map(\.partId), "seed \(seed)")
    let tolerance = MoneyBack.tolerance(
      partRub: parts[covered - 1].amountRubE4, foreignInvolved: true)
    #expect((plan.allocatedRubE4 - receivedRub).magnitude <= tolerance, "seed \(seed)")
  }
}

/// Whatever the money and the parts, the rubles received are written once: when the money
/// runs out on a part, the links take exactly the rubles received; when money is over, the
/// links and the surplus do; only when every part closed and what is over is the drift of the
/// rate do the links miss the rubles received, by no more than that drift.
@Suite("Money back writes every ruble once")
struct MoneyBackRublesPropertyTests {
  static let seeds: [UInt64] = Array(1...300)

  @Test(arguments: seeds)
  func theRublesReceivedAreWrittenOnce(seed: UInt64) {
    var dice = MoneyDice(seed: seed)
    let categories = StartingCategories()
    let person = id(40)
    let parts = (0..<dice.int(1...4)).map { index -> OwedPart in
      let inDollars = dice.chance(40)
      let amount = inDollars ? dice.amount(upTo: 150) : dice.amount(upTo: 9000)
      let rate = Decimal(dice.int(700_000...1_109_999)) / 10_000
      let rubles = inDollars ? MoneyDice.rounded(amount.decimal * rate) : amount
      return OwedPart(
        partId: id(index + 1), transactionId: id(index + 100),
        occurredAt: moment("2026-03-0\(index + 1)"), debtorPersonId: person,
        categoryId: categories.groceries, forWhom: .friends, amountE4: amount,
        amountRubE4: rubles, currency: inDollars ? .usd : .rub, rateProvisional: false,
        returnedRubE4: .zero, accountId: id(1))
    }
    let inDollars = dice.chance(70)
    let received = inDollars ? dice.fineAmount(upTo: 300) : dice.amount(upTo: 20_000)
    let rate = Decimal(dice.int(700_000...1_109_999)) / 10_000
    let receivedRub = inDollars ? MoneyDice.rounded(received.decimal * rate) : received
    let currency: CurrencyCode = inDollars ? .usd : .rub
    let plan = MoneyBack.plan(
      received: received, currency: currency, receivedRub: receivedRub, rateProvisional: false,
      person: person, owed: parts, openDebts: [])
    guard plan.refusal == nil, !plan.allocations.isEmpty else { return }
    // Parts bought in the money's own currency are closed at their own rate: their rubles
    // drift from the money's, and that drift is neither income nor spending.
    guard !parts.contains(where: { $0.currency == currency && currency != .rub }) else { return }

    let links = plan.allocatedRubE4
    if plan.surplus.raw > 0 {
      #expect(links + plan.surplusRub == receivedRub, "seed \(seed)")
    } else if !plan.stillOwed.isEmpty {
      // The money ran out on a part: it takes the rubles left — unless the money ended exactly
      // on its need, and it closed with its own rubles; then the difference is drift of the
      // rate within its tolerance, as `moneyEndingExactlyOnAPartsNeedLeavesOnlyTheDrift` shows.
      let lastLinked = plan.allocations.last.flatMap { link in
        parts.first { $0.partId == link.partId }
      }
      if let lastLinked, plan.closes.contains(lastLinked.partId) {
        let drift = MoneyBack.tolerance(partRub: lastLinked.amountRubE4, foreignInvolved: true)
        #expect((links - receivedRub).magnitude <= drift, "seed \(seed)")
      } else {
        #expect(links == receivedRub, "seed \(seed)")
      }
    } else {
      let last = parts.max {
        ($0.occurredAt, $0.partId.uuidString) < ($1.occurredAt, $1.partId.uuidString)
      }
      let drift = MoneyBack.tolerance(partRub: last?.amountRubE4 ?? .zero, foreignInvolved: true)
      #expect((links - receivedRub).magnitude <= drift, "seed \(seed)")
    }
    for allocation in plan.allocations {
      #expect(allocation.amountE4.raw > 0, "seed \(seed)")
    }
  }
}
