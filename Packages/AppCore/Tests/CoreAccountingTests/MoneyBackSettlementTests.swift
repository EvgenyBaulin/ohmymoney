import CoreKit
import Foundation
import Testing

@testable import CoreAccounting

/// Money that already came back, balanced again when the part it closed changes its rubles.
@Suite("Money back when the part changes its rubles")
struct MoneyBackSettlementTests {
  let back = id(9)
  let link = id(90)
  let shortfall = id(91)

  func moneyBack(
    _ rubles: String, surplus: String = "0", currency: CurrencyCode = .rub,
    amount: String? = nil, at iso: String = "2026-09-10", id moneyBackId: UUID? = nil
  ) -> MoneyBackSettlement.MoneyBackState {
    MoneyBackSettlement.MoneyBackState(
      id: moneyBackId ?? back, occurredAt: moment(iso), currency: currency,
      amountE4: money(amount ?? rubles), amountRubE4: money(rubles), surplusRubE4: money(surplus))
  }

  func part(
    _ rubles: String, status: ReimbursementStatus, linked: String, own: String? = nil,
    foreign: Bool = true
  ) -> MoneyBackSettlement.PartState {
    MoneyBackSettlement.PartState(
      partId: id(1), amountRubE4: money(rubles), status: status, foreignInvolved: foreign,
      links: [MoneyBackSettlement.Link(id: link, moneyBackId: back, amountRubE4: money(linked))],
      companions: own.map { [MoneyBackSettlement.Companion(id: shortfall, amountRubE4: money($0))] }
        ?? [])
  }

  /// 20 $ at the bank's 92 = 1,840 ₽, 2,000 ₽ came back — link 1,840, surplus 160. The card
  /// was charged 1,800 ₽ (rate 90): the link is 1,800, the surplus 200.
  @Test func aCheaperClosedPartGivesItsRublesToTheSurplus() {
    let outcome = MoneyBackSettlement.settle(
      part("1800", status: .returned, linked: "1840"),
      moneyBacks: [back: moneyBack("2000", surplus: "160")])
    #expect(outcome.status == .returned)
    #expect(outcome.links == [link: money(1800)])
    #expect(outcome.surplusRub == [back: money(200)])
    #expect(outcome.companions.isEmpty)
  }

  /// the same, charged 1,900 ₽ (95): the link takes 60 from the surplus.
  @Test func aDearerClosedPartTakesFromTheSurplus() {
    let outcome = MoneyBackSettlement.settle(
      part("1900", status: .returned, linked: "1840"),
      moneyBacks: [back: moneyBack("2000", surplus: "160")])
    #expect(outcome.status == .returned)
    #expect(outcome.links == [link: money(1900)])
    #expect(outcome.surplusRub == [back: money(100)])
  }

  /// exactly 1,840 ₽ came back. Charged 1,900 ₽: 60 missing is over the tolerance of
  /// 19 ₽ — the part waits again. Charged 1,850 ₽: 10 ₽ is drift, it stays closed.
  @Test func aDearerPartWithoutASurplusWaitsAgainBeyondTheDrift() {
    let beyond = MoneyBackSettlement.settle(
      part("1900", status: .returned, linked: "1840"), moneyBacks: [back: moneyBack("1840")])
    #expect(beyond.status == .expected)
    #expect(beyond.links.isEmpty && beyond.surplusRub.isEmpty && beyond.companions.isEmpty)
    let within = MoneyBackSettlement.settle(
      part("1850", status: .returned, linked: "1840"), moneyBacks: [back: moneyBack("1840")])
    #expect(within.isUnchanged)
  }

  /// 3.33 $ at a provisional 80.10 = 266.73 ₽, 266 ₽ came back, 0.73 ₽ waits. Refined to
  /// 79.60 (265.07 ₽): closed, 0.93 ₽ of income. Refined to 79.95 (266.23 ₽): closed, the
  /// 0.23 ₽ is drift and nothing is written.
  @Test func aRefinedPartTheMoneyNowCoversCloses() {
    let covered = MoneyBackSettlement.settle(
      part("265.07", status: .expected, linked: "266"), moneyBacks: [back: moneyBack("266")])
    #expect(covered.status == .returned)
    #expect(covered.links == [link: money("265.07")])
    #expect(covered.surplusRub == [back: money("0.93")])
    let drift = MoneyBackSettlement.settle(
      part("266.23", status: .expected, linked: "266"), moneyBacks: [back: moneyBack("266")])
    #expect(drift.status == .returned)
    #expect(drift.links.isEmpty && drift.surplusRub.isEmpty)
    // Still more than the tolerance away: it waits with the rest, nothing written.
    let waits = MoneyBackSettlement.settle(
      part("280", status: .expected, linked: "266"), moneyBacks: [back: moneyBack("266")])
    #expect(waits.isUnchanged)
  }

