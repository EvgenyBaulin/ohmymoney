import CoreKit
import Foundation
import Testing

@testable import CoreAnalytics

/// «Прошлый месяц», «последние 30 дней», «третий квартал»: days from words, the same days
/// the periods of Analytics are made of.
@Suite("Периоды словами")
struct RelativePeriodTests {
  static let today = DateOnly(year: 2026, month: 10, day: 22)  // a Thursday

  private func span(
    _ period: RelativePeriod, _ today: DateOnly = RelativePeriodTests.today
  )
    -> String
  {
    let value = period.resolved(today: today)
    return "\(value.start.iso)…\(value.end.iso)"
  }

  @Test("Дни по словам на четверг 22 октября 2026")
  func spansOnAThursday() {
    #expect(span(.today) == "2026-10-22…2026-10-22")
    #expect(span(.yesterday) == "2026-10-21…2026-10-21")
    #expect(span(.thisWeek) == "2026-10-19…2026-10-25")
    #expect(span(.lastWeek) == "2026-10-12…2026-10-18")
    #expect(span(.thisMonth) == "2026-10-01…2026-10-31")
    #expect(span(.lastMonth) == "2026-09-01…2026-09-30")
    #expect(span(.thisQuarter) == "2026-10-01…2026-12-31")
    #expect(span(.lastQuarter) == "2026-07-01…2026-09-30")
    #expect(span(.thisYear) == "2026-01-01…2026-12-31")
    #expect(span(.lastYear) == "2025-01-01…2025-12-31")
    #expect(span(.lastDays(30)) == "2026-09-23…2026-10-22")
    #expect(span(.lastDays(1)) == "2026-10-22…2026-10-22")
    #expect(span(.lastMonths(12)) == "2025-11-01…2026-10-31")
    #expect(span(.lastMonths(3)) == "2026-08-01…2026-10-31")
    #expect(span(.month(MonthKey(year: 2026, month: 2))) == "2026-02-01…2026-02-28")
    #expect(span(.month(MonthKey(year: 2024, month: 2))) == "2024-02-01…2024-02-29")
    #expect(span(.quarter(year: 2025, number: 3)) == "2025-07-01…2025-09-30")
    #expect(span(.year(2024)) == "2024-01-01…2024-12-31")
    let range = RelativePeriod.range(
      DateOnly(year: 2026, month: 9, day: 1), DateOnly(year: 2026, month: 9, day: 15))
    #expect(span(range) == "2026-09-01…2026-09-15")
  }

  @Test("Границы года, високосный февраль и неделя через Новый год")
  func calendarEdges() {
    let january = DateOnly(year: 2026, month: 1, day: 1)  // a Thursday
    #expect(span(.thisWeek, january) == "2025-12-29…2026-01-04")
    #expect(span(.lastMonth, january) == "2025-12-01…2025-12-31")
    #expect(span(.lastQuarter, january) == "2025-10-01…2025-12-31")
    #expect(span(.lastMonths(12), january) == "2025-02-01…2026-01-31")
    let march = DateOnly(year: 2024, month: 3, day: 10)
    #expect(span(.lastMonth, march) == "2024-02-01…2024-02-29")
    #expect(span(.lastDays(60), march) == "2024-01-11…2024-03-10")
    let sunday = DateOnly(year: 2026, month: 10, day: 25)
    #expect(span(.thisWeek, sunday) == "2026-10-19…2026-10-25")
    let monday = DateOnly(year: 2026, month: 10, day: 26)
    #expect(span(.thisWeek, monday) == "2026-10-26…2026-11-01")
  }

