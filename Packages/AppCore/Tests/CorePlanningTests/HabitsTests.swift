import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CorePlanning

/// Synthetic days and operations for the rules of the habits. The calendar is Moscow's; every
/// moment is made in it, so the tests read the same in every zone of the Mac.
enum HabitFixture {
  static let calendar = CalendarContext.moscow

  static func day(_ year: Int, _ month: Int, _ day: Int) -> DateOnly {
    DateOnly(year: year, month: month, day: day)
  }

  /// 2026-11-02 is a Monday.
  static let monday = day(2026, 11, 2)

  static func days(_ from: DateOnly, _ count: Int) -> Set<DateOnly> {
    Set((0..<count).map { from.adding(days: $0) })
  }

  /// An operation written at noon of `written`, about `about` (the same day by default).
  static func entry(
    written: DateOnly, about: DateOnly? = nil, source: String? = nil, externalId: String? = nil,
    importBatch: UUID? = nil, deleted: Bool = false, amount: Int64 = 300
  ) -> TransactionEntry {
    let createdAt = calendar.noon(of: written)
    let transaction = Transaction(
      kind: .expense, occurredAt: calendar.noon(of: about ?? written),
      amountE4: AmountE4(whole: amount), importBatchId: importBatch, externalId: externalId,
      createdAt: createdAt, updatedAt: createdAt, deletedAt: deleted ? createdAt : nil,
      source: source)
    return TransactionEntry(
      transaction: transaction,
      parts: [TransactionPart(transactionId: transaction.id, amountE4: AmountE4(whole: amount))])
  }
}

@Suite("Habits: days of entry")
struct HabitEntryDaysTests {
  typealias F = HabitFixture

  @Test("an operation counts on the day it was written, not the day it is about")
  func writtenDay() {
    let entry = F.entry(written: F.monday, about: F.monday.adding(days: -3))
    #expect(HabitEntryDays.typedDays([entry], calendar: F.calendar) == [F.monday])
  }

  @Test("lines of the app, imports, statements and deleted operations are not entry")
  func notTyped() {
    let day = F.monday
    let entries = [
      F.entry(written: day, externalId: "sched:abc"),
      F.entry(written: day, externalId: "ccinterest:x:2026-11-02"),
      F.entry(written: day, importBatch: UUID()),
      F.entry(written: day, source: "statement"),
      F.entry(written: day, source: "receipt"),
      F.entry(written: day, deleted: true),
    ]
    #expect(HabitEntryDays.typedDays(entries, calendar: F.calendar).isEmpty)
    #expect(HabitEntryDays.lastTyped(entries) == nil)
    let manual = F.entry(written: day.adding(days: 1), source: "manual")
    #expect(
      HabitEntryDays.typedDays(entries + [manual], calendar: F.calendar) == [day.adding(days: 1)])
  }

  @Test("a day marked «трат не было» is a day of entry")
  func noSpendCounts() {
    let days = HabitEntryDays.days([], noSpend: [F.monday], calendar: F.calendar)
    #expect(days == [F.monday])
  }
}

@Suite("Habits: the streak")
struct EntryStreakTests {
  typealias F = HabitFixture

  @Test("seven days in a row are a streak of seven")
  func plain() throws {
    let days = F.days(F.monday, 7)
    let streak = try #require(EntryStreaks.current(days: days, today: F.monday.adding(days: 6)))
    #expect(streak.length == 7)
    #expect(streak.start == F.monday)
    #expect(streak.forgiven.isEmpty)
  }

  @Test("one day missed in a week does not break the streak and counts in its length")
  func oneMissForgiven() throws {
    var days = F.days(F.monday, 7)
    days.remove(F.monday.adding(days: 2))  // Wednesday
    let streak = try #require(EntryStreaks.current(days: days, today: F.monday.adding(days: 6)))
    #expect(streak.length == 7)
    #expect(streak.forgiven == [F.monday.adding(days: 2)])
  }

  @Test("a second day missed in the same week breaks it")
  func twoMissesBreak() {
    var days = F.days(F.monday, 7)
    days.remove(F.monday.adding(days: 1))  // Tuesday
    days.remove(F.monday.adding(days: 4))  // Friday
    let runs = EntryStreaks.runs(days: days, today: F.monday.adding(days: 6))
    #expect(runs.map(\.length) == [4, 2])  // Mon–Thu (Tue forgiven), then Sat–Sun
    #expect(runs.first?.end == F.monday.adding(days: 3))
  }

