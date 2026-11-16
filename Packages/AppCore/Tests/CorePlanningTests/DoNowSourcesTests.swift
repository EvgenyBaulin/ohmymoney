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
      try entry(
        daysAgo: 30, categorized: true, source: "statement", account: bank, loadedDaysAgo: 30),
      try entry(
        daysAgo: 20, categorized: true, source: "statement", account: bank, loadedDaysAgo: 14),
      try entry(daysAgo: 1, categorized: true, source: "manual", account: bank),
    ]
    let sources = DoNowSources.statements(entries: entries, today: today, calendar: calendar)
    #expect(sources.count == 1)
    #expect(sources[0].accountId == bank)
    #expect(sources[0].daysAgo == 14)
  }

  @Test func anImportWithNoNewOperationsStillAsksForTheNextStatement() {
    let bank = UUID()
    let importedAt = calendar.startOfDay(today.adding(days: -14)).addingTimeInterval(7200)
    let sources = DoNowSources.statements(
      entries: [], today: today, calendar: calendar,
      statementImportMoments: [bank: importedAt])

    #expect(sources.map(\.accountId) == [bank])
    #expect(sources.first?.daysAgo == 14)
  }

  @Test func aFreshStatementOrNoStatementAtAllAsksForNothing() throws {
    let bank = UUID()
    let entries = [
      try entry(
        daysAgo: 13, categorized: true, source: "statement", account: bank, loadedDaysAgo: 13),
      try entry(daysAgo: 40, categorized: true, source: "manual", account: UUID()),
    ]
    #expect(DoNowSources.statements(entries: entries, today: today, calendar: calendar).isEmpty)
  }

  @Test func anAccountWithoutAnImportRecordFallsBackToItsStatementOperations() throws {
    let importedAccount = UUID()
    let fallbackAccount = UUID()
    let entries = [
      try entry(
        daysAgo: 60, categorized: true, source: "statement", account: importedAccount,
        loadedDaysAgo: 60),
      try entry(
        daysAgo: 14, categorized: true, source: "statement", account: fallbackAccount,
        loadedDaysAgo: 14),
    ]
    let recentImport =
      calendar.startOfDay(today.adding(days: -11)).addingTimeInterval(7200)
    let sources = DoNowSources.statements(
      entries: entries, today: today, calendar: calendar,
      statementImportMoments: [importedAccount: recentImport])

    #expect(sources.map(\.accountId) == [fallbackAccount])
    #expect(sources.first?.daysAgo == 14)
  }

  /// A card with a quiet month: the statement was loaded 11 days ago although its newest
  /// operation is 25 days old — it must not ask.
  @Test func theDayOfLoadingCountsNotTheDayOfTheNewestOperation() throws {
    let bank = UUID()
    let entries = [
      try entry(
        daysAgo: 25, categorized: true, source: "statement", account: bank, loadedDaysAgo: 11)
    ]
    #expect(DoNowSources.statements(entries: entries, today: today, calendar: calendar).isEmpty)
  }

  @Test func anArchivedAccountNeverAsksForAStatement() throws {
    let open = UUID()
    let closed = UUID()
    let importedAt = calendar.startOfDay(today.adding(days: -60)).addingTimeInterval(7200)
    let entries = [
      try entry(
        daysAgo: 60, categorized: true, source: "statement", account: open, loadedDaysAgo: 60),
      try entry(
        daysAgo: 60, categorized: true, source: "statement", account: closed, loadedDaysAgo: 60),
    ]
    let sources = DoNowSources.statements(
      entries: entries, today: today, calendar: calendar,
      statementImportMoments: [open: importedAt, closed: importedAt],
      archivedAccounts: [closed])
    #expect(sources.map(\.accountId) == [open])
  }

  @Test func aSkippedAccountIsQuietForFourteenDaysThenAsksAgain() throws {
    let bank = UUID()
    let entries = [
      try entry(
        daysAgo: 60, categorized: true, source: "statement", account: bank, loadedDaysAgo: 60)
    ]
    let skips = StatementSkips().skipping(bank, on: today.adding(days: -13))
    #expect(
      DoNowSources.statements(entries: entries, today: today, calendar: calendar, skips: skips)
        .isEmpty)
    let later = StatementSkips().skipping(bank, on: today.adding(days: -14))
    #expect(
      DoNowSources.statements(entries: entries, today: today, calendar: calendar, skips: later)
        .map(\.accountId) == [bank])
  }

  @Test func aSkipOfOneAccountLeavesTheOtherAsking() throws {
    let skipped = UUID()
    let other = UUID()
    let entries = [
      try entry(
        daysAgo: 60, categorized: true, source: "statement", account: skipped, loadedDaysAgo: 60),
      try entry(
        daysAgo: 60, categorized: true, source: "statement", account: other, loadedDaysAgo: 60),
    ]
    let skips = StatementSkips().skipping(skipped, on: today)
    let sources = DoNowSources.statements(
      entries: entries, today: today, calendar: calendar, skips: skips)
    #expect(sources.map(\.accountId) == [other])
  }

  @Test func skipsSurviveTheRoundTripThroughTheirString() {
    let first = UUID()
    let second = UUID()
    let skips = StatementSkips().skipping(first, on: today).skipping(second, on: today.adding(days: -3))
    #expect(StatementSkips(encoded: skips.encoded) == skips)
    #expect(StatementSkips(encoded: "garbage,=,x=y").days.isEmpty)
    #expect(StatementSkips(encoded: nil).days.isEmpty)
  }

  @Test func prunedSkipsDropTheExpiredOnes() {
    let old = UUID()
    let fresh = UUID()
    let skips = StatementSkips().skipping(old, on: today.adding(days: -20))
      .skipping(fresh, on: today.adding(days: -2))
    #expect(skips.pruned(today: today).days.keys.sorted { $0.uuidString < $1.uuidString } == [fresh])
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
