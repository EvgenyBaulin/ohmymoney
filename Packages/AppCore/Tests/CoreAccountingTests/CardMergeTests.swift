import CoreKit
import Foundation
import Testing

@testable import CoreAccounting

/// «Объединить с…» of a card: only into another live card of the same account; the merged card's
/// rules go to the kept card except where the kept card already has a rule of the same month and
/// category; the kept card takes the merged card's names as other names.
@Suite("Merging a card into another card of its account")
struct CardMergeTests {
  let tBank = PaymentMethod(id: id(1), name: "T-Bank", kind: .card, aliases: ["tinkoff"])
  let sber = PaymentMethod(id: id(2), name: "Sber", kind: .card)
  let black = PaymentCard(id: id(11), accountId: id(1), name: "Black", aliases: ["чёрная"])
  let virtual = PaymentCard(id: id(12), accountId: id(1), name: "Virtual", aliases: ["virt"])
  let platinum = PaymentCard(id: id(13), accountId: id(1), name: "Platinum", sort: 0)
  let old = PaymentCard(id: id(14), accountId: id(1), name: "Old", archived: true)
  let sberCard = PaymentCard(id: id(21), accountId: id(2), name: "Sber")
  let cafe = id(31)
  let taxi = id(32)
  let september = MonthKey(year: 2026, month: 9)

  var accounts: [PaymentMethod] { [tBank, sber] }
  var cards: [PaymentCard] { [black, virtual, platinum, old, sberCard] }

  func percent(_ whole: Int64) -> CashbackPercent { CashbackPercent(e4: whole * 10_000)! }

  func rule(
    _ number: Int, card: UUID?, category: UUID?, month: MonthKey? = nil, _ whole: Int64
  ) -> CashbackRule {
    CashbackRule(
      id: id(100 + number), accountId: id(1), cardId: card, categoryId: category, month: month,
      percent: percent(whole))
  }

  @Test func aCardMergesOnlyIntoAnotherLiveCardOfItsAccount() {
    let targets = CardMerge.targets(for: virtual, cards: cards, locale: Locale(identifier: "en"))
    #expect(targets.map(\.id) == [black.id, platinum.id], "live cards of its account, in order")
    #expect(CardMerge.offered(for: virtual, cards: cards))
    #expect(!CardMerge.offered(for: sberCard, cards: cards), "Sber has no other live card")
    #expect(!CardMerge.offered(for: old, cards: cards), "an archived card is not merged")

    func issue(_ source: UUID, _ kept: UUID) -> CardMergeIssue? {
      if case .failure(let issue) = CardMerge.plan(
        merging: source, into: kept, cards: cards, rules: [], accounts: accounts)
      {
        return issue
      }
      return nil
    }
    #expect(issue(virtual.id, virtual.id) == .sameCard)
    #expect(issue(virtual.id, sberCard.id) == .otherAccount)
    #expect(issue(virtual.id, old.id) == .archived)
    #expect(issue(old.id, black.id) == .archived)
    #expect(issue(id(99), black.id) == .notFound)
    #expect(issue(virtual.id, id(99)) == .notFound)
    #expect(issue(virtual.id, black.id) == nil)
  }

  /// A rule of the merged card whose month and category the kept card already has gives way to
  /// the kept card's; every other rule moves to the kept card under its own id; the account's
  /// rules and the rules of other cards are not touched.
  @Test func theKeptCardsRuleWinsAKeyBothHave() throws {
    let rules = [
      rule(1, card: virtual.id, category: cafe, 10),  // kept has cafe always → dropped
      rule(2, card: virtual.id, category: cafe, month: september, 15),  // kept lacks → moves
      rule(3, card: virtual.id, category: nil, 2),  // everything else, kept lacks → moves
      rule(4, card: virtual.id, category: taxi, 5),  // kept has taxi in September only → moves
      rule(5, card: black.id, category: cafe, 7),
      rule(6, card: black.id, category: taxi, month: september, 4),
      rule(7, card: nil, category: cafe, 3),  // the account's own
      rule(8, card: platinum.id, category: cafe, 1),
    ]
    let plan = try CardMerge.plan(
      merging: virtual.id, into: black.id, cards: cards, rules: rules, accounts: accounts
    ).get()
    #expect(plan.merged == virtual)
    #expect(plan.droppedRules.map(\.id) == [id(101)])
    #expect(plan.movedRules.map(\.id) == [id(102), id(103), id(104)])
    #expect(plan.movedRules.allSatisfy { $0.cardId == black.id && $0.accountId == tBank.id })
    #expect(plan.movedRules.map(\.percent) == [percent(15), percent(2), percent(5)])
    #expect(plan.movedRules.map(\.month) == [september, nil, nil])

    // After the merge no two rules of one holder share a key, and the kept card holds the union.
    let untouched = rules.filter { $0.cardId != virtual.id }
    let after = untouched + plan.movedRules
    #expect(Set(after.map(\.key)).count == after.count)
    #expect(after.filter { $0.cardId == black.id }.count == 5)
    #expect(after.contains { $0.id == id(105) && $0.percent == percent(7) }, "the kept one wins")
  }

  /// The kept card is known by the merged card's name and other names too — but not by a
  /// spelling it already answers to, nor by its account's own names, which the entry line reads
  /// as the account.
  @Test func theKeptCardTakesTheMergedCardsNames() throws {
    let merged = PaymentCard(
      id: id(15), accountId: id(1), name: "Virtual",
      aliases: ["virt", " BLACK ", "Чёрная", "", "Tinkoff"])
    let plan = try CardMerge.plan(
      merging: merged.id, into: black.id, cards: [black, merged], rules: [], accounts: accounts
    ).get()
    #expect(plan.kept.id == black.id && plan.kept.name == "Black")
    #expect(plan.kept.aliases == ["чёрная", "Virtual", "virt"])
    #expect(plan.kept.sort == black.sort && !plan.kept.archived)

    let named = PaymentCard(id: id(16), accountId: id(1), name: "t-bank")
    let account = try CardMerge.plan(
      merging: named.id, into: black.id, cards: [black, named], rules: [], accounts: accounts
    ).get()
    #expect(account.kept.aliases == ["чёрная"], "the card called like its account adds no name")
  }
}