  @Test("a day missed in each of two weeks is forgiven both times, even side by side")
  func adjacentWeeks() throws {
    var days = F.days(F.monday, 14)
    days.remove(F.monday.adding(days: 6))  // Sunday of the first week
    days.remove(F.monday.adding(days: 7))  // Monday of the second
    let streak = try #require(EntryStreaks.current(days: days, today: F.monday.adding(days: 13)))
    #expect(streak.length == 14)
    #expect(streak.forgiven.count == 2)
  }

  @Test("today without entry yet breaks nothing")
  func todayOpen() throws {
    let days = F.days(F.monday, 5)  // Monday to Friday
    let streak = try #require(EntryStreaks.current(days: days, today: F.monday.adding(days: 5)))
    #expect(streak.length == 5)
  }

  @Test("a streak whose week already had a forgiven day ends after a second gap up to yesterday")
  func endedBeforeToday() {
    var days = F.days(F.monday, 3)  // Mon–Wed
    days.insert(F.monday.adding(days: 4))  // Friday; Thursday missed, forgiven
    // Saturday missed: the second day of the week. Today is Sunday.
    #expect(EntryStreaks.current(days: days, today: F.monday.adding(days: 6)) == nil)
  }

  @Test("a day marked «трат не было» keeps the streak")
  func noSpendKeepsIt() throws {
    let typed = F.days(F.monday, 3).subtracting([F.monday.adding(days: 1)])
    let days = HabitEntryDays.days([], noSpend: [F.monday.adding(days: 1)], calendar: F.calendar)
      .union(typed)
    let streak = try #require(EntryStreaks.current(days: days, today: F.monday.adding(days: 2)))
    #expect(streak.length == 3)
    #expect(streak.forgiven.isEmpty)
  }

  @Test("no day of entry, no streak")
  func none() {
    #expect(EntryStreaks.runs(days: [], today: F.monday).isEmpty)
    #expect(EntryStreaks.current(days: [], today: F.monday) == nil)
  }
}

@Suite("Habits: badges")
struct HabitBadgesTests {
  typealias F = HabitFixture
  let now = Date(timeIntervalSince1970: 1_800_000_000)

  @Test("a streak of seven earns «7 дней», of thirty «30 дней», keyed by its first day")
  func streakBadges() {
    let days = F.days(F.monday, 30)
    let badges = HabitBadges.earned(
      entryDays: days, reconciliations: [], today: F.monday.adding(days: 29), at: now)
    #expect(badges.map(\.kind) == [.entry7, .entry30])
    #expect(badges.allSatisfy { $0.period == F.monday.iso })
    #expect(badges.first?.earnedOn == F.monday.adding(days: 6))
    #expect(badges.first?.key == "entry7:\(F.monday.iso)")
  }

  @Test("six days earn nothing")
  func shortStreak() {
    let badges = HabitBadges.earned(
      entryDays: F.days(F.monday, 6), reconciliations: [], today: F.monday.adding(days: 5),
      at: now)
    #expect(badges.isEmpty)
  }

  @Test(
    "a month with a count earns a badge; openings are not counts; three months in a row earn a series"
  )
  func countBadges() {
    func count(_ day: DateOnly, _ kind: ReconciliationKind = .accounts) -> Reconciliation {
      Reconciliation(date: day, actualTotalRubE4: .zero, kind: kind)
    }
    let reconciliations = [
      count(F.day(2026, 8, 1), .opening),
      count(F.day(2026, 8, 20)), count(F.day(2026, 8, 5)),
      count(F.day(2026, 9, 30)), count(F.day(2026, 10, 15), .total),
    ]
    let badges = HabitBadges.earned(
      entryDays: [], reconciliations: reconciliations, today: F.day(2026, 11, 1), at: now)
    let months = badges.filter { $0.kind == .countMonth }
    #expect(months.map(\.period) == ["2026-08", "2026-09", "2026-10"])
    #expect(months.first?.earnedOn == F.day(2026, 8, 5))
    let series = badges.filter { $0.kind == .count3 }
    #expect(series.map(\.period) == ["2026-08"])
    #expect(series.first?.earnedOn == F.day(2026, 10, 15))
    #expect(!badges.contains { $0.kind == .count12 })
  }

