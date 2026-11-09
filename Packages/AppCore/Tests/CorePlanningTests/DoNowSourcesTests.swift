import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CorePlanning

@Suite("Sources of «Что сделать сейчас»")
struct DoNowSourcesTests {
  private let today = DateOnly(year: 2026, month: 11, day: 5)
  private let calendar = CalendarContext.utc
  private let food = CoreKit.Category(kind: .expense, name: "Food")

  private func entry(
    daysAgo: Int, categorized: Bool, source: String? = nil, account: UUID? = nil
  )
    throws -> TransactionEntry
  {
    let day = today.adding(days: -daysAgo)
    var draft = TransactionDraft(
      kind: .expense, occurredAt: calendar.startOfDay(day).addingTimeInterval(3600),
      amount: AmountE4(whole: 100))
    draft.paymentMethodId = account
    draft.parts = [PartDraft(categoryId: categorized ? food.id : nil, amount: AmountE4(whole: 100))]
    var entry = try draft.materialize(timeZone: calendar.timeZone)
    entry.transaction.source = source
    return entry
  }

  @Test func reviewCountsWeekOldOperationsWithoutCategory() throws {
    let entries = [
      try entry(daysAgo: 0, categorized: false), try entry(daysAgo: 6, categorized: false),
      try entry(daysAgo: 7, categorized: false), try entry(daysAgo: 1, categorized: true),
    ]
    let sources = DoNowSources.reviews(entries: entries, today: today, calendar: calendar)
    #expect(sources.count == 1)
    #expect(sources[0].count == 2)
  }

  @Test func nothingUncategorizedIsNoSource() throws {
    let entries = [try entry(daysAgo: 2, categorized: true)]
    #expect(DoNowSources.reviews(entries: entries, today: today, calendar: calendar).isEmpty)
  }

  @Test func deletedOperationsAreNotCounted() throws {
    var gone = try entry(daysAgo: 1, categorized: false)
    gone.transaction.deletedAt = Date()
    #expect(DoNowSources.reviews(entries: [gone], today: today, calendar: calendar).isEmpty)
  }

  @Test func aStatementTwoWeeksOldAsksForTheNextOne() throws {
    let bank = UUID()
    let entries = [
      try entry(daysAgo: 30, categorized: true, source: "statement", account: bank),
      try entry(daysAgo: 14, categorized: true, source: "statement", account: bank),
      try entry(daysAgo: 1, categorized: true, source: "manual", account: bank),
    ]
    let sources = DoNowSources.statements(entries: entries, today: today, calendar: calendar)
    #expect(sources.count == 1)
    #expect(sources[0].accountId == bank)
    #expect(sources[0].daysAgo == 14)
  }

  @Test func aFreshStatementOrNoStatementAtAllAsksForNothing() throws {
    let bank = UUID()
    let entries = [
      try entry(daysAgo: 13, categorized: true, source: "statement", account: bank),
      try entry(daysAgo: 40, categorized: true, source: "manual", account: UUID()),
    ]
    #expect(DoNowSources.statements(entries: entries, today: today, calendar: calendar).isEmpty)
  }

  @Test func theVerdictHasOneThreshold() {
    #expect(FreeVerdict(free: AmountE4(whole: 0)) == .enough)
    #expect(FreeVerdict(free: AmountE4(whole: 41_600)) == .enough)
    #expect(FreeVerdict(free: AmountE4(whole: -1)) == .short)
  }
}
