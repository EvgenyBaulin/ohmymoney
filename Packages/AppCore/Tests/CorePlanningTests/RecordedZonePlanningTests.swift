import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CorePlanning

/// An operation recorded in another zone stays on the day of that zone wherever the Mac is: an
/// operation at 01:30 on 1 December in Makassar (UTC+8) is December's, though in Moscow it is
/// still 20:30 on 30 November. The planning rules read its day the way the ledger does.
@Suite("Planning reads an operation's day in the zone it was recorded in")
struct RecordedZonePlanningTests {
  static let zone = "Asia/Makassar"
  /// 2026-11-30T17:30Z — 01:30 on 1 December in Makassar, 20:30 on 30 November in Moscow.
  static let night = Date(timeIntervalSince1970: 1_796_059_800)
  static let december = MonthKey(year: 2026, month: 12)
  static let moscow = CalendarContext.moscow

  static func entry(
    _ number: Int, kind: TransactionKind = .expense, at moment: Date = night,
    category: UUID? = nil, account: UUID? = nil, externalId: String? = nil
  ) -> TransactionEntry {
    let id = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number))!
    let amount = AmountE4(whole: 100)
    return TransactionEntry(
      transaction: Transaction(
        id: id, kind: kind, occurredAt: moment, amountE4: amount, amountRubE4: amount,
        paymentMethodId: account, externalId: externalId, createdAt: moment, updatedAt: moment,
        timeZoneId: zone),
      parts: [
        TransactionPart(
          id: UUID(), transactionId: id, categoryId: category,
          quality: kind.hasQuality ? .neutral : nil,
          qualitySource: kind.hasQuality ? .category : nil, amountE4: amount,
          amountRubE4: amount)
      ])
  }

  /// The bank's interest paid at 01:30 on 28 August in Makassar is inside the window of the
  /// payout due on the 31st, which opens three days early; in UTC it is still the 27th.
  @Test func aNightInterestIncomeAbroadBringsThePayoutOfItsOwnDay() throws {
    var fx = DepositFx()
    let id = fx.income("1315.07", on: "2026-08-28")
    let index = try #require(fx.cash.entries.firstIndex { $0.id == id })
    // 2026-08-27T17:30Z.
    let moment = Date(timeIntervalSince1970: 1_787_851_800)
    fx.cash.entries[index].transaction.occurredAt = moment
    fx.cash.entries[index].transaction.timeZoneId = Self.zone
    let payout = try #require(
      fx.payouts().first { $0.payDate == CashFx.day("2026-08-31") })
    #expect(payout.state == .received(id))
  }

  /// «Разобрать» counts the last seven days: an operation at 01:30 on the first of them in
  /// Makassar is recent, though in Moscow it is the evening before.
  @Test func aNightOperationAbroadIsReviewedAsOfItsOwnDay() {
    let today = DateOnly(year: 2026, month: 12, day: 7)
    let sources = DoNowSources.reviews(
      entries: [Self.entry(1)], today: today, calendar: Self.moscow)
    #expect(sources.map(\.id) == [DoNowSources.recentReviewId])
  }

  @Test func theHistoryOfARecordIsInTheMonthOfTheOperationsZone() {
    let category = CoreKit.Category(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000077")!, kind: .expense,
      name: "Food")
    let records = Namesakes.categories(
      [category], entries: [Self.entry(1, category: category.id)], calendar: Self.moscow)
    #expect(records.first?.period?.first == Self.december)
  }

  @Test func theHistoryOfAnExpectationIsInTheMonthOfTheIncomesZone() {
    let income = ExpectedIncome(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000088")!, name: "Project",
      totalE4: AmountE4(whole: 100), dueDate: DateOnly(year: 2026, month: 12, day: 1))
    let entry = Self.entry(1, kind: .income)
    let records = Namesakes.expected(
      [income], links: [ExpectedIncomeLink(expectedIncomeId: income.id, transactionId: entry.id)],
      entries: [entry], calendar: Self.moscow)
    #expect(records.first?.period?.first == Self.december)
  }

  @Test func theHistoryOfAPaymentIsInTheMonthOfItsChargesZone() {
    let payment = ScheduledPayment(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000099")!, name: "Cloud",
      amountE4: AmountE4(whole: 100))
    let linked = Self.entry(
      1,
      externalId: OperationLink.scheduled(
        paymentId: payment.id, due: DateOnly(year: 2026, month: 12, day: 1)
      ).externalId)
    let matched = Self.entry(2)
    let records = Namesakes.scheduled(
      [payment], entries: [linked, matched], calendar: Self.moscow,
      matchedOperations: [payment.id: [matched.id]])
    #expect(records.first?.period?.first == Self.december)
    #expect(records.first?.period?.last == Self.december)
  }
}
