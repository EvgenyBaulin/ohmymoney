import CoreKit
import Foundation
import Testing

@testable import CoreParse

@Suite("Поиск операции для чека")
struct ReceiptMatchTests {
  static let calendar = CalendarContext(timeZone: TimeZone(identifier: "Europe/Moscow")!)
  static let receipt = ReceiptQRParser.parse("t=20261029T183200&s=1250.50&n=1")!

  static func candidate(
    _ id: String, day: Int, hour: Int = 12, month: Int = 10, amount: Int64 = 12_505_000,
    kind: TransactionKind = .expense, currency: CurrencyCode = .rub, zone: String? = nil
  ) -> ReceiptCandidate {
    ReceiptCandidate(
      id: Fixture.id(id), kind: kind,
      occurredAt: calendar.moment(
        DateOnly(year: 2026, month: month, day: day), hour: hour, minute: 0),
      timeZoneId: zone, currency: currency, amountE4: AmountE4(raw: amount))
  }

  @Test func sameSumSameDayIsOffered() {
    let proposal = ReceiptMatch.propose(
      Self.receipt, among: [Self.candidate("01", day: 29)], calendar: Self.calendar)
    guard case .supplement(let found, let moment, let others) = proposal else {
      Issue.record("expected a supplement")
      return
    }
    #expect(found.id == Fixture.id("01"))
    #expect(others.isEmpty)
    #expect(Self.calendar.timeOfDay(moment) == TimeOfDay(hour: 18, minute: 32))
  }

  @Test func aDayEitherWayIsEnoughTwoDaysAreNot() {
    for day in [28, 30] {
      let proposal = ReceiptMatch.propose(
        Self.receipt, among: [Self.candidate("01", day: day)], calendar: Self.calendar)
      if case .new = proposal { Issue.record("day \(day) should match") }
    }
    for day in [27, 31] {
      let proposal = ReceiptMatch.propose(
        Self.receipt, among: [Self.candidate("01", day: day)], calendar: Self.calendar)
      guard case .new = proposal else {
        Issue.record("day \(day) should not match")
        continue
      }
    }
  }

  @Test func monthBoundaryCountsAsNeighbours() throws {
    let receipt = try #require(ReceiptQRParser.parse("t=20261101T0030&s=1250.50&n=1"))
    let proposal = ReceiptMatch.propose(
      receipt, among: [Self.candidate("01", day: 31)], calendar: Self.calendar)
    if case .new = proposal { Issue.record("31 October is the day before 1 November") }
  }

  @Test func theNearestComesFirstTheSameDayBeforeANeighbour() {
    let candidates = [
      Self.candidate("01", day: 28, hour: 18),
      Self.candidate("02", day: 29, hour: 9),
      Self.candidate("03", day: 29, hour: 18),
      Self.candidate("04", day: 30, hour: 18),
    ]
    guard
      case .supplement(let found, _, let others) = ReceiptMatch.propose(
        Self.receipt, among: candidates, calendar: Self.calendar)
    else {
      Issue.record("expected a supplement")
      return
    }
    #expect(found.id == Fixture.id("03"))
    #expect(others.map(\.id) == [Fixture.id("02"), Fixture.id("04"), Fixture.id("01")])
  }

  @Test func anotherSumKindOrCurrencyIsNotAMatch() {
    let candidates = [
      Self.candidate("01", day: 29, amount: 12_505_001),
      Self.candidate("02", day: 29, kind: .income),
      Self.candidate("03", day: 29, kind: .refund),
      Self.candidate("04", day: 29, currency: CurrencyCode("USD")),
    ]
    let proposal = ReceiptMatch.propose(Self.receipt, among: candidates, calendar: Self.calendar)
    guard case .new(let draft) = proposal else {
      Issue.record("expected a new operation")
      return
    }
    #expect(draft.kind == .expense)
    #expect(draft.currency == .rub)
    #expect(draft.amountE4.raw == 12_505_000)
    #expect(draft.day == DateOnly(year: 2026, month: 10, day: 29))
    #expect(draft.time == TimeOfDay(hour: 18, minute: 32))
  }

  @Test func aRefundReceiptLooksForARefund() throws {
    let refund = try #require(ReceiptQRParser.parse("t=20261029T183200&s=1250.50&n=2"))
    let candidates = [
      Self.candidate("01", day: 29), Self.candidate("02", day: 29, kind: .refund),
    ]
    guard
      case .supplement(let found, _, _) = ReceiptMatch.propose(
        refund, among: candidates, calendar: Self.calendar)
    else {
      Issue.record("expected a supplement")
      return
    }
    #expect(found.id == Fixture.id("02"))
  }

