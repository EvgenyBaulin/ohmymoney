import CoreKit
import Foundation
import Testing

@testable import CoreAccounting

/// Where the cashback of a month stands against the day its bank pays it.
@Suite("The payout day of a cashback")
struct CashbackScheduleTests {
  let september = MonthKey(year: 2026, month: 9)

  func status(
    _ payout: CashbackPayout?, today: String, expected: Int = 280, received: Int = 0
  ) -> CashbackPayoutStatus {
    CashbackSchedule.status(
      of: september, payout: payout, today: DateOnly(iso: today)!, expectedRub: money(expected),
      receivedRub: money(received), calendar: .utc)
  }

  @Test func anAccountThatHasNotSaidIsNotTold() {
    #expect(status(nil, today: "2026-10-20") == .unknown)
  }

  @Test func aBankThatPaysWithThePurchase() {
    #expect(status(.immediately, today: "2026-09-15") == .immediately)
    #expect(status(.immediately, today: "2026-11-15") == .immediately)
  }

  /// Until the day is over the cashback of the month is simply due.
  @Test func beforeTheDayItIsDue() {
    let later = CashbackPayout.later(day: 10)
    let due = DateOnly(iso: "2026-10-10")!
    #expect(status(later, today: "2026-09-30") == .due(due))
    #expect(status(later, today: "2026-10-10") == .due(due))
  }

  /// Nothing came the day after the day: late, with what was expected.
  @Test func afterTheDayWithNothingReceivedItIsLate() {
    let later = CashbackPayout.later(day: 10)
    #expect(
      status(later, today: "2026-10-11")
        == .late(since: DateOnly(iso: "2026-10-10")!, expectedRub: money(280)))
  }

  /// Anything received is not a delay: the sum is an estimate, and a few rubles are no reason
  /// to worry.
  @Test func somethingReceivedIsPaid() {
    let later = CashbackPayout.later(day: 10)
    #expect(
      status(later, today: "2026-10-11", received: 250) == .paid(DateOnly(iso: "2026-10-10")!))
  }

  /// A month with no cashback expected has nothing to be late with.
  @Test func nothingExpectedIsNeverLate() {
    let later = CashbackPayout.later(day: 10)
    let result = status(later, today: "2026-10-20", expected: 0, received: 0)
    #expect(result == .due(DateOnly(iso: "2026-10-10")!))
  }

  /// The 31st is the end of the month: October 31st for September.
  @Test func theLastDayOfTheMonth() {
    let end = CashbackPayout.later(day: 31)
    #expect(status(end, today: "2026-10-31") == .due(DateOnly(iso: "2026-10-31")!))
    #expect(
      status(end, today: "2026-11-01")
        == .late(since: DateOnly(iso: "2026-10-31")!, expectedRub: money(280)))
  }
}