  @Test("Слова и дни совпадают с арифметикой Аналитики на двух тысячах дней подряд")
  func agreesWithAnalyticsArithmetic() {
    var day = DateOnly(year: 2024, month: 1, day: 1)
    for _ in 0..<2_000 {
      let week = RelativePeriod.thisWeek.resolved(today: day)
      #expect(week.start == day.weekStart && week.end == day.weekStart.adding(days: 6), "\(day)")
      let days = RelativePeriod.lastDays(45).resolved(today: day)
      #expect(days.start == day.adding(days: -44) && days.end == day)
      let last = RelativePeriod.lastMonth.resolved(today: day)
      #expect(
        last.start == day.monthKey.previous.firstDay && last.end == day.monthKey.previous.lastDay)
      let yesterday = RelativePeriod.yesterday.resolved(today: day)
      #expect(yesterday.start == day.adding(days: -1))
      let twelve = RelativePeriod.lastMonths(12).resolved(today: day)
      let reference = Period.twelveMonths(endingWith: day.monthKey)
      #expect(twelve.start == reference.start && twelve.end == reference.end)
      day = day.adding(days: 1)
    }
  }

  @Test("В период Аналитики: целый месяц и год остаются месяцем и годом")
  func intoAPeriod() {
    let today = Self.today
    #expect(
      RelativePeriod.thisMonth.period(today: today) == .month(MonthKey(year: 2026, month: 10)))
    #expect(RelativePeriod.lastMonth.period(today: today) == .month(MonthKey(year: 2026, month: 9)))
    #expect(RelativePeriod.lastYear.period(today: today) == .year(2025))
    #expect(
      RelativePeriod.lastMonths(12).period(today: today)
        == .twelveMonths(endingWith: MonthKey(year: 2026, month: 10)))
    #expect(RelativePeriod.lastDays(30).period(today: today).kind == .days)
    #expect(RelativePeriod.thisQuarter.period(today: today).kind == .days)
    #expect(RelativePeriod.thisQuarter.period(today: today).isWholeMonths)
    #expect(
      Period.covering(
        DayRange(DateOnly(year: 2026, month: 3, day: 1), DateOnly(year: 2026, month: 3, day: 31)))
        == .month(MonthKey(year: 2026, month: 3)))
  }

  @Test("Предыдущий период: месяц до месяца, год до года, столько же дней до дней")
  func previousPeriods() {
    let today = Self.today
    #expect(
      RelativePeriod.thisMonth.previous(today: today) == .month(MonthKey(year: 2026, month: 9)))
    #expect(
      RelativePeriod.lastMonth.previous(today: today) == .month(MonthKey(year: 2026, month: 8)))
    #expect(RelativePeriod.thisYear.previous(today: today) == .year(2025))
    #expect(RelativePeriod.lastYear.previous(today: today) == .year(2024))
    #expect(RelativePeriod.thisQuarter.previous(today: today) == .quarter(year: 2026, number: 3))
    #expect(
      RelativePeriod.quarter(year: 2026, number: 1).previous(today: today)
        == .quarter(year: 2025, number: 4))
    #expect(
      RelativePeriod.lastDays(30).previous(today: today)
        == .range(DateOnly(year: 2026, month: 8, day: 24), DateOnly(year: 2026, month: 9, day: 22)))
    // It is what the Analytics period calls «previous».
    for relative in [
      RelativePeriod.thisMonth, .lastMonth, .thisYear, .lastYear, .lastDays(30), .lastDays(7),
    ] {
      let own = relative.period(today: today).previous.range
      let words = relative.previous(today: today).resolved(today: today)
      #expect(own == DayRange(words.start, words.end), "\(relative.token)")
    }
  }

  @Test("Прошлое — пара настоящему; у остальных пары нет")
  func counterparts() {
    #expect(RelativePeriod.lastYear.currentCounterpart == .thisYear)
    #expect(RelativePeriod.lastMonth.currentCounterpart == .thisMonth)
    #expect(RelativePeriod.lastQuarter.currentCounterpart == .thisQuarter)
    #expect(RelativePeriod.lastWeek.currentCounterpart == .thisWeek)
    #expect(RelativePeriod.thisYear.currentCounterpart == nil)
    #expect(RelativePeriod.year(2025).currentCounterpart == nil)
  }

  @Test("Закрепить: что значило «прошлый месяц» сегодня")
  func fixing() {
    let today = Self.today
    #expect(RelativePeriod.lastMonth.fixed(today: today) == .month(MonthKey(year: 2026, month: 9)))
    #expect(RelativePeriod.thisYear.fixed(today: today) == .year(2026))
    #expect(RelativePeriod.lastQuarter.fixed(today: today) == .quarter(year: 2026, number: 3))
    #expect(
      RelativePeriod.lastDays(30).fixed(today: today)
        == .range(DateOnly(year: 2026, month: 9, day: 23), today))
    #expect(RelativePeriod.year(2025).fixed(today: today) == .year(2025))
    #expect(RelativePeriod.lastMonth.isFloating && !RelativePeriod.year(2025).isFloating)
  }
}
