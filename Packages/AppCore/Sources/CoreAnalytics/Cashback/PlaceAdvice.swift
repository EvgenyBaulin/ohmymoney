import CoreAccounting
import CoreKit
import Foundation

/// «Здесь лучше платить …»: the card that earns the most for what the owner buys at a marked
/// place, as the cashback rules and this month's ceilings stand today.
public struct PlaceAdvice: Hashable, Sendable {
  public var markId: UUID
  /// What the price was worked out for.
  public var categoryId: UUID?
  public var best: CashbackCandidate
  public var bestPercent: CashbackPercent
  /// The card the owner already pays with at the place is the best one.
  public var isUsualCard: Bool
}

public enum PlaceAdvisor {
  /// The size of a purchase the cards are compared on when the place has no history of its own.
  public static let referenceAmountRub = AmountE4(whole: 1_000)

  /// The advice for `mark`, or `nil` when it names neither a place the books know nor a category,
  /// when no card has a rule for it, or when the best card earns nothing there. A place's
  /// history says what is bought there (the category and the merchant code most often seen, the
  /// card most often used); a mark's own category stands in for a place with no history.
  /// Hidden accounts are neither compared nor named.
  public static func advice(
    for mark: PlaceMark, ledger: Ledger, today: DateOnly, hidden: Set<UUID> = []
  ) -> PlaceAdvice? {
    let dataset = ledger.dataset
    let book = CashbackRuleBook(
      rules: dataset.cashbackRules, tree: ledger.tree, cards: dataset.cards,
      accounts: dataset.paymentMethods, mappings: dataset.cashbackChoice.mappings)
    guard !book.isEmpty else { return nil }
    let mainId = CashbackAdvisor.mainAccount(dataset)

    var categories: [UUID: Int] = [:]
    var codes: [String: Int] = [:]
    var holders: [CashbackHolder: Int] = [:]
    var seen = Set<UUID>()
    if let placeId = mark.placeId {
      for row in ledger.rows
      where row.isFirstPart && row.kind == .expense
        && row.placeId == placeId
      {
        guard seen.insert(row.transactionId).inserted,
          let transaction = ledger.entry(row.transactionId)?.transaction
        else { continue }
        if let category = row.categoryId { categories[category, default: 0] += 1 }
        if let code = MerchantCode.normalized(transaction.mcc) { codes[code, default: 0] += 1 }
        if let held = CashbackAdvisor.holder(of: transaction, mainId: mainId) {
          holders[held, default: 0] += 1
        }
      }
    }
    let category = mostOften(categories) ?? mark.categoryId
    guard let category else { return nil }

    let candidates = CashbackAdvisor.candidates(
      accounts: dataset.paymentMethods, cards: dataset.cards, book: book, hidden: hidden)
    let tracker = CashbackHints.monthTracker(
      ledger: ledger, book: book, today: today, mainId: mainId)
    let options = CashbackAdvisor.options(
      categoryId: category, amountRub: referenceAmountRub, month: today.monthKey,
      candidates: candidates, book: book, tracker: tracker, mcc: mostOften(codes))
    guard let best = options.first, best.percent > .zero else { return nil }
    let usual = mostOften(holders)
    return PlaceAdvice(
      markId: mark.id, categoryId: category, best: best.candidate, bestPercent: best.percent,
      isUsualCard: usual == best.candidate.holder)
  }

  /// The key seen most often; ties go to the smallest description so the result never wobbles.
  private static func mostOften<Key: Hashable>(_ counts: [Key: Int]) -> Key? {
    counts.max { left, right in
      left.value != right.value
        ? left.value < right.value : "\(left.key)" > "\(right.key)"
    }?.key
  }
}