  @Test("only badges not written yet are new")
  func onlyNew() {
    let earned = HabitBadges.earned(
      entryDays: F.days(F.monday, 30), reconciliations: [], today: F.monday.adding(days: 29),
      at: now)
    let stored = [earned[0]]
    #expect(HabitBadges.new(earned, stored: stored).map(\.kind) == [.entry30])
    #expect(HabitBadges.new(earned, stored: earned).isEmpty)
  }

  @Test("a period shows the badges earned within its days")
  func inPeriod() {
    let earned = HabitBadges.earned(
      entryDays: F.days(F.monday, 30), reconciliations: [], today: F.monday.adding(days: 29),
      at: now)
    let firstWeek = DayRange(F.monday, F.monday.adding(days: 6))
    #expect(HabitBadges.earned(in: firstWeek, of: earned).map(\.kind) == [.entry7])
  }
}

@Suite("Habits: the days missed")
struct MissedDaysTests {
  typealias F = HabitFixture

  @Test("whole days without entry reach the setting: the line comes, with the days through today")
  func gap() throws {
    let last = F.monday
    let today = last.adding(days: 4)  // three whole days between
    let gap = try #require(
      HabitNotes.missedDays(entryDays: [last], settings: HabitSettings(), today: today))
    #expect(gap.count == 3)
    #expect(gap.days == [1, 2, 3, 4].map { last.adding(days: $0) })
    #expect(gap.id == "habits.missed:\(last.iso)")
  }

  @Test("a shorter gap, a longer setting and no entry at all give no line")
  func noGap() {
    let last = F.monday
    #expect(
      HabitNotes.missedDays(
        entryDays: [last], settings: HabitSettings(), today: last.adding(days: 3))
        == nil)
    #expect(
      HabitNotes.missedDays(
        entryDays: [last], settings: HabitSettings(missedDaysAfter: 5), today: last.adding(days: 4))
        == nil)
    #expect(HabitNotes.missedDays(entryDays: [], settings: HabitSettings(), today: last) == nil)
  }

  @Test("the setting stays within its range")
  func settingRange() {
    #expect(HabitSettings(missedDaysAfter: 0).missedDaysAfter == 2)
    #expect(HabitSettings(missedDaysAfter: 99).missedDaysAfter == 14)
    #expect(HabitSettings(storedValues: [:]).missedDaysAfter == 3)
    #expect(
      HabitSettings(storedValues: [HabitSettings.missedDaysAfterKey: "5"]).missedDaysAfter == 5)
    #expect(
      HabitSettings(storedValues: [HabitSettings.missedDaysAfterKey: "x"]).missedDaysAfter == 3)
  }

  @Test("the money missing is spread over the days in whole units and adds up exactly")
  func spread() {
    let key = BalanceKey(accountId: UUID(), currency: .rub)
    let days = (1...3).map { F.monday.adding(days: $0) }
    let missing = AmountE4(raw: 1_000_0050)  // 1,000.005
    let lines = MissedDaysWizard.spread(missing, over: days, key: key)
    #expect(
      lines.map(\.amountE4) == [
        AmountE4(whole: 333), AmountE4(whole: 333), AmountE4(raw: 334_0050),
      ])
    #expect(AmountE4.sum(lines.map(\.amountE4)) == missing)
    #expect(MissedDaysWizard.left(missing, lines: lines, key: key).isZero)
    #expect(MissedDaysWizard.spread(.zero, over: days, key: key).isEmpty)
    #expect(MissedDaysWizard.spread(AmountE4(whole: -5), over: days, key: key).isEmpty)
  }

  @Test("restored = expected − counted: the shortfall is the difference of the balances")
  func restoredEqualsDifference() throws {
    let key = BalanceKey(accountId: UUID(), currency: .rub)
    let expected = AmountE4(whole: 12_000)
    let actual = AmountE4(whole: 9_550)
    let missing = MissedDaysWizard.shortfall(expected: expected, actual: actual)
    var lines = MissedDaysWizard.spread(
      missing, over: [F.monday, F.monday.adding(days: 1)], key: key)
    #expect(AmountE4.sum(lines.map(\.amountE4)) == expected - actual)
    let category = UUID()
    #expect(MissedDaysWizard.problem(lines: lines, missing: [key: missing]) == .lineWithoutCategory)
    for index in lines.indices { lines[index].categoryId = category }
    #expect(MissedDaysWizard.problem(lines: lines, missing: [key: missing]) == nil)
    lines[0].amountE4 = lines[0].amountE4 - AmountE4(whole: 1)
    #expect(MissedDaysWizard.problem(lines: lines, missing: [key: missing]) == .notLaidOut(key))
    #expect(MissedDaysWizard.problem(lines: [], missing: [key: missing]) == .noLines)
  }

  @Test("the wizard asks about counted balances of accounts in the summary only")
  func balances() {
    let shown = PaymentMethod(name: "Card")
    let archived = PaymentMethod(name: "Old", archived: true)
    let outside = PaymentMethod(name: "Abroad")
    func line(
      _ account: PaymentMethod, balance: AmountE4?, anchored: Bool
    ) -> AccountsSnapshot.AccountLine {
      AccountsSnapshot.AccountLine(
        account: account,
        keys: [
          AccountsSnapshot.KeyLine(
            key: BalanceKey(accountId: account.id, currency: .rub), balance: balance, rub: balance,
            anchorAt: anchored ? Date(timeIntervalSince1970: 0) : nil, isHeld: true)
        ], totalRub: balance, unknown: 0)
    }
    let never = PaymentMethod(name: "Never counted")
    let snapshot = AccountsSnapshot(
      sections: [
        AccountsSnapshot.Section(
          group: nil,
          accounts: [
            line(shown, balance: AmountE4(whole: 100), anchored: true),
            line(archived, balance: AmountE4(whole: 5), anchored: true),
            line(never, balance: nil, anchored: false),
          ], totalRub: nil, inSummary: true),
        AccountsSnapshot.Section(
          group: AccountGroup(name: "Abroad", inSummary: false),
          accounts: [line(outside, balance: AmountE4(whole: 7), anchored: true)], totalRub: nil,
          inSummary: false),
      ], inSummaryTotalRub: nil, unanchored: [], withoutRate: [], balances: .empty)
    let asked = MissedDaysWizard.balances(snapshot)
    #expect(asked.map(\.account.id) == [shown.id])
    #expect(asked.first?.expected == AmountE4(whole: 100))
  }
}