  /// 10 $ at 100 = 1,000 ₽ closed by hand with 900 ₽ back and a shortfall of 100 ₽.
  @Test func aHandSettledPartMovesItsShortfall() {
    let moneyBacks = [back: moneyBack("900")]
    func at(_ rubles: String) -> MoneyBackSettlement.Outcome {
      MoneyBackSettlement.settle(
        part(rubles, status: .returned, linked: "900", own: "100"), moneyBacks: moneyBacks)
    }
    #expect(at("1010").isUnchanged)  // 10 ₽ within 10.10 ₽: drift
    #expect(at("1020").companions == [shortfall: money(120)])
    #expect(at("1020").status == .returned)
    #expect(at("950").companions == [shortfall: money(50)])
    #expect(at("950").links.isEmpty)
    let cheaper = at("850")
    #expect(cheaper.companions == [shortfall: .zero])
    #expect(cheaper.links == [link: money(850)])
    #expect(cheaper.surplusRub == [back: money(50)])
  }

  /// Two money backs: what the part no longer needs goes to the newer one first.
  @Test func theNewestMoneyBackIsTouchedFirst() {
    let older = id(8)
    let olderLink = id(80)
    let state = MoneyBackSettlement.PartState(
      partId: id(1), amountRubE4: money(900), status: .returned, foreignInvolved: false,
      links: [
        MoneyBackSettlement.Link(id: olderLink, moneyBackId: older, amountRubE4: money(600)),
        MoneyBackSettlement.Link(id: link, moneyBackId: back, amountRubE4: money(400)),
      ])
    let outcome = MoneyBackSettlement.settle(
      state,
      moneyBacks: [
        older: moneyBack("600", at: "2026-09-05", id: older),
        back: moneyBack("400", at: "2026-09-10"),
      ])
    #expect(outcome.links == [link: money(300)])
    #expect(outcome.surplusRub == [back: money(100)])
  }

  @Test func aWrittenOffPartOrOneWithoutLinksIsLeftAlone() {
    #expect(
      MoneyBackSettlement.settle(
        part("100", status: .writtenOff, linked: "500"), moneyBacks: [back: moneyBack("500")]
      ).isUnchanged)
    let bare = MoneyBackSettlement.PartState(
      partId: id(1), amountRubE4: money(100), status: .expected, foreignInvolved: false, links: [])
    #expect(MoneyBackSettlement.settle(bare, moneyBacks: [:]).isUnchanged)
  }

  /// 20 $ bought at 92 (1,840 ₽) and exactly 20 $ given back at 93: the dollars closed the
  /// dollars, and the rubles between the two days are drift. Charged 1,900 ₽ or 1,800 ₽ later,
  /// the part stays closed with its link at its rubles, and nothing is owed or earned; half of
  /// it back in dollars stays half of it.
  @Test func aPartClosedInItsOwnCurrencyStaysClosedAtAnyRate() {
    let dollars = moneyBack("1860", currency: .usd, amount: "20")
    func at(
      _ rubles: String, status: ReimbursementStatus = .returned, linked: String = "1840"
    ) -> MoneyBackSettlement.Outcome {
      MoneyBackSettlement.settle(
        MoneyBackSettlement.PartState(
          partId: id(1), amountRubE4: money(rubles), status: status, foreignInvolved: true,
          links: [
            MoneyBackSettlement.Link(id: link, moneyBackId: back, amountRubE4: money(linked))
          ],
          currency: .usd, previousAmountRubE4: money(1840)),
        moneyBacks: [back: dollars])
    }
    let dearer = at("1900")
    #expect(dearer.status == .returned)
    #expect(dearer.links == [link: money(1900)])
    #expect(dearer.surplusRub.isEmpty && dearer.companions.isEmpty)
    let cheaper = at("1800")
    #expect(cheaper.status == .returned)
    #expect(cheaper.links == [link: money(1800)])
    #expect(cheaper.surplusRub.isEmpty)
    let half = at("1900", status: .expected, linked: "920")
    #expect(half.status == .expected)
    #expect(half.links == [link: money(950)])
    #expect(half.surplusRub.isEmpty)
    // Rubles not known from before: the dollars' link is left as it is.
    let unknown = MoneyBackSettlement.settle(
      MoneyBackSettlement.PartState(
        partId: id(1), amountRubE4: money(1900), status: .returned, foreignInvolved: true,
        links: [MoneyBackSettlement.Link(id: link, moneyBackId: back, amountRubE4: money(1840))],
        currency: .usd),
      moneyBacks: [back: dollars])
    #expect(unknown.isUnchanged)
  }

  /// 20 $ at 92 = 1,840 ₽: 10 $ came back (920 ₽ of the part) and 1,000 ₽ (920 ₽, 80 ₽ over).
  /// Charged 1,900 ₽: the dollars cover their half, 950 ₽; the rubles take the 30 ₽ they now
  /// miss from their surplus — link 950, surplus 50.
  @Test func onlyMoneyInAnotherCurrencyIsBalancedAgain() {
    let rubles = id(8)
    let rubleLink = id(80)
    let state = MoneyBackSettlement.PartState(
      partId: id(1), amountRubE4: money(1900), status: .returned, foreignInvolved: true,
      links: [
        MoneyBackSettlement.Link(id: link, moneyBackId: back, amountRubE4: money(920)),
        MoneyBackSettlement.Link(id: rubleLink, moneyBackId: rubles, amountRubE4: money(920)),
      ],
      currency: .usd, previousAmountRubE4: money(1840))
    let outcome = MoneyBackSettlement.settle(
      state,
      moneyBacks: [
        back: moneyBack("930", currency: .usd, amount: "10", at: "2026-09-05"),
        rubles: moneyBack("1000", surplus: "80", at: "2026-09-10", id: rubles),
      ])
    #expect(outcome.status == .returned)
    #expect(outcome.links == [link: money(950), rubleLink: money(950)])
    #expect(outcome.surplusRub == [rubles: money(50)])
  }

  /// A surplus in dollars is the rubles over at the money back's own rate.
  @Test func aSurplusIsInTheMoneyBacksCurrency() {
    let dollars = moneyBack("2200", currency: .usd, amount: "22")
    #expect(MoneyBackSettlement.surplusAmount(rub: money(200), of: dollars) == money(2))
    #expect(MoneyBackSettlement.surplusAmount(rub: money(200), of: moneyBack("2000")) == money(200))
  }
}

