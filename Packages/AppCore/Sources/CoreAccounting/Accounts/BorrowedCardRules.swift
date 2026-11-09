import CoreKit
import Foundation

/// Where money moved from someone else's card to an account of the owner is written.
public enum BorrowedIncomeCategoryChoice: Hashable, Sendable {
  /// A live income category of the owner's.
  case existing(UUID)
  /// The category is in the archive — itself, its parent, or both: it comes back live in the
  /// change that writes the income, the parent first. `parent` is named only when the parent is
  /// in the archive.
  case revive(UUID, parent: UUID?)
  /// No such category: a top-level income category is made, named by `nameKey` in the interface
  /// language.
  case create(nameKey: String)
}

/// Why an account cannot be saved as someone else's card.
public enum BorrowedCardIssue: Hashable, Sendable {
  /// The main account takes every operation that names none: it is the owner's own money.
  case main
  /// A credit card is the owner's debt to his bank.
  case creditCard
  /// A deposit or savings account earns the owner interest on his balance.
  case deposit
  /// The safety cushion is the owner's money.
  case cushion
}

/// What money of the owner moved onto someone else's card is. He says it when he moves it; the
/// card keeps no balance, so the answer is what the money was for.
public enum BorrowedTransferPurpose: String, Hashable, Sendable, CaseIterable {
  /// Money for his own spending with the card: a transfer, not spending — what he spends with the
  /// card is counted as his own when he spends it, so counting the advance too would count it
  /// twice. The default.
  case advance
  /// Money given away: spending of the owner's, in a category of gifts.
  case gift
  /// Money given back on what he owes the person whose card it is: a payment of that debt.
  case debtRepayment
}

/// The rules of someone else's card (`BorrowedCardTerms`): the money of a parent's, a partner's
/// or a company card the owner pays with.
///
/// * Its spending is the owner's: nothing here touches «Мои расходы», analytics, categories or
///   limits — they read the operations as they read any other.
/// * It keeps no balance (`PaymentMethod.hasBalance`), so it takes nothing from «Можно тратить»
///   or the free sum, and is in no total, group, capital or forecast.
/// * Money moved from it to an account of the owner is income from the person whose card it is,
///   written as an income operation on that account (`incomeDraft`), never as a transfer.
/// * Money of the owner moved onto it is an advance, a gift or a repayment of a debt, as he says
///   (`BorrowedTransferPurpose`); an advance is the default and is not spending.
public enum BorrowedCardRules {
  /// The name of the default income category, in the strings.
  public static let defaultIncomeNameKey = "borrowed.category.familyHelp"

  /// The names the default income category is found by, in either language, in any case.
  private static let defaultIncomeNames: Set<String> = ["помощь семьи", "family help"]

  /// Why `account` cannot be someone else's card, or `nil` when it can. Its money would have to
  /// be the owner's for any of these.
  public static func issue(_ account: PaymentMethod) -> BorrowedCardIssue? {
    guard account.isBorrowed else { return nil }
    if account.isDefault { return .main }
    if account.isCreditCard { return .creditCard }
    if account.interest != nil { return .deposit }
    if account.cushion { return .cushion }
    return nil
  }

  /// The category a transfer from `card` to an account of the owner is written in, the first
  /// that applies:
  ///
  /// 1. the one the card names, while it and its parent are live income categories;
  /// 2. a live top-level income category named «Помощь семьи» or "Family help", in any case;
  /// 3. the one the card names, when it or its parent is in the archive: both come back;
  /// 4. a top-level income category of that name in the archive: it comes back;
  /// 5. a new top-level income category of that name.
  ///
  /// Only an income category the owner files things in counts — never one of the app's, and
  /// never an expense category of the same name («Помощь родным» / "Family help" of the starter
  /// set is spending).
  public static func incomeCategory(
    for card: PaymentMethod, categories: [CoreKit.Category]
  ) -> BorrowedIncomeCategoryChoice {
    let tree = CategoryTree(categories)
    func isOwnersIncome(_ category: CoreKit.Category) -> Bool {
      category.kind == .income && tree.systemRole(of: category.id) == nil
    }
    func isLive(_ category: CoreKit.Category) -> Bool {
      isOwnersIncome(category) && !category.archived
        && !(tree.parent(of: category.id)?.archived ?? false)
    }
    func revival(_ category: CoreKit.Category) -> BorrowedIncomeCategoryChoice {
      let parent = tree.parent(of: category.id)
      return .revive(category.id, parent: parent?.archived == true ? parent?.id : nil)
    }
    let chosen = card.borrowed?.incomeCategoryId.flatMap { tree[$0] }
    if let chosen, isLive(chosen) { return .existing(chosen.id) }
    let named = categories.filter { category in
      category.parentId == nil && isOwnersIncome(category)
        && defaultIncomeNames.contains(
          category.name.trimmingCharacters(in: .whitespaces).lowercased())
    }
    .sorted { left, right in
      left.sort != right.sort ? left.sort < right.sort : left.id.uuidString < right.id.uuidString
    }
    if let live = named.first(where: isLive) { return .existing(live.id) }
    if let chosen, isOwnersIncome(chosen) { return revival(chosen) }
    if let archived = named.first { return revival(archived) }
    return .create(nameKey: defaultIncomeNameKey)
  }

