import CoreKit
import Foundation

/// What the update to the rules that belong to the account does with the rules the cards held.
///
/// Until now the rules lived on the cards, and an account with cards had none of its own. Now
/// they belong to the account and its cards follow them, so a rule that every card of an
/// account would have to repeat goes up to the account — and nothing else is moved: a rule is
/// never invented, never given to a card that did not have it, and never taken from a card that
/// differs from its sisters.
public enum CashbackRulesMigration {
  /// The rows the update moves and drops, by id.
  public struct Plan: Hashable, Sendable {
    /// Rules that stay as the same rows but lose their card: they are the account's now.
    public var movedUp: [UUID] = []
    /// Rules that go: the copies left on the other cards of an account whose cards held the same
    /// rules, and the rules on «Кредиты», which earns nothing.
    public var dropped: [UUID] = []
    /// How many of `dropped` are rules on «Кредиты».
    public var droppedOnLoans = 0

    public init() {}

    public var isEmpty: Bool { movedUp.isEmpty && dropped.isEmpty }
  }

  /// `cards` in the order the cards are listed (the first of equal cards is the one whose rules
  /// are kept); `loanCategoryIds` are «Кредиты» and every subcategory under it.
  ///
  /// An account that already has rules of its own is left alone. Otherwise, of its live cards
  /// that hold rules: one card gives its rules to the account; several cards that hold exactly
  /// the same rules give one copy to the account and lose theirs; cards that differ keep theirs.
  /// The rules of a card in the archive stay on it: its past purchases keep them.
  public static func plan(
    rules: [CashbackRule], cards: [PaymentCard], loanCategoryIds: Set<UUID>
  ) -> Plan {
    var plan = Plan()
    var kept: [CashbackRule] = []
    for rule in rules {
      if let category = rule.categoryId, loanCategoryIds.contains(category) {
        plan.dropped.append(rule.id)
        plan.droppedOnLoans += 1
      } else {
        kept.append(rule)
      }
    }

    let liveCards = cards.filter { !$0.archived }
    var accounts: [UUID] = []
    for card in liveCards where !accounts.contains(card.accountId) {
      accounts.append(card.accountId)
    }
    for account in accounts {
      guard !kept.contains(where: { $0.accountId == account && $0.cardId == nil }) else {
        continue
      }
      let ruled = liveCards.filter { $0.accountId == account }.compactMap {
        card -> (card: PaymentCard, rules: [CashbackRule])? in
        let held = kept.filter { $0.cardId == card.id }
        return held.isEmpty ? nil : (card, held)
      }
      guard let first = ruled.first else { continue }
      if ruled.count == 1 {
        plan.movedUp.append(contentsOf: first.rules.map(\.id))
      } else if ruled.dropFirst().allSatisfy({ Self.sameRules($0.rules, first.rules) }) {
        plan.movedUp.append(contentsOf: first.rules.map(\.id))
        plan.dropped.append(contentsOf: ruled.dropFirst().flatMap { $0.rules.map(\.id) })
      }
    }
    return plan
  }

  /// The same rules: the same months and categories at the same percents, whatever the rows.
  private static func sameRules(_ left: [CashbackRule], _ right: [CashbackRule]) -> Bool {
    func percents(_ rules: [CashbackRule]) -> [Slot: CashbackPercent] {
      Dictionary(
        rules.map { (Slot(month: $0.month, categoryId: $0.categoryId), $0.percent) },
        uniquingKeysWith: { first, _ in first })
    }
    return percents(left) == percents(right)
  }

  private struct Slot: Hashable {
    var month: MonthKey?
    var categoryId: UUID?
  }
}
