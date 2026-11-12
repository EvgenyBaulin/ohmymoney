import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation

/// How many bank cards the owner holds across all banks, against the legal cap on cards per
/// person, and which of them nothing has been paid with for a long time.
///
/// The cap is 20 cards per person in all banks together, in force from 1 September 2027. The
/// app counts the live cards of live accounts it knows; a card of someone else
/// («чужая карта») and cash are not the owner's cards.
public struct CardCountStatus: Hashable, Sendable {
  /// The cards the owner holds.
  public var count: Int
  public var limit: Int
  /// The day the cap comes into force.
  public var limitFrom: DateOnly
  /// Cards nothing was paid with for `unusedDays` days or more, the longest idle first; a card
  /// never used at all comes first.
  public var unused: [UUID]
  public var unusedDays: Int

  public init(count: Int, limit: Int, limitFrom: DateOnly, unused: [UUID], unusedDays: Int) {
    self.count = count
    self.limit = limit
    self.limitFrom = limitFrom
    self.unused = unused
    self.unusedDays = unusedDays
  }

  /// The cap is already in force.
  public func inForce(on today: DateOnly) -> Bool { today >= limitFrom }
  /// Cards still free under the cap; zero at or over it.
  public var left: Int { max(0, limit - count) }
  public var isOver: Bool { count > limit }
  public var isAtLimit: Bool { count >= limit }
  /// From `BankLimits.nearShareBp` of the cap: the line shows.
  public var isNear: Bool { count * 10_000 >= limit * BankLimits.nearShareBp }
}

public enum CardCount {
  public static let legalLimit = 20
  public static let limitFrom = DateOnly(year: 2027, month: 9, day: 1)

  /// The cards the owner holds: live, on a live account that is not cash and not someone
  /// else's card.
  public static func ownCards(dataset: Dataset) -> [PaymentCard] {
    let live = Set(
      dataset.paymentMethods.filter { !$0.archived && $0.kind != .cash && $0.borrowed == nil }
        .map(\.id))
    return dataset.cards.filter { !$0.archived && live.contains($0.accountId) }
  }

  public static func status(
    ledger: Ledger, today: DateOnly, unusedDays: Int? = nil
  ) -> CardCountStatus {
    let dataset = ledger.dataset
    let days = max(1, unusedDays ?? dataset.bankData.settings.forgottenDays)
    let cards = ownCards(dataset: dataset)
    var lastUse: [UUID: DateOnly] = [:]
    for entry in dataset.entries where !entry.transaction.isDeleted {
      guard let card = entry.transaction.cardId else { continue }
      let transaction = entry.transaction
      let day = ledger.calendar.day(of: transaction.occurredAt, recordedIn: transaction.timeZoneId)
      if lastUse[card].map({ day > $0 }) ?? true { lastUse[card] = day }
    }
    let idle: [(UUID, Int)] = cards.compactMap { card in
      guard let last = lastUse[card.id] else { return (card.id, Int.max) }
      let gone = last.days(to: today)
      return gone >= days ? (card.id, gone) : nil
    }
    let unused = idle.sorted { ($1.1, $0.0.uuidString) < ($0.1, $1.0.uuidString) }.map(\.0)
    return CardCountStatus(
      count: cards.count, limit: legalLimit, limitFrom: limitFrom, unused: unused,
      unusedDays: days)
  }
}
