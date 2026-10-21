import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CorePlanning

/// «Это было до сверки в 10:00?» over every count of a day, oldest first: «Нет» asks about the
/// next count, «Да» puts the movement just before the count asked about and after the one
/// before it. An answer remembered for a reconciliation answers its count — and every count it
/// decides — without asking.
@Suite("The questions about the counts of a day")
struct CountQuestionsTests {
  typealias Fx = CashFx

  static let calendar = CalendarContext.utc
  static let day = Fx.day("2026-09-18")
  static let early = Fx.at("2026-09-18", 10)
  static let late = Fx.at("2026-09-18", 18)
  static let noon = calendar.noon(of: day)

  static let first = Fx.id(701)
  static let second = Fx.id(702)
  static let third = Fx.id(703)

  // MARK: The walk

  /// Two counts on the day — 10:00 and 18:00 —: the earlier is asked first, «Нет» asks about the
  /// later, «Да» to the later puts the movement between them, «Нет» to both after 18:00, «Да» to
  /// the first before 10:00.
  @Test func twoCountsAreAskedAboutInTurn() {
    let first = CountQuestions(
      counts: [Self.early, Self.late], occurredAt: Self.noon, calendar: Self.calendar)
    #expect(first.count == Self.early)
    #expect(first.index == 0)
    #expect(first.reconciliation == nil)
    guard case .ask(let second) = first.answer(wasBefore: false) else {
      Issue.record("«Нет» to 10:00 asks about 18:00")
      return
    }
    #expect(second.count == Self.late)
    #expect(second.index == 1)
    guard case .stamp(let between) = second.answer(wasBefore: true) else {
      Issue.record("«Да» stamps")
      return
    }
    #expect(between > Self.early)
    #expect(between < Self.late)
    guard case .stamp(let before) = first.answer(wasBefore: true) else {
      Issue.record("«Да» stamps")
      return
    }
    #expect(before < Self.early)
    guard case .stamp(let after) = second.answer(wasBefore: false) else {
      Issue.record("«Нет» to the last count stamps")
      return
    }
    #expect(after > Self.late)
  }

  /// «Да» to the only count keeps a moment that is before it already, as an operation keeps
  /// its own; «Нет» puts it after the count on the same day.
  @Test func yesKeepsAMomentBeforeTheCount() {
    let nine = Fx.at("2026-09-18", 9)
    let questions = CountQuestions(
      counts: [Self.early], occurredAt: nine, calendar: Self.calendar)
    guard case .stamp(let yes) = questions.answer(wasBefore: true) else {
      Issue.record("«Да» to the only count stamps")
      return
    }
    #expect(yes == nine)
    guard case .stamp(let no) = questions.answer(wasBefore: false) else {
      Issue.record("«Нет» to the only count stamps")
      return
    }
    #expect(no > Self.early)
    #expect(Self.calendar.day(of: no) == Self.day)
  }

  /// No answer moves a movement to another day: «Да» to a count at midnight keeps it on the
  /// count's day, «Нет» to one in the last second of the day keeps it on that day after the
  /// count, and «Да» to the second of two counts in the first second of the day puts it between
  /// them, still on that day.
  @Test func theAnswersNeverMoveToAnotherDay() {
    let midnight = Self.calendar.startOfDay(Self.day)
    let atMidnight = CountQuestions(
      counts: [midnight], occurredAt: Self.noon, calendar: Self.calendar)
    guard case .stamp(let yes) = atMidnight.answer(wasBefore: true) else {
      Issue.record("«Да» stamps")
      return
    }
    #expect(Self.calendar.day(of: yes) == Self.day)
    #expect(yes <= midnight)

    let lastSecond = Self.calendar.startOfDay(Self.day.adding(days: 1)).addingTimeInterval(-1)
    let atLastSecond = CountQuestions(
      counts: [lastSecond], occurredAt: Self.noon, calendar: Self.calendar)
    guard case .stamp(let no) = atLastSecond.answer(wasBefore: false) else {
      Issue.record("«Нет» to the only count stamps")
      return
    }
    #expect(Self.calendar.day(of: no) == Self.day)
    #expect(no > lastSecond)

    let halfASecond = midnight.addingTimeInterval(0.5)
    let two = CountQuestions(
      counts: [midnight, halfASecond], occurredAt: Self.noon, calendar: Self.calendar)
    guard case .ask(let next) = two.answer(wasBefore: false),
      case .stamp(let between) = next.answer(wasBefore: true)
    else {
      Issue.record("«Нет», then «Да» stamps")
      return
    }
    #expect(Self.calendar.day(of: between) == Self.day)
    #expect(between > midnight)
    #expect(between < halfASecond)
  }

  /// The reconciliation of the count asked about goes with it.
  @Test func eachCountCarriesItsReconciliation() {
    let questions = CountQuestions(
      counts: [Self.early, Self.late], reconciliations: [Self.first, Self.second],
      occurredAt: Self.noon, calendar: Self.calendar)
    #expect(questions.reconciliation == Self.first)
    guard case .ask(let next) = questions.answer(wasBefore: false) else {
      Issue.record("«Нет» asks about the next count")
      return
    }
    #expect(next.reconciliation == Self.second)
  }

