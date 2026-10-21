import CoreKit
import Foundation

/// An account as the update reads it, before any card exists.
public struct MigratingCardAccount: Hashable, Sendable {
  public var id: UUID
  public var name: String
  /// `nil`: a kind this build does not know.
  public var kind: PaymentMethodKind?
  public var archived: Bool

  public init(id: UUID, name: String, kind: PaymentMethodKind?, archived: Bool) {
    self.id = id
    self.name = name
    self.kind = kind
    self.archived = archived
  }
}

/// The cards the update makes, worked out before anything is written.
public struct CardsMigrationPlan: Hashable, Sendable {
  /// One card per live account of the kind «card», in the order the accounts were given.
  public var cards: [PaymentCard]
  /// Live card accounts whose name is empty once trimmed: the table refuses such a name.
  public var skipped: Int

  public init(cards: [PaymentCard], skipped: Int) {
    self.cards = cards
    self.skipped = skipped
  }
}

/// A card for every account of the kind «card» an older build left: the account was the card,
/// and now it holds one. A card says what paid and holds the cashback rules; the money stays on
/// the account, so nothing any figure reads changes.
///
/// Only live accounts get one — an archived account is not what the owner pays with — and only
/// of the kind «card»: an account of the kind «account» may have no card at all, and one made
/// later is the owner's to add.
public enum CardsMigration {
  /// The bytes the id of a card made by the update is XOR-ed with: «card» four times, ASCII.
  public static let idMask: [UInt8] = Array("cardcardcardcard".utf8)

  /// The id of the card the update makes for `account`: the account's bytes XOR `idMask`. The
  /// same on every run and every retry — so an update stopped and tried again makes what an
  /// untouched one makes —, never the account's own id, one per account.
  public static func cardId(forAccount account: UUID) -> UUID {
    MaskedId.xor(account, with: idMask)
  }

  /// A card for every live account of the kind «card»: named like it (trimmed), no other names,
  /// `sort` 0, not archived. An id given twice gets one card, the first.
  public static func plan(accounts: [MigratingCardAccount]) -> CardsMigrationPlan {
    var cards: [PaymentCard] = []
    var skipped = 0
    var seen: Set<UUID> = []
    for account in accounts where account.kind == .card && !account.archived {
      guard seen.insert(account.id).inserted else { continue }
      let name = account.name.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !name.isEmpty else {
        skipped += 1
        continue
      }
      cards.append(
        PaymentCard(id: cardId(forAccount: account.id), accountId: account.id, name: name))
    }
    return CardsMigrationPlan(cards: cards, skipped: skipped)
  }
}
