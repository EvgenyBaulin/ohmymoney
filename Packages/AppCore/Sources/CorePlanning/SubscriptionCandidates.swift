import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation

/// Spending that looks like a subscription nobody has set up yet: the same description (or
/// the same place) charged about the same amount every week, month or year.
public struct SubscriptionCandidate: Hashable, Sendable, Identifiable {
  /// The normalized description the operations share, or `place:<id>` when they are
  /// grouped by place.
  public var key: String
  /// The place of the latest operation.
  public var placeId: UUID?
  /// The category of the latest operation.
  public var categoryId: UUID?
  /// The account and the card of the latest operation: a payment made of the candidate is paid
  /// from them. `nil` when it named none.
  public var paymentMethodId: UUID?
  public var cardId: UUID?
  public var currency: CurrencyCode
  /// The median amount, in `currency`.
  public var typicalAmount: AmountE4
  public var freq: Frequency
  public var occurrences: Int
  public var lastDay: DateOnly

  public init(
    key: String, placeId: UUID?, categoryId: UUID?, currency: CurrencyCode,
    typicalAmount: AmountE4, freq: Frequency, occurrences: Int, lastDay: DateOnly,
    paymentMethodId: UUID? = nil, cardId: UUID? = nil
  ) {
    self.key = key
    self.placeId = placeId
    self.categoryId = categoryId
    self.paymentMethodId = paymentMethodId
    self.cardId = cardId
    self.currency = currency
    self.typicalAmount = typicalAmount
    self.freq = freq
    self.occurrences = occurrences
    self.lastDay = lastDay
  }

  public var id: String { "\(key)|\(currency.code)" }
}

/// Finds subscription candidates in the history.
public enum SubscriptionCandidates {

  /// Gaps between two charges that fit each frequency, in days.
  static let gaps: [(freq: Frequency, days: ClosedRange<Int>)] = [
    (.monthly, 25...35), (.weekly, 6...8), (.yearly, 350...380),
  ]

  /// The candidates among the live expenses of the last `months` months (12 by default).
  ///
  /// * Only plain spending takes part: an expense the app did not write itself
  ///   (`external_id` links — «Mark as paid», shortfalls, reconciliations), not a debt
  ///   payment, not a goal contribution, not in a system category.
  /// * Operations are grouped by their normalized description — lowercased, digits
  ///   stripped, whitespace folded — or, without one, by their place; and by currency.
  /// * A group is a candidate when it has at least 3 operations (in 3 different months,
  ///   unless it is weekly), at least ⅔ of the gaps between them fit one frequency —
  ///   weekly 6–8 days, monthly 25–35, yearly 350–380 — the amounts spread by no more than
  ///   10 % of their median (max − min ≤ median ÷ 10), and it is still running: the latest
  ///   operation is no older than the longest gap of its frequency. Three yearly charges
  ///   need a window of more than two years, so the default window finds none.
  /// * A group that is already a payment — by name (normalized the same way), or by the
  ///   same category and currency with an amount within 10 % of the payment's price today —
  ///   is left out. So is every operation that pays a scheduled payment by matching one of its
  ///   due dates (`paidOperations`, `ScheduledMatches.operationIds`): it is that payment's
  ///   charge, as one «Провести» wrote is — a dollar subscription typed in rubles included,
  ///   which neither its currency nor its name would give away.
  public static func find(
    ledger: Ledger, book: PlanningBook, today: DateOnly, months: Int = 12,
    paidOperations: Set<UUID> = []
  ) -> [SubscriptionCandidate] {
    struct Item {
      let day: DateOnly
      let amount: AmountE4
      let categoryId: UUID?
      let placeId: UUID?
      let paymentMethodId: UUID?
      let cardId: UUID?
    }
    struct GroupKey: Hashable {
      let key: String
      let currency: CurrencyCode
    }

    var groups: [GroupKey: [Item]] = [:]
    let window = DayRange(today.adding(months: -max(1, months)), today)
    for row in ledger.rows(in: window) where row.isFirstPart && row.kind == .expense {
      guard row.link == nil, row.debtId == nil, row.creditDebtId == nil,
        !row.isGoalContribution, row.systemRole == nil,
        !paidOperations.contains(row.transactionId),
        let entry = ledger.entry(row.transactionId)
      else { continue }
      let transaction = entry.transaction
      let key: String
      if let text = normalized(transaction.note ?? entry.parts.first?.note) {
        key = text
      } else if let place = transaction.placeId {
        key = "place:\(place.uuidString.lowercased())"
      } else {
        continue
      }
      groups[GroupKey(key: key, currency: transaction.currency), default: []].append(
        Item(
          day: row.day, amount: transaction.amountE4, categoryId: row.categoryId,
          placeId: transaction.placeId, paymentMethodId: transaction.paymentMethodId,
          cardId: transaction.cardId))
    }

    let names = Set(book.scheduled.compactMap { normalized($0.name) })
    var result: [SubscriptionCandidate] = []
    for (group, items) in groups where items.count >= 3 {
      // The ledger is sorted by day already; the groups keep that order.
      let days = items.map(\.day)
      let intervals = zip(days, days.dropFirst()).map { $0.days(to: $1) }
      guard
        let fit = gaps.max(by: { left, right in
          intervals.filter { left.days.contains($0) }.count
            < intervals.filter { right.days.contains($0) }.count
        })
      else { continue }
      let fitting = intervals.filter { fit.days.contains($0) }.count
      guard fitting * 3 >= intervals.count * 2 else { continue }
      if fit.freq != .weekly, Set(days.map(\.monthKey)).count < 3 { continue }
      guard let last = items.last, last.day.days(to: today) <= fit.days.upperBound else {
        continue
      }

      let amounts = items.map(\.amount.decimal).sorted()
      guard let low = amounts.first, let high = amounts.last else { continue }
      let middle = amounts.count / 2
      let median =
        amounts.count % 2 == 1 ? amounts[middle] : (amounts[middle - 1] + amounts[middle]) / 2
      guard high - low <= median / 10 else { continue }
      let typical = SubscriptionMath.rounded(median)

      if names.contains(group.key) { continue }
      let known = book.scheduled.contains { payment in
        guard let category = payment.categoryId, category == last.categoryId,
          payment.currency == group.currency
        else { return false }
        let price = SubscriptionMath.price(of: payment, on: today, prices: book.prices)
        return (typical - price).magnitude.decimal <= price.decimal.magnitude / 10
      }
      if known { continue }

      result.append(
        SubscriptionCandidate(
          key: group.key, placeId: last.placeId, categoryId: last.categoryId,
          currency: group.currency, typicalAmount: typical, freq: fit.freq,
          occurrences: items.count, lastDay: last.day, paymentMethodId: last.paymentMethodId,
          cardId: last.cardId))
    }
    return result.sorted { left, right in
      if left.key != right.key { return left.key < right.key }
      return left.currency.code < right.currency.code
    }
  }

  /// Lowercased, digits stripped, runs of whitespace folded into one space and trimmed:
  /// «Netflix 09/2026» and «NETFLIX 10/2026» are the same thing. `nil` when nothing is left.
  public static func normalized(_ text: String?) -> String? {
    guard let text else { return nil }
    var result = ""
    var pendingSpace = false
    for character in text.lowercased() {
      if character.isNumber { continue }
      if character.isWhitespace {
        pendingSpace = !result.isEmpty
        continue
      }
      if pendingSpace {
        result.append(" ")
        pendingSpace = false
      }
      result.append(character)
    }
    return result.isEmpty ? nil : result
  }
}