  // MARK: Remembered answers

  /// Nothing remembered: the walk starts at the first count; no counts, no walk.
  @Test func withNothingRememberedTheFirstCountIsAsked() {
    let step = CountQuestions.start(
      counts: [Self.early, Self.late], reconciliations: [Self.first, Self.second],
      occurredAt: Self.noon, calendar: Self.calendar, remembered: [Self.third: true])
    guard case .ask(let questions) = step else {
      Issue.record("asks")
      return
    }
    #expect(questions.index == 0)
    #expect(questions.count == Self.early)
    #expect(
      CountQuestions.start(
        counts: [], reconciliations: [], occurredAt: Self.noon, calendar: Self.calendar,
        remembered: [:]) == nil)
  }

  /// «Нет, после» remembered for the later count answers both: the movement is after 18:00, and
  /// nothing is asked.
  @Test func rememberedAfterAtTheLaterCountAnswersBoth() {
    let step = CountQuestions.start(
      counts: [Self.early, Self.late], reconciliations: [Self.first, Self.second],
      occurredAt: Self.noon, calendar: Self.calendar, remembered: [Self.second: false])
    guard case .stamp(let stamp) = step else {
      Issue.record("nothing is asked")
      return
    }
    #expect(stamp > Self.late)
    #expect(Self.calendar.day(of: stamp) == Self.day)
  }

  /// «Да, до» remembered for the earlier count answers both: the movement is before 10:00.
  @Test func rememberedBeforeAtTheEarlierCountAnswersBoth() {
    let step = CountQuestions.start(
      counts: [Self.early, Self.late], reconciliations: [Self.first, Self.second],
      occurredAt: Self.noon, calendar: Self.calendar, remembered: [Self.first: true])
    guard case .stamp(let stamp) = step else {
      Issue.record("nothing is asked")
      return
    }
    #expect(stamp < Self.early)
    #expect(stamp == Self.early.addingTimeInterval(-1))
  }

  /// Three counts, the middle one remembered: «после» asks only about the last, and its «Да»
  /// puts the movement between the middle and the last; «до» asks only about the first, and
  /// its «Нет» puts the movement between the first and the middle — the remembered count is
  /// never asked.
  @Test func aRememberedAnswerBetweenAsksOnlyTheOpenOnes() {
    let middle = Fx.at("2026-09-18", 14)
    let counts = [Self.early, middle, Self.late]
    let reconciliations = [Self.first, Self.second, Self.third]

    let afterMiddle = CountQuestions.start(
      counts: counts, reconciliations: reconciliations, occurredAt: Self.noon,
      calendar: Self.calendar, remembered: [Self.second: false])
    guard case .ask(let last) = afterMiddle else {
      Issue.record("the last count is asked")
      return
    }
    #expect(last.count == Self.late)
    #expect(last.reconciliation == Self.third)
    guard case .stamp(let between) = last.answer(wasBefore: true) else {
      Issue.record("«Да» stamps")
      return
    }
    #expect(between > middle)
    #expect(between < Self.late)
    guard case .stamp(let afterAll) = last.answer(wasBefore: false) else {
      Issue.record("«Нет» stamps")
      return
    }
    #expect(afterAll > Self.late)

    let beforeMiddle = CountQuestions.start(
      counts: counts, reconciliations: reconciliations, occurredAt: Self.noon,
      calendar: Self.calendar, remembered: [Self.second: true])
    guard case .ask(let firstOne) = beforeMiddle else {
      Issue.record("the first count is asked")
      return
    }
    #expect(firstOne.count == Self.early)
    guard case .stamp(let inside) = firstOne.answer(wasBefore: false) else {
      Issue.record("«Нет» to the first stamps: the middle one is answered")
      return
    }
    #expect(inside > Self.early)
    #expect(inside < middle)
    guard case .stamp(let beforeAll) = firstOne.answer(wasBefore: true) else {
      Issue.record("«Да» stamps")
      return
    }
    #expect(beforeAll < Self.early)
  }

  /// Both ends remembered: «после» for the first and «до» for the last settle the movement
  /// between them; a count whose reconciliation is not known is asked like any other.
  @Test func bothEndsRememberedSettleTheMiddle() {
    let step = CountQuestions.start(
      counts: [Self.early, Self.late], reconciliations: [Self.first, Self.second],
      occurredAt: Self.noon, calendar: Self.calendar,
      remembered: [Self.first: false, Self.second: true])
    guard case .stamp(let between) = step else {
      Issue.record("nothing is asked")
      return
    }
    #expect(between > Self.early)
    #expect(between < Self.late)

    let unknown = CountQuestions.start(
      counts: [Self.early, Self.late], reconciliations: [nil, Self.second],
      occurredAt: Self.noon, calendar: Self.calendar, remembered: [Self.second: true])
    guard case .ask(let asked) = unknown else {
      Issue.record("the count of no known reconciliation is asked")
      return
    }
    #expect(asked.count == Self.early)
    #expect(asked.reconciliation == nil)
  }
}
