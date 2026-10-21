import CoreKit
import Foundation
import Testing

@testable import CoreAccounting

/// The month a cashback rule is read for is the month of the day the purchase was made on, in the
/// zone it was recorded in (0491), not the zone of the Mac that reads it.
@Suite("Cashback of a purchase made in another zone")
struct CashbackZoneTests {
  let fixture = CashbackFixture()

  /// 18:00 UTC on 30 September: still September in Moscow and in UTC, 02:00 on 1 October in Bali.
  private var lateInSeptember: Date {
    CalendarContext.utc.noon(of: DateOnly(iso: "2026-09-30")!).addingTimeInterval(6 * 3600)
  }

  private func coffee(zone: String?) -> TransactionEntry {
    var entry = fixture.operation(
      on: "09-30", parts: [(fixture.coffee, money(350))], account: fixture.tBank,
      card: fixture.black)
    entry.transaction.occurredAt = lateInSeptember
    entry.transaction.timeZoneId = zone
    return entry
  }

  /// Black: Cafes in September 10 %, Coffee always 3 %.
  @Test func aPurchaseOfTheLastEveningOfSeptemberAtHomeTakesSeptembersRule() throws {
    let expected = try #require(fixture.expected(coffee(zone: nil)))
    #expect(expected.rubles == money("35"))
  }

  @Test func theSameInstantInBaliIsOctobersAndTakesTheRuleOfOctober() throws {
    let expected = try #require(fixture.expected(coffee(zone: "Asia/Makassar")))
    #expect(expected.rubles == money("10.5"))
  }

  @Test func theZoneItWasRecordedInDecidesWhateverZoneReadsIt() throws {
    // The same Bali purchase read by a calendar set in Bali, or in Moscow, prices alike.
    let bali = CalendarContext(timeZone: TimeZone(identifier: "Asia/Makassar")!)
    let moscow = CalendarContext(timeZone: TimeZone(identifier: "Europe/Moscow")!)
    let entry = coffee(zone: "Asia/Makassar")
    for calendar in [bali, moscow] {
      let holder = CashbackHolders.holder(
        accountId: entry.transaction.paymentMethodId, cardId: entry.transaction.cardId,
        mainAccountId: fixture.sber)
      let expected = try #require(
        CashbackMath.expected(
          entry, holder: holder, book: fixture.book, tree: fixture.tree, calendar: calendar,
          refunded: { _ in .zero }))
      #expect(expected.rubles == money("10.5"))
    }
  }
}