@Suite("Habits: the evening")
struct EveningTests {
  typealias F = HabitFixture

  @Test("in the evening of a day without entry the question comes, with the streak")
  func evening() throws {
    let today = F.monday.adding(days: 3)
    let days = F.days(F.monday, 3)
    let at = F.calendar.moment(today, hour: 20, minute: 30)
    let notes = HabitNotes.list(
      entryDays: days, settings: HabitSettings(), today: today, now: at, calendar: F.calendar)
    guard case .evening(let check) = try #require(notes.first) else {
      Issue.record("no question of the evening")
      return
    }
    #expect(check.streakDays == 3)
    #expect(check.remind)
  }

  @Test("before the evening, after an entry today, or switched off — no question")
  func noEvening() {
    let today = F.monday.adding(days: 3)
    let days = F.days(F.monday, 3)
    let afternoon = F.calendar.moment(today, hour: 15, minute: 0)
    let evening = F.calendar.moment(today, hour: 21, minute: 0)
    #expect(
      HabitNotes.list(
        entryDays: days, settings: HabitSettings(), today: today, now: afternoon,
        calendar: F.calendar
      ).isEmpty)
    #expect(
      HabitNotes.list(
        entryDays: days.union([today]), settings: HabitSettings(), today: today, now: evening,
        calendar: F.calendar
      ).isEmpty)
    #expect(
      HabitNotes.list(
        entryDays: days, settings: HabitSettings(), today: today, now: evening,
        calendar: F.calendar, eveningEnabled: false
      ).isEmpty)
    let id = EveningCheck(day: today, streakDays: nil, remind: true).id
    #expect(
      HabitNotes.list(
        entryDays: days, settings: HabitSettings(), today: today, now: evening,
        calendar: F.calendar, dismissed: [id]
      ).isEmpty)
  }

  @Test("a gap of days shows the wizard line instead of the question")
  func gapFirst() throws {
    let today = F.monday.adding(days: 6)
    let evening = F.calendar.moment(today, hour: 21, minute: 0)
    let notes = HabitNotes.list(
      entryDays: [F.monday], settings: HabitSettings(), today: today, now: evening,
      calendar: F.calendar)
    #expect(notes.count == 1)
    guard case .missedDays = try #require(notes.first) else {
      Issue.record("not the wizard line")
      return
    }
  }

  @Test("the reminder is due at the evening hour of today, only while today has no entry")
  func nudge() throws {
    let today = F.monday.adding(days: 1)
    let nudge = try #require(
      HabitNotes.nudge(entryDays: [F.monday], today: today, hour: 21, calendar: F.calendar))
    #expect(nudge.at == F.calendar.moment(today, hour: 21, minute: 0))
    #expect(nudge.streakDays == 1)
    #expect(
      HabitNotes.nudge(entryDays: [F.monday, today], today: today, hour: 21, calendar: F.calendar)
        == nil)
    #expect(HabitNotes.nudge(entryDays: [], today: today, hour: 21, calendar: F.calendar) == nil)
  }
}

