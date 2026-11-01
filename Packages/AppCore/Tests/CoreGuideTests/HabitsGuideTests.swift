import CoreKit
import Foundation
import Testing

@testable import CoreGuide

@Suite("The first month")
struct FirstMonthTests {
  let start = DateOnly(year: 2026, month: 11, day: 2)

  @Test("the day of the month counts from one and ends after thirty days")
  func dayIndex() {
    #expect(FirstMonth.dayIndex(start: start, today: start) == 1)
    #expect(FirstMonth.dayIndex(start: start, today: DateOnly(year: 2026, month: 12, day: 1)) == 30)
    #expect(
      FirstMonth.dayIndex(start: start, today: DateOnly(year: 2026, month: 12, day: 2)) == nil)
    #expect(
      FirstMonth.dayIndex(start: start, today: DateOnly(year: 2026, month: 11, day: 1)) == nil)
  }

  @Test(
    "each task comes on its day: the accounts and the first expense first, the count on day seven")
  func byDays() {
    let first = FirstMonth.open(start: start, today: start, facts: FirstMonthFacts())
    #expect(first.map(\.id) == ["month.accounts", "month.firstOperation"])
    let week = FirstMonth.open(
      start: start, today: DateOnly(year: 2026, month: 11, day: 8), facts: FirstMonthFacts())
    #expect(week.map(\.id).contains("month.firstCount"))
    #expect(!week.map(\.id).contains("month.goal"))
  }

  @Test("a task is done by the data, and done stays done")
  func doneByFacts() {
    let facts = FirstMonthFacts(accountsReady: true, operations: 2, entryDays: 1)
    let open = FirstMonth.open(start: start, today: start.addingDays(3), facts: facts)
    #expect(open.map(\.id) == ["month.subscriptions", "month.threeDays"])
    var progress = FirstMonthProgress(start: start)
    #expect(progress.record(facts) == ["month.accounts", "month.firstOperation"])
    // The data changes (an operation deleted): the task stays done.
    let later = FirstMonth.open(
      start: start, today: start.addingDays(3), facts: FirstMonthFacts(), done: progress.done)
    #expect(!later.map(\.id).contains("month.firstOperation"))
    let counted = FirstMonth.progress(facts: FirstMonthFacts(), done: progress.done)
    #expect(counted.done == 2)
    #expect(counted.total == FirstMonth.tasks.count)
  }

  @Test("the card hides when put away, after the month or with nothing left")
  func shows() {
    let progress = FirstMonthProgress(start: start)
    #expect(progress.shows(today: start, facts: FirstMonthFacts()))
    var hidden = progress
    hidden.hidden = true
    #expect(!hidden.shows(today: start, facts: FirstMonthFacts()))
    #expect(!progress.shows(today: start.addingDays(40), facts: FirstMonthFacts()))
    let all = FirstMonthFacts(
      accountsReady: true, operations: 1, entryDays: 10, scheduledPayments: 1, limits: 1,
      goals: 1, counts: 2)
    #expect(!progress.shows(today: start.addingDays(29), facts: all))
  }

  @Test("the memory reads back, and a memory without the flag of hiding reads as shown")
  func memory() throws {
    var progress = FirstMonthProgress(start: start, done: ["month.accounts"])
    progress.hidden = true
    let data = try JSONEncoder().encode(progress)
    #expect(try JSONDecoder().decode(FirstMonthProgress.self, from: data) == progress)
  }

  @Test("every task has both languages and a day within the month; ids are unique")
  func texts() {
    #expect(Set(FirstMonth.tasks.map(\.id)).count == FirstMonth.tasks.count)
    for task in FirstMonth.tasks {
      #expect(task.title.isComplete && task.why.isComplete, "\(task.id)")
      #expect((1...FirstMonth.length).contains(task.day), "\(task.id)")
    }
  }
}

@Suite("The beginner mode")
struct BeginnerModeTests {
  let today = DateOnly(year: 2026, month: 11, day: 20)

  @Test("off, nothing is quiet")
  func off() {
    #expect(BeginnerMode.quiet(enabled: false, facts: BeginnerFacts(today: today)).isEmpty)
  }