  @Test func nothingAtAllIsANewOperation() {
    let proposal = ReceiptMatch.propose(Self.receipt, among: [], calendar: Self.calendar)
    guard case .new(let draft) = proposal else {
      Issue.record("expected a new operation")
      return
    }
    #expect(Self.calendar.day(of: draft.moment) == draft.day)
  }

  @Test func theDayOfAnOperationIsTheDayInItsOwnZone() {
    // 23:30 on 30 October in Tokyo is 17:30 on the 30th in Moscow, but 29 October 20:30 there
    // would be the 30th in Tokyo: the operation is read on the day of the zone it was recorded in.
    let tokyo = CalendarContext(timeZone: TimeZone(identifier: "Asia/Tokyo")!)
    let late = ReceiptCandidate(
      id: Fixture.id("09"), kind: .expense,
      occurredAt: tokyo.moment(DateOnly(year: 2026, month: 10, day: 31), hour: 23, minute: 30),
      timeZoneId: "Asia/Tokyo", currency: .rub, amountE4: AmountE4(raw: 12_505_000))
    // In Moscow that instant is 17:30 on 31 October, two days from the receipt's 29th; in
    // Tokyo it is the 31st too. Both say no.
    guard case .new = ReceiptMatch.propose(Self.receipt, among: [late], calendar: Self.calendar)
    else {
      Issue.record("two days apart")
      return
    }
    let near = ReceiptCandidate(
      id: Fixture.id("08"), kind: .expense,
      occurredAt: tokyo.moment(DateOnly(year: 2026, month: 10, day: 30), hour: 1, minute: 0),
      timeZoneId: "Asia/Tokyo", currency: .rub, amountE4: AmountE4(raw: 12_505_000))
    // 01:00 on the 30th in Tokyo is 19:00 on the 29th in Moscow: matches either way.
    if case .new = ReceiptMatch.propose(Self.receipt, among: [near], calendar: Self.calendar) {
      Issue.record("one day apart")
    }
  }
}

@Suite("Время чека для найденной операции")
struct ReceiptSupplementZoneTests {
  @Test func theTimeIsReadInTheZoneOfTheOperation() throws {
    let owner = CalendarContext(
      timeZone: TimeZone(identifier: "Asia/Tokyo")!, unrecordedZone: TravelDay.moscowZone)
    let receipt = try #require(ReceiptQRParser.parse("t=20261029T183200&s=10.00&n=1"))
    let moscow = CalendarContext.moscow
    let candidate = ReceiptCandidate(
      id: Fixture.id("01"), kind: .expense,
      occurredAt: moscow.moment(DateOnly(year: 2026, month: 10, day: 29), hour: 12, minute: 0),
      timeZoneId: nil, amountE4: AmountE4(raw: 100_000))
    guard
      case .supplement(_, let moment, _) = ReceiptMatch.propose(
        receipt, among: [candidate], calendar: owner)
    else {
      Issue.record("expected a supplement")
      return
    }
    #expect(moscow.timeOfDay(moment) == TimeOfDay(hour: 18, minute: 32))
    #expect(moscow.day(of: moment) == DateOnly(year: 2026, month: 10, day: 29))
  }
}

@Suite("Чек: почти подходящие операции")
struct ReceiptNearMatchTests {

  @Test func aTipOrARoundingGivesASuggestionNeverAMatch() {
    // 1 250.50 on the receipt; the owner wrote 1 300 (a tip) and 1 250 (a rounding).
    let tip = ReceiptMatchTests.candidate("01", day: 29, amount: 13_000_000)
    let rounded = ReceiptMatchTests.candidate("02", day: 29, amount: 12_500_000)
    let far = ReceiptMatchTests.candidate("03", day: 29, amount: 20_000_000)
    let proposal = ReceiptMatch.propose(
      ReceiptMatchTests.receipt, among: [tip, rounded, far], calendar: ReceiptMatchTests.calendar)
    guard case .new(let draft) = proposal else {
      Issue.record("a near sum is not the receipt's own")
      return
    }
    #expect(draft.similar.map(\.id) == [Fixture.id("02"), Fixture.id("01")], "nearest sum first")
  }

