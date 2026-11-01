import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// The habits in the app: the wizard of the days missed writes its lines as one step of ⌘Z and
/// refuses when a balance moved; the badges are written once and a recount after them writes
/// nothing; the first month starts only on a new book; the reminder of the evening goes to a
/// deliverer when there is one; every word reads in both languages. Synthetic data only.
@MainActor
final class HabitsTests: AccountsScenarioDatabaseCase {
  private var defaults: UserDefaults!
  private var suite: String!

  override func setUp() async throws {
    try await super.setUp()
    suite = "ohmymoney.tests.habits.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suite)
  }

  override func tearDown() async throws {
    defaults?.removePersistentDomain(forName: suite)
    HabitNudgeRoute.deliverer = nil
    HabitNudgeRoute.route(nil)
    try await super.tearDown()
  }

  private func dataset() async throws -> Dataset {
    let stack = try XCTUnwrap(environment.stack)
    return try await DatasetRepository(writer: stack.writer).load(version: 0)
  }

  private func snapshot(_ dataset: Dataset) -> DataSnapshot {
    DataSnapshot.build(
      dataset: dataset, calendar: environment.calendar, today: today,
      context: SnapshotContext(), version: DataVersion(load: 0), now: moment)
  }

  private func expenseCategory(_ categories: [CoreKit.Category]) throws -> UUID {
    let id =
      MissedDaysWrite.unknownCategory(categories)
      ?? MissedDaysWrite.categoryChoices(categories).first?.id
    return try XCTUnwrap(id, "the book has no expense category")
  }

  // MARK: Words

  func testEveryKeyHasWordsInBothLanguages() {
    for choice in [AppLanguage.Choice.russian, .english] {
      let words = AppEnvironment()
      words.language.choice = choice
      for key in HabitText.keys {
        let value = words.language(key, table: HabitText.table)
        XCTAssertNotEqual(value, key, "\(choice) \(key)")
        XCTAssertFalse(value.isEmpty, key)
      }
      for action in WorthALookNoteText.Action.allCases where action.isHabit {
        XCTAssertNotEqual(words.language(action.key, table: action.table), action.key)
      }
    }
  }

  func testTheLinesSayWhatTheyAreAboutInBothLanguages() {
    let gap = MissedDays(lastActive: today.adding(days: -5), today: today)
    let check = EveningCheck(day: today, streakDays: 12, remind: true)
    let russian = AppEnvironment()
    russian.language.choice = .russian
    XCTAssertTrue(HabitText.note(.missedDays(gap), russian).contains("4 дня"))
    XCTAssertTrue(HabitText.note(.evening(check), russian).contains("12 дней"))
    let english = AppEnvironment()
    english.language.choice = .english
    XCTAssertTrue(HabitText.note(.missedDays(gap), english).contains("4 days"))
    XCTAssertEqual(
      HabitText.actions(.missedDays(gap)), [.restoreMissed, .done])
    XCTAssertEqual(HabitText.actions(.evening(check)), [.noSpend, .done])
  }

  // MARK: The wizard of the days missed

  func testTheWizardWritesItsLinesAsOneStepOfUndo() async throws {
    let card = try await make(
      PaymentMethod(name: "Карта", isDefault: true), openings: [.rub: rub(10_000)])
    let key = BalanceKey(accountId: card.id, currency: .rub)
    let categories = try XCTUnwrap(environment.references).categories()
    let category = try expenseCategory(categories)
    // The opening was counted this morning: the lines go on today, after it.
    let days = [today, today]
    var lines = MissedDaysWizard.spread(rub(2_500), over: days, key: key)
    for index in lines.indices { lines[index].categoryId = category }
    XCTAssertNil(MissedDaysWizard.problem(lines: lines, missing: [key: rub(2_500)]))
    let before = try liveEntries().count

    let change = try MissedDaysWrite.change(
      lines: lines, expected: [key: rub(10_000)], categories: categories, environment: environment,
      now: moment)
    XCTAssertTrue(store.apply(change))
    let balanceAfter = try await balance(card.id)
    XCTAssertEqual(balanceAfter, rub(7_500), "restored = expected − counted")
    let written = try liveEntries()
    XCTAssertEqual(written.count, before + 2)
    let restored = written.filter { entry in
      lines.contains { $0.amountE4 == entry.transaction.amountE4 }
    }
    XCTAssertTrue(restored.allSatisfy { HabitEntryDays.isTypedByHand($0.transaction) })
    XCTAssertEqual(
      Set(restored.map { environment.calendar.day(of: $0.transaction.occurredAt) }), Set(days))
    XCTAssertTrue(restored.allSatisfy { $0.parts.first?.categoryId == category })

    store.undo()
    let balanceUndone = try await balance(card.id)
    XCTAssertEqual(balanceUndone, rub(10_000))
    XCTAssertEqual(try liveEntries().count, before, "one ⌘Z takes every line back")
  }

