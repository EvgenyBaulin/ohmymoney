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
    daysAgo: Int, categorized: Bool, source: String? = nil, account: UUID? = nil,
    loadedDaysAgo: Int? = nil
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
    if let loadedDaysAgo {
      entry.transaction.createdAt = calendar.startOfDay(today.adding(days: -loadedDaysAgo))
        .addingTimeInterval(7200)
    }
    return entry
  }

  @Test func reviewCountsWeekOldOperationsWithoutCategory() throws {
    let entries = [
      try entry(daysAgo: 0, categorized: false), try entry(daysAgo: 6, categorized: false),
      try entry(daysAgo: 7, categorized: false), try entry(daysAgo: 1, categorized: true),
    ]
    let sources = DoNowSources.reviews(entries: entries, today: today, calendar: calendar)
    let recent = sources.first { $0.id == DoNowSources.recentReviewId }
    #expect(recent?.count == 2)
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

  @Test func aStatementLoadedTwoWeeksAgoAsksForTheNextOne() throws {
    let bank = UUID()
    let entries = [
      try entry(daysAgo: 30, categorized: true, source: "statement", account: bank, loadedDaysAgo: 30),
      try entry(daysAgo: 20, categorized: true, source: "statement", account: bank, loadedDaysAgo: 14),
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
      try entry(daysAgo: 13, categorized: true, source: "statement", account: bank, loadedDaysAgo: 13),
      try entry(daysAgo: 40, categorized: true, source: "manual", account: UUID()),
    ]
    #expect(DoNowSources.statements(entries: entries, today: today, calendar: calendar).isEmpty)
  }

  /// A card with a quiet month: the statement was loaded 11 days ago although its newest
  /// operation is 25 days old — it must not ask.
  @Test func theDayOfLoadingCountsNotTheDayOfTheNewestOperation() throws {
    let bank = UUID()
    let entries = [
      try entry(daysAgo: 25, categorized: true, source: "statement", account: bank, loadedDaysAgo: 11)
    ]
    #expect(DoNowSources.statements(entries: entries, today: today, calendar: calendar).isEmpty)
  }

  @Test func anArchivedAccountNeverAsksForAStatement() throws {
    let open = UUID()
    let closed = UUID()
    let entries = [
      try entry(daysAgo: 60, categorized: true, source: "statement", account: open, loadedDaysAgo: 60),
      try entry(daysAgo: 60, categorized: true, source: "statement", account: closed, loadedDaysAgo: 60),
    ]
    let sources = DoNowSources.statements(
      entries: entries, today: today, calendar: calendar, archivedAccounts: [closed])
    #expect(sources.map(\.accountId) == [open])
  }

  /// Operations without a category older than the week do not vanish: they form their own,
  /// lower source next to the recent one.
  @Test func olderUncategorizedOperationsAreTheirOwnSource() throws {
    let entries = [
      try entry(daysAgo: 1, categorized: false), try entry(daysAgo: 7, categorized: false),
      try entry(daysAgo: 400, categorized: false), try entry(daysAgo: 30, categorized: true),
    ]
    let sources = DoNowSources.reviews(entries: entries, today: today, calendar: calendar)
    #expect(sources.map(\.id) == [DoNowSources.recentReviewId, DoNowSources.olderReviewId])
    #expect(sources.map(\.count) == [1, 2])
  }

  @Test func onlyOlderUncategorizedOperationsGiveOnlyTheOlderSource() throws {
    let entries = [try entry(daysAgo: 20, categorized: false)]
    let sources = DoNowSources.reviews(entries: entries, today: today, calendar: calendar)
    #expect(sources.map(\.id) == [DoNowSources.olderReviewId])
  }

  @Test func theOlderReviewComesAfterTheRecentOneInTheList() {
    let list = WhatToDoNow.list(
      payments: [],
      reviews: [
        DoNowSource(id: DoNowSources.olderReviewId, count: 9),
        DoNowSource(id: DoNowSources.recentReviewId, count: 2),
      ], today: today)
    #expect(list.items.map(\.count) == [2, 9])
  }

  @Test func theVerdictHasOneThreshold() {
    #expect(FreeVerdict(free: AmountE4(whole: 0)) == .enough)
    #expect(FreeVerdict(free: AmountE4(whole: 41_600)) == .enough)
    #expect(FreeVerdict(free: AmountE4(whole: -1)) == .short)
  }
}