/// Whatever the part now costs, the money that came back is written once.
@Suite("Money back balanced again keeps every ruble")
struct MoneyBackSettlementPropertyTests {
  static let seeds: [UInt64] = Array(1...300)

  @Test(arguments: seeds)
  func theMoneyThatCameBackIsWrittenOnce(seed: UInt64) {
    var dice = MoneyDice(seed: seed)
    let count = dice.int(1...3)
    var moneyBacks: [UUID: MoneyBackSettlement.MoneyBackState] = [:]
    var links: [MoneyBackSettlement.Link] = []
    for index in 0..<count {
      let linked = dice.amount(upTo: 3000)
      let surplus = dice.chance(50) ? dice.amount(upTo: 500) : .zero
      let backId = id(100 + index)
      moneyBacks[backId] = MoneyBackSettlement.MoneyBackState(
        id: backId, occurredAt: moment("2026-09-0\(index + 1)"), currency: .rub,
        amountE4: linked + surplus, amountRubE4: linked + surplus, surplusRubE4: surplus)
      links.append(
        MoneyBackSettlement.Link(id: id(200 + index), moneyBackId: backId, amountRubE4: linked))
    }
    let covered = AmountE4.sum(links.map(\.amountRubE4))
    let status: ReimbursementStatus = dice.chance(60) ? .returned : .expected
    // Only a closed part can have been settled by hand.
    let handSettled = status == .returned && dice.chance(30)
    let own = handSettled ? dice.amount(upTo: 800) : AmountE4.zero
    let price = max(
      AmountE4(raw: 1), covered + own + AmountE4(raw: Int64(dice.int(-2_000_000...2_000_000))))
    let foreign = dice.chance(50)
    let part = MoneyBackSettlement.PartState(
      partId: id(1), amountRubE4: price, status: status, foreignInvolved: foreign, links: links,
      companions: handSettled
        ? [MoneyBackSettlement.Companion(id: id(300), amountRubE4: own)] : [])
    let outcome = MoneyBackSettlement.settle(part, moneyBacks: moneyBacks)

    for link in links {
      let before = link.amountRubE4 + (moneyBacks[link.moneyBackId]?.surplusRubE4 ?? .zero)
      let after =
        (outcome.links[link.id] ?? link.amountRubE4)
        + (outcome.surplusRub[link.moneyBackId]
          ?? moneyBacks[link.moneyBackId]?.surplusRubE4 ?? .zero)
      #expect(before == after, "seed \(seed): money back \(link.moneyBackId)")
      #expect((outcome.links[link.id] ?? link.amountRubE4).raw >= 0, "seed \(seed)")
    }
    for surplus in outcome.surplusRub.values {
      #expect(surplus.raw >= 0, "seed \(seed)")
    }
    let linkedAfter = AmountE4.sum(links.map { outcome.links[$0.id] ?? $0.amountRubE4 })
    let ownAfter = AmountE4.sum(
      part.companions.map { outcome.companions[$0.id] ?? $0.amountRubE4 })
    #expect(ownAfter.raw >= 0, "seed \(seed)")
    if outcome.status == .returned {
      // Links never cover more than the part; a closed part misses its rubles by no more than
      // the drift unless the owner's own spending on it takes the rest.
      #expect(linkedAfter <= max(price, covered), "seed \(seed)")
      let tolerance = MoneyBack.tolerance(partRub: price, foreignInvolved: foreign)
      #expect(
        (price - linkedAfter - ownAfter).magnitude <= tolerance || ownAfter.raw > 0,
        "seed \(seed)")
      if price <= covered + own { #expect(linkedAfter + ownAfter == price, "seed \(seed)") }
    }
  }
}
