import CoreKit
import Foundation

/// Why one card cannot be merged into another.
public enum CardMergeIssue: Error, Hashable, Sendable {
  case notFound
  case sameCard
  /// The cards belong to different accounts: a card is merged only into another card of its own
  /// account, so no money moves and no count changes.
  case otherAccount
  /// Either card is in the archive.
  case archived
}

/// A merge of one card into another card of the same account, worked out before it is written.
public struct CardMergePlan: Hashable, Sendable {
  /// The card that goes away; what named it names `kept` after the merge.
  public var merged: PaymentCard
  /// The card that stays, with the merged card's name and other names among its other names.
  public var kept: PaymentCard
  /// The merged card's rules, now the kept card's, under their own ids.
  public var movedRules: [CashbackRule]
  /// The merged card's rules whose month and category the kept card already has a rule for:
  /// the kept card's rule stays and these go.
  public var droppedRules: [CashbackRule]

  public init(
    merged: PaymentCard, kept: PaymentCard, movedRules: [CashbackRule],
    droppedRules: [CashbackRule]
  ) {
    self.merged = merged
    self.kept = kept
    self.movedRules = movedRules
    self.droppedRules = droppedRules
  }
}

/// «Объединить с…» of a card. Only cards of one account merge: the money and the balance are the
/// account's, so the merge moves no money and leaves every count as it is. What named the merged
/// card — operations, in the bin too, and scheduled payments — names the kept card, its rules
/// become the kept card's where the kept card has no rule of the same month and category, and the
/// entry line reads its names as the kept card.
public enum CardMerge {
  /// Whether «Объединить с…» is offered for `card`: a live card whose account has another live
  /// card.
  public static func offered(for card: PaymentCard, cards: [PaymentCard]) -> Bool {
    !card.archived
      && cards.contains { $0.id != card.id && $0.accountId == card.accountId && !$0.archived }
  }

  /// The cards `card` can be merged into: the other live cards of its account, in list order.
  public static func targets(
    for card: PaymentCard, cards: [PaymentCard], locale: Locale = .current
  ) -> [PaymentCard] {
    CardRules.ordered(cards, of: card.accountId, locale: locale).filter { $0.id != card.id }
  }

  /// The merge of `mergedId` into `keptId`. `cards` and `rules` are all of them; `accounts`
  /// give the names of the account, which the kept card does not take as its own.
  public static func plan(
    merging mergedId: UUID, into keptId: UUID, cards: [PaymentCard], rules: [CashbackRule],
    accounts: [PaymentMethod]
  ) -> Result<CardMergePlan, CardMergeIssue> {
    guard let merged = cards.first(where: { $0.id == mergedId }),
      let target = cards.first(where: { $0.id == keptId })
    else { return .failure(.notFound) }
    guard merged.id != target.id else { return .failure(.sameCard) }
    guard merged.accountId == target.accountId else { return .failure(.otherAccount) }
    guard !merged.archived, !target.archived else { return .failure(.archived) }

    struct Slot: Hashable {
      var month: MonthKey?
      var categoryId: UUID?
    }
    let held = Set(
      rules.filter { $0.cardId == target.id }
        .map { Slot(month: $0.month, categoryId: $0.categoryId) })
    var moved: [CashbackRule] = []
    var dropped: [CashbackRule] = []
    for rule in rules where rule.cardId == merged.id {
      if held.contains(Slot(month: rule.month, categoryId: rule.categoryId)) {
        dropped.append(rule)
      } else {
        var rule = rule
        rule.cardId = target.id
        rule.accountId = target.accountId
        moved.append(rule)
      }
    }

    var kept = target
    let account = accounts.first { $0.id == target.accountId }
    // The kept card's own other names stay as they are; the merged card's are added after them,
    // but not a spelling the kept card or its account already answers to.
    var seen = Set(
      ([target.name] + target.aliases + (account.map { [$0.name] + $0.aliases } ?? []))
        .map(NameKey.fold))
    var aliases = target.aliases
    for name in [merged.name] + merged.aliases {
      let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
      let folded = NameKey.fold(trimmed)
      guard !folded.isEmpty, seen.insert(folded).inserted else { continue }
      aliases.append(trimmed)
    }
    kept.aliases = aliases
    return .success(
      CardMergePlan(merged: merged, kept: kept, movedRules: moved, droppedRules: dropped))
  }

  /// The account of a merge once it is made, when the merged card was its main one: the kept
  /// card is main then, in the same step. `nil` — the account does not change.
  public static func account(
    _ account: PaymentMethod, after plan: CardMergePlan
  ) -> PaymentMethod? {
    guard account.id == plan.kept.accountId, account.mainCardId == plan.merged.id else {
      return nil
    }
    var changed = account
    changed.mainCardId = plan.kept.id
    return changed
  }
}