  @Test("a new owner sees Analytics, Reports and Capital quiet, with what each waits for")
  func newOwner() {
    let quiet = BeginnerMode.quiet(enabled: true, facts: BeginnerFacts(today: today))
    #expect(quiet[.analytics] == .entryDays(needed: 14, have: 0))
    #expect(quiet[.reports] == .monthOfEntries(daysLeft: 30))
    #expect(quiet[.capital] == .firstCount)
    // Nobody said there are no loans: the debts stay open.
    #expect(quiet[.debts] == nil)
  }

  @Test("each section opens on its own condition")
  func opens() {
    let first = DateOnly(year: 2026, month: 10, day: 10)
    let facts = BeginnerFacts(entryDays: 14, firstEntry: first, counts: 1, today: today)
    #expect(BeginnerMode.quiet(enabled: true, facts: facts).isEmpty)
    let early = BeginnerFacts(
      entryDays: 3, firstEntry: DateOnly(year: 2026, month: 11, day: 10), today: today)
    #expect(BeginnerMode.unlock(.reports, facts: early) == .monthOfEntries(daysLeft: 20))
  }

  @Test("the debts are quiet only for an owner without loans, until a week of entries")
  func debts() {
    let noLoans = BeginnerFacts(entryDays: 2, hasLoans: false, today: today)
    #expect(BeginnerMode.unlock(.debts, facts: noLoans) == .entryDays(needed: 7, have: 2))
    var withDebt = noLoans
    withDebt.debts = 1
    #expect(BeginnerMode.unlock(.debts, facts: withDebt) == nil)
    let loans = BeginnerFacts(entryDays: 0, hasLoans: true, today: today)
    #expect(BeginnerMode.unlock(.debts, facts: loans) == nil)
  }
}

@Suite("The lessons")
struct GuideLessonsTests {
  @Test("five lessons — cushion, loans, deposits, deductions, cashback — of five cards each")
  func shape() {
    #expect(
      GuideLessons.all.map(\.id) == ["cushion", "loans", "deposits", "deductions", "cashback"])
    #expect(GuideLessons.all.allSatisfy { $0.cards.count == 5 })
    let ids = GuideLessons.all.flatMap { $0.cards.map(\.id) }
    #expect(Set(ids).count == ids.count)
  }

  @Test("every text is in both languages")
  func languages() {
    for lesson in GuideLessons.all {
      #expect(lesson.title.isComplete, "\(lesson.id)")
      for card in lesson.cards {
        #expect(card.title.isComplete && card.body.isComplete, "\(card.id)")
      }
    }
  }

  /// A limit, a rate or a threshold changes: a lesson points to the screen that shows the figure
  /// of the day and holds no figure of its own.
  @Test("no lesson holds a figure of its own")
  func noFigures() {
    for lesson in GuideLessons.all {
      for card in lesson.cards {
        let texts = [card.title.russian, card.title.english, card.body.russian, card.body.english]
        #expect(!texts.joined().contains { $0.isNumber }, "\(card.id)")
      }
    }
  }

  @Test("a lesson is a scenario of the guide with its own id, and a place it points at is known")
  func scenario() throws {
    let lesson = try #require(GuideLessons.lesson("deposits"))
    #expect(lesson.scenario.id == "lesson.deposits")
    #expect(lesson.scenario.cards == lesson.cards)
    let known: Set<String> = [
      GuideTarget.sidebarCapital, GuideTarget.sidebarDebts, GuideTarget.sidebarPlanning,
    ]
    for card in GuideLessons.all.flatMap(\.cards) {
      if let target = card.target { #expect(known.contains(target), "\(card.id)") }
    }
  }

  @Test("«Что нового в 2.8» tells of the habits")
  func whatsNew() {
    #expect(GuideCatalog.whatsNew.contains { $0.id == "whatsNew.2.8" })
    let progress = GuideProgress(firstLaunchShown: true, whatsNewSeen: "2.7.0")
    #expect(
      progress.whatsNewDue(current: "2.8.0", catalog: GuideCatalog.whatsNew).map(\.id)
        == ["whatsNew.2.8"])
  }
}

extension DateOnly {
  fileprivate func addingDays(_ days: Int) -> DateOnly {
    CalendarContext.moscow.adding(days: days, to: self)
  }
}
