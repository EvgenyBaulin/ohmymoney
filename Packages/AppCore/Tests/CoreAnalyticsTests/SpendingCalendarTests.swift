import Foundation
import Testing

@testable import CoreAnalytics
@testable import CoreKit

/// «Календарь трат»: the weeks of a month or one week, my spending of each day by the ledger's
/// rule without the differences of reconciliations, the level of a day against the usual one,
/// and the plans of the days ahead.
@Suite("The spending calendar")
struct SpendingCalendarTests {
  private let today = DateOnly(year: 2026, month: 10, day: 14)  // a Wednesday
  private let food = CoreKit.Category(kind: .expense, name: "Food")

  private func day(_ month: Int, _ day: Int) -> DateOnly {
    DateOnly(year: 2026, month: month, day: day)
  }

  private func entry(
    _ whole: Int64, on day: DateOnly, kind: TransactionKind = .expense,
    category: CoreKit.Category? = nil, reimbursable: Bool = false, externalId: String? = nil
  ) throws -> TransactionEntry {
    var draft = TransactionDraft(
      kind: kind, occurredAt: CalendarContext.utc.startOfDay(day).addingTimeInterval(3600),
      amount: AmountE4(whole: whole))
    var part = PartDraft(categoryId: (category ?? food).id, amount: AmountE4(whole: whole))
    if reimbursable {
      part.reimbursable = true
      part.debtorPersonId = UUID()
      part.reimbursementStatus = .expected
    }
    draft.parts = [part]
    var entry = try draft.materialize(timeZone: CalendarContext.utc.timeZone)
    entry.transaction.externalId = externalId
    return entry
  }

  private func ledger(
    _ entries: [TransactionEntry], book: PlanningBook = PlanningBook(),
    categories: [CoreKit.Category] = []
  )
    -> Ledger
  {
    Ledger(
      dataset: Dataset(entries: entries, categories: [food] + categories, planning: book),
      calendar: .utc)
  }

  /// `count` days of 1 000 each, the days just before `before`.
  private func history(
    _ count: Int, before: DateOnly, whole: Int64 = 1_000
  ) throws
    -> [TransactionEntry]
  {
    try (1...count).map { try entry(whole, on: before.adding(days: -$0)) }
  }

  // MARK: - Weeks

  @Test func russianWeeksStartOnMondayOthersFollowTheMac() {
    #expect(SpendingCalendar.firstWeekday(languageCode: "ru", systemFirstWeekday: 1) == 1)
    #expect(SpendingCalendar.firstWeekday(languageCode: "en", systemFirstWeekday: 1) == 7)
    #expect(SpendingCalendar.firstWeekday(languageCode: "en", systemFirstWeekday: 2) == 1)
    #expect(SpendingCalendar.firstWeekday(languageCode: "en", systemFirstWeekday: 7) == 6)
    #expect(SpendingCalendar.firstWeekday(languageCode: nil, systemFirstWeekday: 0) == 1)
    #expect(SpendingCalendar.weekdays(startingWith: 7) == [7, 1, 2, 3, 4, 5, 6])
    #expect(SpendingCalendar.weekdays(startingWith: 1) == [1, 2, 3, 4, 5, 6, 7])
  }

  /// October 2026 begins on a Thursday and ends on a Saturday: from Monday 28 September to
  /// Sunday 1 November, five whole weeks; from Sunday, 27 September to Saturday 31 October.
  @Test func aMonthIsWholeWeeksAroundIt() {
    let monday = SpendingCalendar.range(scope: .month, anchor: today, firstWeekday: 1)
    #expect(monday.start == day(9, 28))
    #expect(monday.end == day(11, 1))
    #expect(monday.dayCount == 35)
    let sunday = SpendingCalendar.range(scope: .month, anchor: today, firstWeekday: 7)
    #expect(sunday.start == day(9, 27))
    #expect(sunday.end == day(10, 31))
    let week = SpendingCalendar.range(scope: .week, anchor: today, firstWeekday: 1)
    #expect(week == DayRange(day(10, 12), day(10, 18)))
  }