@Suite("Habits: the period of a copy and the goal note")
struct HabitPrivacyTests {
  typealias F = HabitFixture

  @Test("a copy of a period keeps the marks and badges of its days only")
  func periodCut() {
    var dataset = Dataset()
    let inside = F.day(2026, 6, 10)
    let outside = F.day(2026, 5, 10)
    dataset.habits = HabitData(
      badges: [
        HabitBadge(kind: .entry7, period: "2026-06-01", earnedOn: inside, earnedAt: Date()),
        HabitBadge(kind: .countMonth, period: "2026-05", earnedOn: outside, earnedAt: Date()),
      ],
      noSpendDays: [
        NoSpendDay(day: inside, markedAt: Date()), NoSpendDay(day: outside, markedAt: Date()),
      ])
    let scoped = PeriodScope.apply(DayRange(F.day(2026, 6, 1), F.day(2026, 6, 30)), to: dataset)
    #expect(scoped.habits.noSpendDays.map(\.day) == [inside])
    #expect(scoped.habits.badges.map(\.kind) == [.entry7])
  }

  @Test("the anonymised copy wipes «Зачем коплю»")
  func anonymised() {
    var dataset = Dataset()
    dataset.goals = [Goal(name: "Море", targetE4: AmountE4(whole: 1), whyNote: "всей семьёй")]
    let copy = Anonymizer.apply(to: dataset)
    #expect(copy.goals.first?.whyNote == nil)
    #expect(Anonymizer.coveredFields.contains("goal.whyNote"))
  }

  @Test("a note is trimmed and cut; an empty one is none")
  func cleanNote() {
    #expect(GoalWhy.clean("  море  ") == "море")
    #expect(GoalWhy.clean("   ") == nil)
    #expect(GoalWhy.clean(nil) == nil)
    #expect(GoalWhy.clean(String(repeating: "а", count: 400))?.count == GoalWhy.maxLength)
  }
}

@Suite("Habits: the days a restored line may take")
struct MissedDaysAnchorTests {
  typealias F = HabitFixture

  @Test("a line goes no earlier than the day of the latest count; all before it — today")
  func anchored() {
    let gap = MissedDays(lastActive: F.monday, today: F.monday.adding(days: 4))
    let key = BalanceKey(accountId: UUID(), currency: .rub)
    let account = PaymentMethod(name: "Card")
    let free = MissedDaysBalance(account: account, key: key, expected: .zero)
    #expect(free.days(of: gap, calendar: F.calendar) == gap.days)
    let counted = MissedDaysBalance(
      account: account, key: key, expected: .zero,
      anchorAt: F.calendar.noon(of: F.monday.adding(days: 3)))
    #expect(
      counted.days(of: gap, calendar: F.calendar)
        == [F.monday.adding(days: 3), F.monday.adding(days: 4)])
    let late = MissedDaysBalance(
      account: account, key: key, expected: .zero,
      anchorAt: F.calendar.noon(of: F.monday.adding(days: 9)))
    #expect(late.days(of: gap, calendar: F.calendar) == [gap.today])
  }
}
