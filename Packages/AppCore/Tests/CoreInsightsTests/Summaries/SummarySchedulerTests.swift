import CoreKit
import Foundation
import Testing

@testable import CoreInsights

@Suite("«Итоги»: when they come")
struct SummarySchedulerTests {
  let first = DateOnly(year: 2025, month: 3, day: 1)
  let on = SummarySwitches()

  func ready(
    _ today: DateOnly, switches: SummarySwitches? = nil, shown: Set<SummaryID> = [],
    firstDay: DateOnly? = nil
  ) -> [SummaryID] {
    SummaryScheduler.ready(
      today: today, firstDay: firstDay ?? first, switches: switches ?? on, shown: shown)
  }

  @Test func weekKeysFollowTheIsoCalendar() {
    let monday = DateOnly(year: 2026, month: 10, day: 26)
    #expect(WeekKey(containing: monday) == WeekKey(year: 2026, week: 44))
    #expect(WeekKey(containing: monday).start == monday)
    #expect(WeekKey(containing: DateOnly(year: 2026, month: 11, day: 1)).week == 44)
    #expect(WeekKey(containing: DateOnly(year: 2027, month: 1, day: 1)) == WeekKey(year: 2026, week: 53))
    #expect(WeekKey(containing: DateOnly(year: 2024, month: 12, day: 30)) == WeekKey(year: 2025, week: 1))
    #expect(WeekKey(iso: "2026-W44") == WeekKey(year: 2026, week: 44))
    #expect(WeekKey(year: 2026, week: 44).iso == "2026-W44")
    #expect(WeekKey(year: 2026, week: 44).end == DateOnly(year: 2026, month: 11, day: 1))
    #expect(WeekKey(year: 2026, week: 1).previous == WeekKey(year: 2025, week: 52))
  }

  @Test func idsRoundTripThroughText() {
    for id in [SummaryID.week(WeekKey(year: 2026, week: 5)), .month(MonthKey(year: 2026, month: 9)), .year(2025)] {
      #expect(SummaryID(raw: id.description) == id)
    }
    #expect(SummaryID(raw: "decade:1") == nil)
  }

  @Test func aMonthComesOnTheFirstAndAWeekOnMonday() {
    // Thursday 1 October 2026: the month of September is ready, the week before it too.
    let october1 = DateOnly(year: 2026, month: 10, day: 1)
    #expect(ready(october1) == [.month(MonthKey(year: 2026, month: 9)), .week(WeekKey(year: 2026, week: 39))])
    // Monday: the week that ended.
    let monday = DateOnly(year: 2026, month: 10, day: 26)
    #expect(ready(monday).contains(.week(WeekKey(year: 2026, week: 43))))
  }

  @Test func aYearComesOnTheFirstOfJanuaryAndLeavesAfterMarch() {
    #expect(ready(DateOnly(year: 2026, month: 1, day: 1)).first == .year(2025))
    #expect(ready(DateOnly(year: 2026, month: 3, day: 31)).first == .year(2025))
    #expect(!ready(DateOnly(year: 2026, month: 4, day: 1)).contains(.year(2025)))
  }

  @Test func shownAndSwitchedOffAreNotOffered() {
    let today = DateOnly(year: 2026, month: 1, day: 1)
    let shown: Set<SummaryID> = [.year(2025)]
    #expect(!ready(today, shown: shown).contains(.year(2025)))
    #expect(ready(today, switches: SummarySwitches(week: false, month: true, year: false)).map(\.kind) == [.month])
    #expect(ready(today, switches: SummarySwitches(week: false, month: false, year: false)).isEmpty)
  }

  @Test func nothingBeforeTheFirstOperation() {
    let today = DateOnly(year: 2026, month: 10, day: 26)
    #expect(SummaryScheduler.ready(today: today, firstDay: nil, switches: on, shown: []).isEmpty)
    // The first operation is on 20 October: September and last week are empty.
    let late = ready(today, firstDay: DateOnly(year: 2026, month: 10, day: 20))
    #expect(late == [.week(WeekKey(year: 2026, week: 43))])
    let after = ready(today, firstDay: DateOnly(year: 2026, month: 10, day: 26))
    #expect(after.isEmpty)
  }

  @Test func theQuestionOfTheWeekComesOnSundayAndMonday() {
    let sunday = DateOnly(year: 2026, month: 10, day: 25)
    let week = WeekKey(containing: sunday)
    #expect(SummaryScheduler.weekToAsk(today: sunday, firstDay: first, answered: [], switches: on) == week)
    let monday = sunday.adding(days: 1)
    #expect(SummaryScheduler.weekToAsk(today: monday, firstDay: first, answered: [], switches: on) == week)
    #expect(SummaryScheduler.weekToAsk(today: monday, firstDay: first, answered: [week], switches: on) == nil)
    #expect(SummaryScheduler.weekToAsk(today: sunday.adding(days: 3), firstDay: first, answered: [], switches: on) == nil)
    #expect(
      SummaryScheduler.weekToAsk(
        today: sunday, firstDay: first, answered: [], switches: SummarySwitches(week: false)) == nil)
  }

  @Test func theCardSaysASummaryBeforeAQuestion() {
    let monday = DateOnly(year: 2026, month: 10, day: 26)
    let said = SummaryScheduler.announcement(
      today: monday, firstDay: first, switches: on, shown: [], answered: [])
    #expect(said == .summary(.month(MonthKey(year: 2026, month: 9))))
    let shown: Set<SummaryID> = [.month(MonthKey(year: 2026, month: 9)), .week(WeekKey(year: 2026, week: 43))]
    let then = SummaryScheduler.announcement(
      today: monday, firstDay: first, switches: on, shown: shown, answered: [])
    #expect(then == .weekQuestion(WeekKey(year: 2026, week: 43)))
  }

  @Test func theArchiveListsFinishedPeriodsNewestFirst() {
    let today = DateOnly(year: 2026, month: 10, day: 26)
    let months = SummaryScheduler.archive(kind: .month, today: today, firstDay: DateOnly(year: 2026, month: 8, day: 14))
    #expect(months == [9, 8].map { .month(MonthKey(year: 2026, month: $0)) })
    #expect(SummaryScheduler.archive(kind: .year, today: today, firstDay: first) == [.year(2025)])
    #expect(SummaryScheduler.archive(kind: .week, today: today, firstDay: DateOnly(year: 2026, month: 10, day: 12)).count == 2)
  }
}