  /// The names the category of gifts is found by, in either language, in any case.
  private static let giftNames: Set<String> = ["подарки", "gifts"]

  /// The name of the category a gift is written in when there is none, in the strings.
  public static let giftNameKey = "borrowed.category.gifts"

  /// The category a gift to the person whose card it is is written in: a live top-level expense
  /// category named «Подарки» or "Gifts", else one from the archive, else a new one.
  public static func giftCategory(categories: [CoreKit.Category]) -> BorrowedIncomeCategoryChoice {
    let tree = CategoryTree(categories)
    let named = categories.filter { category in
      category.parentId == nil && category.kind == .expense
        && tree.systemRole(of: category.id) == nil
        && giftNames.contains(category.name.trimmingCharacters(in: .whitespaces).lowercased())
    }
    .sorted { left, right in
      left.sort != right.sort ? left.sort < right.sort : left.id.uuidString < right.id.uuidString
    }
    if let live = named.first(where: { !$0.archived }) { return .existing(live.id) }
    if let archived = named.first { return .revive(archived.id, parent: nil) }
    return .create(nameKey: giftNameKey)
  }

  /// The debt a repayment to the person whose card it is pays: an open debt the owner owes that
  /// person, in the currency that left his account; the first by name when there are several.
  /// `nil` when there is none.
  public static func debtToRepay(
    card: PaymentMethod, currency: CurrencyCode, debts: [Debt]
  ) -> Debt? {
    guard let person = card.borrowed?.personId else { return nil }
    return debts.filter {
      $0.deletedAt == nil && !$0.closed && $0.direction == .iOwe && $0.personId == person
        && $0.currency == currency
    }
    .min { left, right in
      left.name != right.name ? left.name < right.name : left.id.uuidString < right.id.uuidString
    }
  }

  /// A gift as the spending it is: what left, in its currency, from the account it left, in
  /// `categoryId`, with the note of the transfer.
  public static func giftDraft(transfer: Transfer, categoryId: UUID) -> TransactionDraft {
    var draft = TransactionDraft(
      kind: .expense, occurredAt: transfer.occurredAt, currency: transfer.fromCurrency,
      amount: transfer.fromAmountE4, note: transfer.note, paymentMethodId: transfer.fromAccountId)
    draft.normalizeSinglePart()
    draft.parts[0].categoryId = categoryId
    draft.parts[0].categorySource = .system
    return draft
  }

  /// Whether a transfer from `fromAccountId` is income from someone else's card rather than a
  /// transfer: the money leaves a card that is not the owner's.
  public static func isIncome(fromAccountId: UUID?, accounts: [PaymentMethod]) -> Bool {
    guard let fromAccountId else { return false }
    return accounts.first { $0.id == fromAccountId }?.isBorrowed ?? false
  }

  /// Money moved from someone else's card to an account of the owner, as the income it is: what
  /// arrived, in its currency, on the account it arrived at, at the moment of the transfer, in
  /// `categoryId`, with the note of the transfer. An income has no rating.
  public static func incomeDraft(transfer: Transfer, categoryId: UUID) -> TransactionDraft {
    var draft = TransactionDraft(
      kind: .income, occurredAt: transfer.occurredAt, currency: transfer.toCurrency,
      amount: transfer.toAmountE4, note: transfer.note, paymentMethodId: transfer.toAccountId)
    draft.normalizeSinglePart()
    draft.parts[0].categoryId = categoryId
    draft.parts[0].categorySource = .system
    return draft
  }
}
