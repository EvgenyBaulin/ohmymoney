import CoreAccounting
import CoreKit
import Foundation
import Testing

@testable import CoreAnalytics

/// Analytics «Места»: the average check of a place.
@Suite("Places")
struct PlacesTests {
  /// A jacket of 10,000 at the shop with 4,000 of it returned was a check of 6,000: the average
  /// check is net of refunds, on the purchase's day, and the refund is no visit of its own.
  @Test func theAverageReceiptIsNetOfRefunds() throws {
    let entries = CashbackBook.entries.filter { [id(1006), id(1007)].contains($0.id) }
    let ledger = CashbackBook.ledger(entries: entries)
    let september = try #require(
      PlacesReport(ledger: ledger, period: .month(CashbackBook.september)).places.first)
    #expect(september.purchases == 1)
    #expect(september.averageReceipt == money("6000"))
    #expect(september.mySpending == money("6000"))
    let october = PlacesReport(ledger: ledger, period: .month(CashbackBook.october))
    #expect(october.places.isEmpty)
  }
}
