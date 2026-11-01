import Foundation

/// «Категория банка → ваша»: what a bank calls a category of its monthly choice, and the
/// owner's category it stands for (`bank_cashback_categories`). Each bank keeps its own table,
/// since one bank's «Супермаркеты» is not another's; one label may stand for several of the
/// owner's categories, each a row of its own.
public struct BankCategoryMapping: Identifiable, Hashable, Sendable, Codable {
  public var id: UUID
  public var bankId: UUID
  /// The bank's words, as the owner typed them.
  public var label: String
  /// A category or a subcategory of expenses; its subcategories go with it.
  public var categoryId: UUID

  public init(id: UUID = UUID(), bankId: UUID, label: String, categoryId: UUID) {
    self.id = id
    self.bankId = bankId
    self.label = label
    self.categoryId = categoryId
  }

  /// The label as it is compared: case, «ё» and spaces around do not matter.
  public static func normalized(_ label: String) -> String {
    label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      .replacingOccurrences(of: "ё", with: "е")
  }
}

/// One category a bank offers for a month (`cashback_offers`): its label and percent, on an
/// account or on one of its cards, and whether the owner took it. Taking an offer writes the
/// month's rule of the account (`CashbackRule` with `month`), which is what every figure of
/// cashback reads; the offer is the memory of what was on the table.
public struct CashbackOffer: Identifiable, Hashable, Sendable, Codable {
  public var id: UUID
  public var accountId: UUID
  /// `nil`: the account's own offer.
  public var cardId: UUID?
  public var month: MonthKey
  public var label: String
  public var percent: CashbackPercent
  public var chosen: Bool

  public init(
    id: UUID = UUID(), accountId: UUID, cardId: UUID? = nil, month: MonthKey, label: String,
    percent: CashbackPercent, chosen: Bool = false
  ) {
    self.id = id
    self.accountId = accountId
    self.cardId = cardId
    self.month = month
    self.label = label
    self.percent = percent
    self.chosen = chosen
  }
}
