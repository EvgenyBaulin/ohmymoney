import CoreKit
import Foundation

/// The filters of the Transactions window, applied to the whole `Dataset` through
/// the ledger, off the main thread.
///
/// Operation-level criteria — period, type, place, account, card, text — look at the
/// operation. An account finds the operations of every card of it: a card is always a card of
/// the operation's own account. Part-level criteria — category, quality, «for whom», person,
/// event, reimbursement status — must all hold for **one** part: «bad groceries» finds a split
/// with a bad grocery part, not one with bad fees next to neutral groceries.
///
/// The period takes income by the month it is for when the period is made of whole months,
/// and by date for a custom span that cuts a month.
public struct EntryFilter: Hashable, Sendable {
  public var period: Period?
  public var kind: TransactionKind?
  /// A top-level category: its subcategories match too.
  public var categoryId: UUID?
  /// A subcategory: only itself matches.
  public var subcategoryId: UUID?
  /// The quality of the ledger row: stored, or the one the rules give.
  public var quality: Quality?
  public var forWhom: ForWhom?
  /// Whom a part was for (`for_person_id`) or who owes it (`debtor_person_id`).
  public var personId: UUID?
  public var placeId: UUID?
  public var eventId: UUID?
  /// An account: its operations, whatever card of it paid.
  public var paymentMethodId: UUID?
  /// A card: only the operations that name it.
  public var cardId: UUID?
  /// What became of a part of a purchase paid for somebody else. Only purchases match: a
  /// refund or any other kind never waits for money.
  public var reimbursementStatus: ReimbursementStatus?
  /// Words to find, each of them, anywhere in the description, notes, names and amount.
  public var text: String

  public init(
    period: Period? = nil, kind: TransactionKind? = nil, categoryId: UUID? = nil,
    subcategoryId: UUID? = nil, quality: Quality? = nil, forWhom: ForWhom? = nil,
    personId: UUID? = nil, placeId: UUID? = nil, eventId: UUID? = nil,
    paymentMethodId: UUID? = nil, reimbursementStatus: ReimbursementStatus? = nil,
    text: String = "", cardId: UUID? = nil
  ) {
    self.period = period
    self.kind = kind
    self.categoryId = categoryId
    self.subcategoryId = subcategoryId
    self.quality = quality
    self.forWhom = forWhom
    self.personId = personId
    self.placeId = placeId
    self.eventId = eventId
    self.paymentMethodId = paymentMethodId
    self.reimbursementStatus = reimbursementStatus
    self.text = text
    self.cardId = cardId
  }

  public static let none = EntryFilter()

  public var isEmpty: Bool { self == .none }

  private var hasPartCriteria: Bool {
    categoryId != nil || subcategoryId != nil || quality != nil || forWhom != nil
      || personId != nil || eventId != nil || reimbursementStatus != nil
  }

  /// The ids of the matching live operations, newest first.
  public func apply(to ledger: Ledger) -> [UUID] {
    let words = NameKey.fold(text).split(whereSeparator: \.isWhitespace).map(String.init)
    var matched: [UUID] = []
    var seen: Set<UUID> = []
    // Rows are oldest first, so walking them backwards gives newest first.
    for row in ledger.rows.reversed() where !seen.contains(row.transactionId) {
      guard matchesOperation(row), !hasPartCriteria || matchesPart(row) else {
        continue
      }
      if !words.isEmpty {
        guard let key = ledger.searchKey(of: row.transactionId),
          words.allSatisfy({ key.contains($0) })
        else { continue }
      }
      seen.insert(row.transactionId)
      matched.append(row.transactionId)
    }
    return matched
  }

  /// Criteria of the operation, read from any of its rows: they are the same on each.
  private func matchesOperation(_ row: LedgerRow) -> Bool {
    if let kind, row.kind != kind { return false }
    if let placeId, row.placeId != placeId { return false }
    if let paymentMethodId, row.paymentMethodId != paymentMethodId { return false }
    if let cardId, row.cardId != cardId { return false }
    if let period {
      if row.kind == .income && period.isWholeMonths {
        guard period.months.contains(row.month) else { return false }
      } else {
        guard period.range.contains(row.day) else { return false }
      }
    }
    return true
  }

  private func matchesPart(_ row: LedgerRow) -> Bool {
    if let subcategoryId {
      guard row.categoryId == subcategoryId else { return false }
    } else if let categoryId {
      guard row.categoryId == categoryId || row.rootCategoryId == categoryId else { return false }
    }
    if let quality, row.quality != quality { return false }
    if let forWhom, row.forWhom != forWhom { return false }
    if let personId, row.forPersonId != personId && row.debtorPersonId != personId { return false }
    if let eventId, row.eventId != eventId { return false }
    if let reimbursementStatus {
      // Only a purchase is waited for, returned or written off. A friend's ticket taken back
      // in a refund keeps the status its part was written with, but nobody waits for it:
      // the money went back to the card.
      guard row.kind == .expense, row.reimbursable,
        row.reimbursementStatus == reimbursementStatus
      else { return false }
    }
    return true
  }
}