  func testTheWizardWritesNothingWhenABalanceMovedMeanwhile() async throws {
    let card = try await make(
      PaymentMethod(name: "Карта", isDefault: true), openings: [.rub: rub(10_000)])
    let key = BalanceKey(accountId: card.id, currency: .rub)
    let categories = try XCTUnwrap(environment.references).categories()
    var lines = MissedDaysWizard.spread(rub(1_000), over: [today], key: key)
    lines[0].categoryId = try expenseCategory(categories)
    // The wizard read 10,000; a coffee was written since.
    try spend(300, on: card.id)
    let before = try liveEntries().count
    let change = try MissedDaysWrite.change(
      lines: lines, expected: [key: rub(10_000)], categories: categories, environment: environment,
      now: moment)
    XCTAssertFalse(store.apply(change))
    XCTAssertEqual(try liveEntries().count, before)
    let after = try await balance(card.id)
    XCTAssertEqual(after, rub(9_700))
  }

  func testTheCategoriesOfALineAreExpensesWithUnknownAndNoOtherCategoryOfTheApp() throws {
    let categories = try XCTUnwrap(environment.references).categories()
    let tree = CategoryTree(categories)
    let choices = MissedDaysWrite.categoryChoices(categories)
    XCTAssertFalse(choices.isEmpty)
    for choice in choices {
      let category = try XCTUnwrap(categories.first { $0.id == choice.id })
      XCTAssertEqual(category.kind, .expense)
      let role = tree.systemRole(of: category.id)
      XCTAssertTrue(role == nil || role == .unknown, choice.title)
    }
  }

  // MARK: Badges

  func testBadgesAreWrittenOnceAndARecountAfterThemFindsNothingNew() async throws {
    let card = try await make(
      PaymentMethod(name: "Карта", isDefault: true), openings: [.rub: rub(1_000)])
    let transactions = try XCTUnwrap(environment.transactions)
    for offset in 0..<7 {
      let day = today.adding(days: offset - 6)
      var draft = TransactionDraft(
        occurredAt: environment.calendar.noon(of: day), amount: rub(10), note: "кофе",
        paymentMethodId: card.id)
      draft.normalizeSinglePart()
      try transactions.insert([
        try draft.materialize(
          now: environment.calendar.noon(of: day), timeZone: environment.calendar.timeZone)
      ])
    }
    let first = snapshot(try await dataset())
    XCTAssertEqual(HabitAwards.new(in: first, now: moment).map(\.kind), [.entry7])

    HabitAwards.check(first, environment: environment)
    let stored = try XCTUnwrap(environment.habits).data().badges
    XCTAssertEqual(stored.map(\.kind), [.entry7])

    // The recount the write starts: the data holds the badge, nothing is new, nothing is written.
    let second = snapshot(try await dataset())
    XCTAssertTrue(HabitAwards.new(in: second, now: moment).isEmpty)
    HabitAwards.check(second, environment: environment)
    XCTAssertEqual(try XCTUnwrap(environment.habits).data().badges, stored)
  }

  func testADayMarkedWithoutSpendingCountsAndTheMarkIsOnce() async throws {
    let habits = try XCTUnwrap(environment.habits)
    let deps = AppDependencies(
      environment: environment, store: store, compute: ComputeStore(calendar: .system))
    XCTAssertTrue(HabitActions(deps).markNoSpend(today))
    XCTAssertTrue(HabitActions(deps).markNoSpend(today), "marking again keeps the mark")
    XCTAssertEqual(try habits.data().noSpendDays.map(\.day), [today])
    let marked = snapshot(try await dataset())
    XCTAssertTrue(HabitNotesOnMac.entryDays(marked).contains(today))
  }

  // MARK: The reminder of the evening

  private final class Deliverer: HabitNudgeDelivering {
    var answer = true
    var scheduled: [HabitNudge?] = []
    func schedule(_ nudge: HabitNudge?) -> Bool {
      scheduled.append(nudge)
      return answer
    }
  }

  func testTheReminderGoesToADelivererAndTheLineThenDoesNotRepeatIt() {
    let deliverer = Deliverer()
    HabitNudgeRoute.route(nil)
    XCTAssertFalse(HabitNudgeRoute.delivers, "without a deliverer the line carries the reminder")
    HabitNudgeRoute.deliverer = deliverer
    let nudge = HabitNudge(day: today, at: moment, streakDays: 3)
    HabitNudgeRoute.route(nudge)
    XCTAssertTrue(HabitNudgeRoute.delivers)
    XCTAssertEqual(deliverer.scheduled, [nudge])
    deliverer.answer = false
    HabitNudgeRoute.route(nudge)
    XCTAssertFalse(HabitNudgeRoute.delivers, "no permission: the line says it again")
  }

