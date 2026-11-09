import Foundation

/// Someone else's money the owner pays with: a parent's card, a partner's, a company card
/// (`payment_methods.borrowed*`). The terms make an account «чужая карта»:
///
/// * What is bought with it is the owner's spending like any other — «Мои расходы», analytics,
///   categories and limits count it, with the cut «с чужой карты <имя>».
/// * Its money is not the owner's: the account has no balance at all — nothing is counted on it,
///   it is in no total, no group, no capital and no forecast, and it never takes from «Можно
///   тратить» or the free sum.
/// * Money moved from it to an account of the owner is income from the person whose card it is,
///   in `incomeCategoryId`; money of the owner is never moved onto it.
public struct BorrowedCardTerms: Hashable, Sendable, Codable {
  /// Whose card it is: a person of the reference book; `nil`: not said.
  public var personId: UUID?
  /// The income category a transfer from the card to an account of the owner is written in;
  /// `nil`: the default one, «Помощь семьи».
  public var incomeCategoryId: UUID?

  public init(personId: UUID? = nil, incomeCategoryId: UUID? = nil) {
    self.personId = personId
    self.incomeCategoryId = incomeCategoryId
  }
}

extension PaymentMethod {
  /// Someone else's card: its spending is the owner's, its balance is not his money.
  public var isBorrowed: Bool { borrowed != nil }

  /// Whether the account keeps a balance of the owner's money: every account but someone else's
  /// card. Without one it has no count, no «не сверен» and no place in any total.
  public var hasBalance: Bool { borrowed == nil }
}
