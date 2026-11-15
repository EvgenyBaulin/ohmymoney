import CoreKit
import Foundation
import Testing

@testable import CoreParse

@Suite("Чек: объяснение близкой операции")
struct ReceiptNearbyTests {
  static let calendar = ReceiptMatchTests.calendar
  static let receipt = ReceiptMatchTests.receipt  // 1 250.50 on 29 October 18:32

  private func nearby(_ candidates: [ReceiptCandidate]) -> [ReceiptNearMatch] {
    ReceiptMatch.nearby(to: Self.receipt, among: candidates, calendar: Self.calendar)
  }

  @Test func aRoundingToTheRoubleIsNamedAsOne() throws {
    // 1 250.00 is 0.50 below the receipt; 1 300.00 is 49.50 above (a tip).
    let rounded = ReceiptMatchTests.candidate("01", day: 29, amount: 12_500_000)
    let tip = ReceiptMatchTests.candidate("02", day: 29, amount: 13_000_000)
    let found = nearby([tip, rounded])
    #expect(found.map(\.candidate.id) == [Fixture.id("01"), Fixture.id("02")])
    #expect(found[0].sumDifferenceE4 == -5_000)
    #expect(found[0].isRounding)
    #expect(found[1].sumDifferenceE4 == 495_000)
    #expect(!found[1].isRounding)
  }

  @Test func theRoundingEdgeIsOneRouble() {
    let edge = ReceiptMatchTests.candidate("01", day: 29, amount: 12_505_000 + 10_000)
    let over = ReceiptMatchTests.candidate("02", day: 29, amount: 12_505_000 - 10_001)
    let found = nearby([edge, over])
    #expect(found.first { $0.candidate.id == Fixture.id("01") }?.isRounding == true)
    #expect(found.first { $0.candidate.id == Fixture.id("02") }?.isRounding == false)
  }

  @Test func theDayOfTheOperationIsRelativeToTheReceipt() {
    let sameDay = ReceiptMatchTests.candidate("01", day: 29, hour: 20, amount: 12_500_000)
    let before = ReceiptMatchTests.candidate("02", day: 28, hour: 20, amount: 12_500_000)
    let after = ReceiptMatchTests.candidate("03", day: 30, hour: 8, amount: 12_500_000)
    let found = nearby([sameDay, before, after])
    func offset(_ id: String) -> Int? {
      found.first { $0.candidate.id == Fixture.id(id) }?.dayOffset
    }
    #expect(offset("01") == 0)
    #expect(offset("02") == -1)
    #expect(offset("03") == 1)
  }

  /// A purchase recorded on a trip is on the clock of the zone it was recorded in (the shop's
  /// clock is the same): 20:00 on the 28th in Auckland is 22.5 hours before the receipt's 18:32
  /// on the 29th there, though far more on the owner's own clock.
  @Test func theWindowIsReadOnTheClockOfTheZoneTheOperationWasRecordedIn() {
    let auckland = CalendarContext(timeZone: TimeZone(identifier: "Pacific/Auckland")!)
    let trip = ReceiptCandidate(
      id: Fixture.id("01"), kind: .expense,
      occurredAt: auckland.moment(DateOnly(year: 2026, month: 10, day: 28), hour: 20, minute: 0),
      timeZoneId: "Pacific/Auckland", amountE4: AmountE4(raw: 13_000_000))
    #expect(nearby([trip]).map(\.candidate.id) == [Fixture.id("01")])
    #expect(nearby([trip]).first?.dayOffset == -1)

    // The same operation 25 hours before the receipt on its own clock is out.
    let tooEarly = ReceiptCandidate(
      id: Fixture.id("02"), kind: .expense,
      occurredAt: auckland.moment(DateOnly(year: 2026, month: 10, day: 28), hour: 17, minute: 0),
      timeZoneId: "Pacific/Auckland", amountE4: AmountE4(raw: 13_000_000))
    #expect(nearby([tooEarly]).isEmpty)
  }

  @Test func theDraftCarriesTheExplainedList() {
    let rounded = ReceiptMatchTests.candidate("01", day: 29, amount: 12_500_000)
    guard
      case .new(let draft) = ReceiptMatch.propose(
        Self.receipt, among: [rounded], calendar: Self.calendar)
    else {
      Issue.record("a near sum is not the receipt's own")
      return
    }
    #expect(draft.nearby.map(\.candidate.id) == draft.similar.map(\.id))
    #expect(draft.nearby.first?.isRounding == true)
  }

  @Test func anOperationThatHoldsAReceiptIsNeverNear() {
    let taken = ReceiptCandidate(
      id: Fixture.id("01"), kind: .expense,
      occurredAt: Self.calendar.moment(
        DateOnly(year: 2026, month: 10, day: 29), hour: 18, minute: 0),
      amountE4: AmountE4(raw: 12_500_000),
      receipt: ReceiptNumbers(fiscalDrive: "1", documentNumber: "2"))
    #expect(nearby([taken]).isEmpty)
  }
}