  func testTheEveningLineFollowsTheSettingsOfThisMac() async throws {
    try await make(PaymentMethod(name: "Карта", isDefault: true), openings: [.rub: rub(1_000)])
    let transactions = try XCTUnwrap(environment.transactions)
    let yesterday = today.adding(days: -1)
    var draft = TransactionDraft(
      occurredAt: environment.calendar.noon(of: yesterday), amount: rub(10), note: "кофе")
    draft.normalizeSinglePart()
    try transactions.insert([
      try draft.materialize(
        now: environment.calendar.noon(of: yesterday), timeZone: environment.calendar.timeZone)
    ])
    let shown = snapshot(try await dataset())
    let evening = environment.calendar.moment(today, hour: 21, minute: 0)
    XCTAssertEqual(HabitNotesOnMac.notes(of: shown, defaults: defaults, now: evening).count, 1)
    defaults.set(22, forKey: HabitNotesOnMac.eveningHourKey)
    XCTAssertTrue(HabitNotesOnMac.notes(of: shown, defaults: defaults, now: evening).isEmpty)
    defaults.set(20, forKey: HabitNotesOnMac.eveningHourKey)
    defaults.set(false, forKey: HabitNotesOnMac.eveningEnabledKey)
    XCTAssertTrue(HabitNotesOnMac.notes(of: shown, defaults: defaults, now: evening).isEmpty)
  }

  // MARK: The first month and the beginner

  func testTheFirstMonthStartsOnANewBookOnlyAndRemembersWhatIsDone() throws {
    let calendar = environment.calendar
    var fresh = Dataset()
    let progress = try XCTUnwrap(
      FirstMonthStore.current(fresh, calendar: calendar, today: today, defaults: defaults))
    XCTAssertEqual(progress.start, today)
    XCTAssertEqual(FirstMonthStore.read(defaults), progress, "the memory is kept")
    XCTAssertTrue(BeginnerModeOnMac.enabled(defaults), "a new book gets the beginner mode")

    // An operation typed: the first expense is done, and stays done when it goes.
    var draft = TransactionDraft(occurredAt: calendar.noon(of: today), amount: rub(10))
    draft.normalizeSinglePart()
    fresh.entries = [
      try draft.materialize(now: calendar.noon(of: today), timeZone: calendar.timeZone)
    ]
    let after = try XCTUnwrap(
      FirstMonthStore.current(fresh, calendar: calendar, today: today, defaults: defaults))
    XCTAssertTrue(after.done.contains("month.firstOperation"))
    let emptied = try XCTUnwrap(
      FirstMonthStore.current(Dataset(), calendar: calendar, today: today, defaults: defaults))
    XCTAssertTrue(emptied.done.contains("month.firstOperation"))

    BeginnerModeOnMac.set(false, defaults)
    XCTAssertFalse(BeginnerModeOnMac.enabled(defaults))
  }

  func testABookInUseNeverGetsTheFirstMonthNorTheBeginnerMode() throws {
    let calendar = environment.calendar
    let long = today.adding(days: -60)
    var draft = TransactionDraft(occurredAt: calendar.noon(of: long), amount: rub(10))
    draft.normalizeSinglePart()
    let book = Dataset(entries: [
      try draft.materialize(now: calendar.noon(of: long), timeZone: calendar.timeZone)
    ])
    XCTAssertNil(
      FirstMonthStore.current(book, calendar: calendar, today: today, defaults: defaults))
    XCTAssertNil(FirstMonthStore.read(defaults))
    XCTAssertFalse(BeginnerModeOnMac.enabled(defaults))
  }

  // MARK: Settings

  func testTheSettingsOfTheHabitsAreFoundBySearch() {
    let captions = SettingsSection.planning.index.filter { $0.table == HabitText.table }
    XCTAssertEqual(captions.count, 5)
    for caption in captions { XCTAssertTrue(HabitText.keys.contains(caption.key), caption.key) }
  }

  func testTheSettingOfTheDaysMissedIsKeptInTheDatabase() throws {
    let habits = try XCTUnwrap(environment.habits)
    let deps = AppDependencies(
      environment: environment, store: store, compute: ComputeStore(calendar: .system))
    XCTAssertTrue(HabitActions(deps).save(HabitSettings(missedDaysAfter: 6)))
    XCTAssertEqual(try habits.data().settings.missedDaysAfter, 6)
  }
}