  @Test func stepsGoByMonthsAndWeeks() {
    #expect(SpendingCalendar.step(day(1, 31), scope: .month, by: 1) == day(2, 1))
    #expect(
      SpendingCalendar.step(day(1, 31), scope: .month, by: -1)
        == DateOnly(year: 2025, month: 12, day: 1))
    #expect(SpendingCalendar.step(today, scope: .week, by: -1) == day(10, 7))
  }

  @Test func theGridIsRowsOfSevenWithTheNeighboursOutOfScope() throws {
    let calendar = SpendingCalendar.build(
      ledger: ledger([]), scope: .month, anchor: today, today: today, firstWeekday: 1)
    #expect(calendar.weeks.count == 5)
    #expect(calendar.weeks.allSatisfy { $0.count == 7 })
    #expect(calendar.days.count == 31)
    #expect(calendar.day(day(9, 30))?.inScope == false)
    #expect(calendar.day(day(10, 1))?.inScope == true)
    #expect(calendar.day(today)?.isToday == true)
    #expect(calendar.day(day(10, 15))?.isFuture == true)
    #expect(calendar.day(day(10, 15))?.spent == nil)
    #expect(calendar.day(day(10, 13))?.spent == .zero)
    #expect(calendar.weekdays == [1, 2, 3, 4, 5, 6, 7])
  }

  // MARK: - My spending of a day

  /// The ledger's rule: my spending, a part paid for somebody else not yet, income never, a
  /// refund taken back in the purchase.
  @Test func aDayIsMyExpensesByTheLedgersRule() throws {
    let entries = [
      try entry(1_200, on: day(10, 5)),
      try entry(800, on: day(10, 5), reimbursable: true),
      try entry(50_000, on: day(10, 5), kind: .income),
    ]
    let calendar = SpendingCalendar.build(
      ledger: ledger(entries), scope: .month, anchor: today, today: today, firstWeekday: 1)
    let fifth = try #require(calendar.day(day(10, 5)))
    #expect(fifth.spent == AmountE4(whole: 1_200))
    // Every operation of the day is listed, the income too.
    #expect(Set(fifth.transactionIds) == Set(entries.map(\.id)))
    #expect(calendar.spent == AmountE4(whole: 1_200))
  }

  /// A reconciliation's difference is no purchase: by its link or by «Сверка».
  @Test func aCountDifferenceIsNoSpending() throws {
    let counts = CoreKit.Category(kind: .expense, name: "Сверка")
    var book = PlanningBook()
    book.settings.reconcileExpenseCategoryId = counts.id
    let entries = [
      try entry(300, on: day(10, 6)),
      try entry(9_000, on: day(10, 6), category: counts),
      try entry(
        7_000, on: day(10, 6),
        externalId: "reconcile:\(UUID().uuidString.lowercased()):\(UUID().uuidString.lowercased())"),
    ]
    let calendar = SpendingCalendar.build(
      ledger: ledger(entries, book: book, categories: [counts]), scope: .week, anchor: day(10, 6),
      today: today, firstWeekday: 1)
    #expect(calendar.day(day(10, 6))?.spent == AmountE4(whole: 300))
    #expect(calendar.spent == AmountE4(whole: 300))
  }

  /// The figures are whole units: rubles rounded half away from zero, the total rounded once.
  @Test func figuresAreRoundedToTheRuble() throws {
    var first = TransactionDraft(
      occurredAt: CalendarContext.utc.startOfDay(day(10, 2)), amount: AmountE4(raw: 1_004_000))
    first.parts = [PartDraft(categoryId: food.id, amount: AmountE4(raw: 1_004_000))]
    var second = TransactionDraft(
      occurredAt: CalendarContext.utc.startOfDay(day(10, 3)), amount: AmountE4(raw: 1_004_000))
    second.parts = [PartDraft(categoryId: food.id, amount: AmountE4(raw: 1_004_000))]
    let calendar = SpendingCalendar.build(
      ledger: ledger([
        try first.materialize(timeZone: CalendarContext.utc.timeZone),
        try second.materialize(timeZone: CalendarContext.utc.timeZone),
      ]), scope: .month,
      anchor: today, today: today, firstWeekday: 1)
    #expect(calendar.day(day(10, 2))?.spent == AmountE4(whole: 100))  // 100.40
    #expect(calendar.spent == AmountE4(whole: 201))  // 200.80
  }

  /// Another default currency: at today's rate; without a rate, rubles.
  @Test func theDefaultCurrencyAtTodaysRateOrRubles() throws {
    let entries = [try entry(9_000, on: day(10, 2))]
    let inDollars = SpendingCalendar.build(
      ledger: ledger(entries), scope: .month, anchor: today, today: today, firstWeekday: 1,
      currency: .usd, rubPerUnit: [.usd: 90])
    #expect(inDollars.currency == .usd)
    #expect(inDollars.day(day(10, 2))?.spent == AmountE4(whole: 100))
    let noRate = SpendingCalendar.build(
      ledger: ledger(entries), scope: .month, anchor: today, today: today, firstWeekday: 1,
      currency: .usd)
    #expect(noRate.currency == .rub)
    #expect(noRate.day(day(10, 2))?.spent == AmountE4(whole: 9_000))
  }

  // MARK: - Usual and levels

  @Test func levelsAreOneAndAHalfAndThreeTimesUsual() {
    let usual = AmountE4(whole: 1_000)
    #expect(SpendingCalendar.level(spent: AmountE4(whole: 1_499), usual: usual) == .usual)
    #expect(SpendingCalendar.level(spent: AmountE4(whole: 1_500), usual: usual) == .higher)
    #expect(SpendingCalendar.level(spent: AmountE4(whole: 2_999), usual: usual) == .higher)
    #expect(SpendingCalendar.level(spent: AmountE4(whole: 3_000), usual: usual) == .muchHigher)
    #expect(SpendingCalendar.level(spent: AmountE4(whole: 5), usual: .zero) == .usual)
  }

  /// The usual day is the median of the days with spending before it; the days without
  /// spending do not pull it down.
  @Test func theUsualDayIsTheMedianOfDaysWithSpending() throws {
    var entries = try history(30, before: day(10, 10))
    entries.append(try entry(2_000, on: day(10, 10)))
    entries.append(try entry(5_000, on: day(10, 11)))
    entries.append(try entry(1_100, on: day(10, 12)))
    let calendar = SpendingCalendar.build(
      ledger: ledger(entries), scope: .week, anchor: today, today: today, firstWeekday: 1)
    #expect(calendar.day(day(10, 12))?.level == .usual)
    let month = SpendingCalendar.build(
      ledger: ledger(entries), scope: .month, anchor: today, today: today, firstWeekday: 1)
    #expect(month.day(day(10, 10))?.level == .higher)
    #expect(month.day(day(10, 11))?.level == .muchHigher)
    // A day without spending has no level, however usual.
    #expect(month.day(day(10, 13))?.level == nil)
    #expect(month.usual == AmountE4(whole: 1_000))
    #expect(!month.lowData)
  }

  /// Fewer than fourteen days with spending in the 90 before: no level, and the calendar says
  /// there is too little data.
  @Test func tooLittleHistoryGivesNoLevel() throws {
    var entries = try history(12, before: day(10, 10))
    entries.append(try entry(9_000, on: day(10, 10)))
    let calendar = SpendingCalendar.build(
      ledger: ledger(entries), scope: .week, anchor: day(10, 10), today: today, firstWeekday: 1)
    #expect(calendar.day(day(10, 10))?.level == nil)
    #expect(calendar.lowData)
    #expect(calendar.usual == nil)
    // Days older than 90 do not count.
    let old = try (91...110).map { try entry(1_000, on: day(10, 10).adding(days: -$0)) }
    let stale = SpendingCalendar.build(
      ledger: ledger(old + [try entry(9_000, on: day(10, 10))]), scope: .week,
      anchor: day(10, 10), today: today, firstWeekday: 1)
    #expect(stale.day(day(10, 10))?.level == nil)
  }

  // MARK: - Plans

  @Test func plansGoOnTodayAndTheDaysAheadOnly() throws {
    let rent = CalendarPlan(
      kind: .payment, sourceId: UUID(), day: day(10, 20), name: "Rent",
      amount: AmountE4(whole: 30_000), currency: .rub)
    let netflix = CalendarPlan(
      kind: .payment, sourceId: UUID(), day: day(10, 20), name: "Netflix",
      amount: AmountE4(whole: 10), currency: .usd)
    let salary = CalendarPlan(
      kind: .income, sourceId: UUID(), day: day(10, 20), name: "Salary",
      amount: AmountE4(whole: 100_000), currency: .rub)
    let past = CalendarPlan(
      kind: .payment, sourceId: UUID(), day: day(10, 10), name: "Old",
      amount: AmountE4(whole: 1), currency: .rub)
    let eur = CalendarPlan(
      kind: .payment, sourceId: UUID(), day: today, name: "Gym",
      amount: AmountE4(whole: 5), currency: .eur)
    let calendar = SpendingCalendar.build(
      ledger: ledger([]), scope: .month, anchor: today, today: today, firstWeekday: 1,
      plans: [rent, netflix, salary, past, eur], rubPerUnit: [.usd: 90])
    let twentieth = try #require(calendar.day(day(10, 20)))
    #expect(twentieth.plans.map(\.name) == ["Netflix", "Rent", "Salary"])
    #expect(twentieth.plannedOut == AmountE4(whole: 30_900))
    #expect(twentieth.plannedIn == AmountE4(whole: 100_000))
    #expect(!twentieth.plansWithoutRate)
    #expect(calendar.day(day(10, 10))?.plans.isEmpty == true)
    // Today has its plans too; a currency without a rate is left out of the sum and said.
    let todays = try #require(calendar.day(today))
    #expect(todays.plans == [eur])
    #expect(todays.plannedOut == nil)
    #expect(todays.plansWithoutRate)
  }
}