  @Test func aWholeDayIsAllowedAndAnExactMatchHidesTheSuggestions() {
    // Both operations are within a day of the receipt at 18:32 on the 29th.
    let early = ReceiptMatchTests.candidate("01", day: 29, hour: 5, amount: 13_000_000)
    let evening = ReceiptMatchTests.candidate("02", day: 29, hour: 20, amount: 13_000_000)
    let near = ReceiptMatch.similar(
      to: ReceiptMatchTests.receipt, among: [early, evening], calendar: ReceiptMatchTests.calendar)
    #expect(near.map(\.id) == [Fixture.id("02"), Fixture.id("01")])

    let exact = ReceiptMatchTests.candidate("03", day: 29)
    let proposal = ReceiptMatch.propose(
      ReceiptMatchTests.receipt, among: [evening, exact], calendar: ReceiptMatchTests.calendar)
    guard case .supplement(let found, _, let others) = proposal else {
      Issue.record("expected the exact match")
      return
    }
    #expect(found.id == Fixture.id("03") && others.isEmpty)
  }

  @Test func fivePercentAndOneDayAreInclusiveWithoutAnAbsoluteMinimum() throws {
    let receipt = try #require(ReceiptQRParser.parse("t=20261029T183200&s=100.00&n=1"))
    let moment = receipt.moment(in: ReceiptMatchTests.calendar)
    func candidate(_ amount: Int64, _ seconds: TimeInterval) -> ReceiptCandidate {
      ReceiptCandidate(
        id: UUID(), kind: .expense, occurredAt: moment.addingTimeInterval(seconds),
        amountE4: AmountE4(raw: amount))
    }
    for amount: Int64 in [950_000, 1_050_000] {
      for seconds: TimeInterval in [-86_400, 86_400] {
        let boundary = candidate(amount, seconds)
        #expect(
          ReceiptMatch.similar(
            to: receipt, among: [boundary], calendar: ReceiptMatchTests.calendar) == [boundary])
      }
    }
    let outside = [
      candidate(949_999, 0), candidate(1_050_001, 0),
      candidate(1_010_000, -86_401), candidate(1_010_000, 86_401),
    ]
    #expect(
      ReceiptMatch.similar(
        to: receipt, among: outside, calendar: ReceiptMatchTests.calendar
      ).isEmpty)
  }
}

@Suite("Чек, разделённый вручную")
struct ReceiptSplitTests {
  let food = Fixture.id("0a")
  let home = Fixture.id("0b")
  let total = AmountE4(whole: 1_000)

  @Test func theRemainderGoesToTheChosenCategoryAndPartsAddUp() throws {
    let split = ReceiptSplit(
      total: total, lines: [.init(categoryId: food, amountE4: AmountE4(whole: 700))])
    #expect(split.remainder == AmountE4(whole: 300))
    let parts = try split.parts(remainderCategory: home).get()
    #expect(parts.map(\.categoryId) == [food, home])
    #expect(AmountE4.sum(parts.map(\.amountE4)) == total)
  }

  @Test func anIncompleteOrOverfullSplitIsRefused() {
    let some = ReceiptSplit(
      total: total, lines: [.init(categoryId: food, amountE4: AmountE4(whole: 700))])
    #expect(some.parts() == .failure(.notAllAssigned))
    let over = ReceiptSplit(
      total: total, lines: [.init(categoryId: food, amountE4: AmountE4(whole: 1_200))])
    #expect(over.parts(remainderCategory: home) == .failure(.exceedsTotal))
    let negative = ReceiptSplit(
      total: total, lines: [.init(categoryId: food, amountE4: AmountE4(whole: -5))])
    #expect(negative.parts(remainderCategory: home) == .failure(.nonPositiveLine))
  }

  @Test func linesOfOneCategoryMergeAndEmptyOnesGo() throws {
    let split = ReceiptSplit(
      total: total,
      lines: [
        .init(categoryId: food, amountE4: AmountE4(whole: 400)),
        .init(categoryId: home, amountE4: .zero),
        .init(categoryId: food, amountE4: AmountE4(whole: 600)),
      ])
    let parts = try split.parts().get()
    #expect(parts == [.init(categoryId: food, amountE4: total)])
  }

  @Test func anEvenSplitNeverLosesACent() throws {
    let odd = AmountE4(raw: 1_000_001)
    let split = ReceiptSplit.evenly(total: odd, among: [food, home, Fixture.id("0c")])
    #expect(split.remainder.isZero)
    #expect(try split.parts().get().count == 3)
  }
}
