import CoreAccounting
import CoreKit
import Foundation
import Testing

@testable import CoreAnalytics

/// The Transactions filter by account and by card.
@Suite("Filtering by account and card")
struct EntryFilterTests {
  let ledger = CashbackBook.ledger()

  func ids(_ filter: EntryFilter) -> Set<UUID> { Set(filter.apply(to: ledger)) }

  /// An account finds the operations of each of its cards and of none.
  @Test func accountFilterIncludesItsCards() {
    let found = ids(EntryFilter(paymentMethodId: CashbackBook.tBank))
    #expect(found.contains(id(1001)) && found.contains(id(1010)) && found.contains(id(1014)))
    #expect(!found.contains(id(1012)) && !found.contains(id(1013)))
    #expect(found.count == 12)
  }

  @Test func cardFilterFindsOnlyThatCard() {
    #expect(ids(EntryFilter(cardId: CashbackBook.virtual)) == [id(1010), id(1011)])
    #expect(
      ids(EntryFilter(paymentMethodId: CashbackBook.tBank, cardId: CashbackBook.virtual)) == [
        id(1010), id(1011),
      ])
    #expect(
      ids(EntryFilter(paymentMethodId: CashbackBook.sber, cardId: CashbackBook.virtual)).isEmpty)
  }

  /// The search box finds an operation by the name of its card.
  @Test func theSearchFindsTheCardsName() {
    #expect(ids(EntryFilter(text: "virtual")) == [id(1010), id(1011)])
  }
}
