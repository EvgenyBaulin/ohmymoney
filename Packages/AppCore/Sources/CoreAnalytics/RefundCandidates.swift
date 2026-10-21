import CoreAccounting
import CoreKit
import Foundation

/// A part of a purchase a refund can take money back from, with what is left of it.
public struct RefundCandidate: Identifiable, Hashable, Sendable {
  public var purchase: TransactionEntry
  public var part: TransactionPart
  /// What is left of the part to refund, in the purchase's currency.
  public var remaining: AmountE4
  /// What refunds already took back from it, in the purchase's currency.
  public var refunded: AmountE4

  public init(
    purchase: TransactionEntry, part: TransactionPart, remaining: AmountE4, refunded: AmountE4
  ) {
    self.purchase = purchase
    self.part = part
    self.remaining = remaining
    self.refunded = refunded
  }

  public var id: UUID { part.id }
  /// The purchase is split: the part is one of several, and the picker names it.
  public var isPartOfASplit: Bool { purchase.parts.count > 1 }
  public var currency: CurrencyCode { purchase.transaction.currency }
  public var occurredAt: Date { purchase.transaction.occurredAt }
  /// What the part is called: its own note, otherwise the purchase's.
  public var description: String? { part.note ?? purchase.transaction.note }
}

/// What the entry line said about a refund, to find the purchase it takes money back from:
/// its words, its place and its amount.
public struct RefundQuery: Hashable, Sendable {
  public var words: String?
  public var placeId: UUID?
  public var amount: AmountE4?
  /// The currency of `amount`: an amount only narrows purchases made in that currency. `nil`
  /// unless the owner said one — typed its code or picked it —: a currency the screen or the
  /// account only laid as a default says nothing, and the amount is then read in the currency
  /// of each purchase («возврат 7000 кроссовки» on a tenge screen finds the 7,000 ₽ sneakers).
  public var currency: CurrencyCode?
  /// The day of the refund: nothing bought after it is offered — money cannot come back for a
  /// purchase before it was made. It is not a word of the line, and «Показать все покупки»
  /// keeps it.
  public var latestDay: DateOnly?

  public init(
    words: String? = nil, placeId: UUID? = nil, amount: AmountE4? = nil,
    currency: CurrencyCode? = nil, latestDay: DateOnly? = nil
  ) {
    self.words = words
    self.placeId = placeId
    self.amount = amount
    self.currency = currency
    self.latestDay = latestDay
  }

  /// The line said nothing to narrow the purchases by.
  public var isEmpty: Bool {
    Self.stems(of: words).isEmpty && placeId == nil && (amount?.raw ?? 0) <= 0
  }

  /// The words of the line cut to their stems, so «кроссовки» finds «кроссовок»: lower case,
  /// «ё» as «е», punctuation off, the ending — up to two letters of a long word — dropped.
  static func stems(of text: String?) -> [String] {
    words(of: text).filter { $0.count >= 2 }.map { word in
      String(word.prefix(max(3, word.count - 2)))
    }
  }

  static func words(of text: String?) -> [String] {
    guard let text else { return [] }
    return
      text
      .lowercased()
      .replacingOccurrences(of: "ё", with: "е")
      .split { !$0.isLetter && !$0.isNumber }
      .map(String.init)
  }
}

/// The purchases a refund is picked from.
///
/// Only a part a refund can take back from is offered (`RefundRules.isRefundable`): a live
/// purchase of my own — nothing paid for somebody else, nothing bought on credit, no payment
/// on a debt, no contribution to a goal, no line of the books — and only while something of it
/// is left to refund. Newest first. By default the last 90 days; «Показать раньше» drops the
/// bound.
///
/// What the line said narrows them: every word of the line is in the part's words (its note,
/// the purchase's note, the place's name), the place is the purchase's, and the amount is no
/// more than what is left of a part in the same currency. When nothing fits all of that, the
/// narrowing is dropped and every purchase of the period is offered, rather than none.
public enum RefundCandidates {
  /// How far back the picker looks before «Показать раньше».
  public static let windowDays = 90

  /// The first day the picker offers by default: 90 days back from `today`, `today` included.
  public static func windowStart(today: DateOnly, calendar: CalendarContext) -> DateOnly {
    calendar.adding(days: -(windowDays - 1), to: today)
  }

  /// `index` is built over the same operations and knows what refunds already took back.
  /// `since` nil means every purchase ever made. `placeNames` lets a word of the line find a
  /// purchase by its place. `plans` — the instalment plans by id: a purchase bought on one is
  /// offered too (`RefundRules.isRefundable`, `creditDebt`).
  public static func list(
    entries: some Sequence<TransactionEntry>, index: RefundIndex, tree: CategoryTree,
    since: DateOnly?, calendar: CalendarContext, query: RefundQuery = RefundQuery(),
    placeNames: [UUID: String] = [:], plans: [UUID: Debt] = [:]
  ) -> (candidates: [RefundCandidate], narrowed: Bool) {
    var all: [RefundCandidate] = []
    for entry in entries {
      let transaction = entry.transaction
      guard transaction.kind == .expense, !transaction.isDeleted else { continue }
      let day = calendar.day(of: transaction.occurredAt)
      if let since, day < since { continue }
      if let latest = query.latestDay, day > latest { continue }
      let plan = transaction.creditDebtId.flatMap { plans[$0] }
      for part in entry.parts
      where RefundRules.isRefundable(part: part, in: entry, tree: tree, creditDebt: plan) {
        let left = RefundRules.remaining(part: part, index: index)
        guard left.raw > 0 else { continue }
        all.append(
          RefundCandidate(
            purchase: entry, part: part, remaining: left, refunded: index.refunded(part: part.id)))
      }
    }
    all.sort(by: newestFirst)
    guard !query.isEmpty else { return (all, false) }
    let fitting = all.filter { fits($0, query: query, placeNames: placeNames) }
    return fitting.isEmpty ? (all, false) : (fitting, true)
  }

  /// Newest purchase first; the parts of one purchase in their own order.
  static func newestFirst(_ left: RefundCandidate, _ right: RefundCandidate) -> Bool {
    if left.occurredAt != right.occurredAt { return left.occurredAt > right.occurredAt }
    if left.purchase.id != right.purchase.id {
      return left.purchase.id.uuidString < right.purchase.id.uuidString
    }
    let leftIndex = left.purchase.parts.firstIndex { $0.id == left.part.id } ?? 0
    let rightIndex = right.purchase.parts.firstIndex { $0.id == right.part.id } ?? 0
    return leftIndex < rightIndex
  }

  /// Whether the candidate answers everything the line said.
  static func fits(
    _ candidate: RefundCandidate, query: RefundQuery, placeNames: [UUID: String]
  ) -> Bool {
    if let place = query.placeId, candidate.purchase.transaction.placeId != place { return false }
    if let amount = query.amount, amount.raw > 0,
      query.currency == nil || query.currency == candidate.currency,
      amount > candidate.remaining
    {
      return false
    }
    let stems = RefundQuery.stems(of: query.words)
    guard !stems.isEmpty else { return true }
    let placeName = candidate.purchase.transaction.placeId.flatMap { placeNames[$0] }
    let haystack = RefundQuery.words(
      of: [candidate.part.note, candidate.purchase.transaction.note, placeName]
        .compactMap { $0 }.joined(separator: " "))
    return stems.allSatisfy { stem in haystack.contains { $0.hasPrefix(stem) } }
  }
}
