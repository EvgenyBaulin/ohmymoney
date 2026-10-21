import AppCore
import AppDatabase
import AppKit
import SwiftUI
import XCTest

@testable import OhMyMoney

/// Covers the path a typed line takes: interpreted, turned into a draft, written to the
/// database and grouped into the day list — everything except the keystroke itself.
///
/// The tests deliberately stay off the main actor: the store's own methods are exercised
/// through the repository and the pure grouping function, because a host-application test
/// bundle cannot reliably hop to the main actor of a running app.
final class EntryPipelineTests: XCTestCase {
  /// The migrations come from the application bundle, exactly as they do at runtime.
  /// Reading them from the repository instead would leave the sandbox — and while the
  /// repository sat in iCloud Drive, a sandboxed test host simply stalled there.
  private func makeRepository() throws -> TransactionRepository {
    let stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    return TransactionRepository(writer: stack.writer)
  }

  func testTypedLineBecomesAVisibleOperation() throws {
    let repository = try makeRepository()
    let today = DateOnly(year: 2026, month: 9, day: 18)
    let parsed = InputLineParser(vocabulary: .empty, calendar: .utc)
      .parse("кофе 250", today: today)

    let amount = try XCTUnwrap(parsed.amount)
    var draft = TransactionDraft(
      occurredAt: CalendarContext.utc.startOfDay(today).addingTimeInterval(9 * 3600),
      amount: try AmountE4(decimal: amount),
      note: parsed.note)
    draft.normalizeSinglePart()
    try repository.save(try draft.materialize())

    let groups = TransactionsStore.group(try repository.recentEntries(), calendar: .utc)
    XCTAssertEqual(groups.count, 1)
    XCTAssertEqual(groups.first?.expenses.count, 1)
    XCTAssertEqual(groups.first?.expenses.first?.transaction.note, "кофе")
    XCTAssertEqual(groups.first?.totals.myExpenses, AmountE4(whole: 250))
  }

  func testExpressionLineKeepsWhatWasTyped() throws {
    let repository = try makeRepository()
    let today = DateOnly(year: 2026, month: 9, day: 18)
    let parsed = InputLineParser(vocabulary: .empty, calendar: .utc)
      .parse("такси (1000+600)/2", today: today)

    let amount = try XCTUnwrap(parsed.amount)
    var draft = TransactionDraft(
      amount: try AmountE4(decimal: amount),
      amountExpression: parsed.amountExpression,
      note: parsed.note)
    draft.normalizeSinglePart()
    try repository.save(try draft.materialize())

    let saved = try XCTUnwrap(try repository.recentEntries().first)
    XCTAssertEqual(saved.transaction.amountE4, AmountE4(whole: 800))
    XCTAssertEqual(saved.transaction.amountExpr, "(1000+600)/2")
    XCTAssertEqual(saved.transaction.note, "такси")
  }

  /// «Делений на ноль и мусора нет: понятная ошибка вместо сохранения». Enter on a line
  /// whose number cannot be an amount names the reason instead of asking for an amount.
  func testALineWithoutAnAmountSaysWhy() {
    let parser = InputLineParser(vocabulary: .empty, calendar: .utc)
    let today = DateOnly(year: 2026, month: 9, day: 18)
    let expected = [
      "кофе 10/0": "entry.error.divisionByZero",
      "кофе 3000 \u{00F7} 0": "entry.error.divisionByZero",
      "кофе 999999999999999999": "entry.error.amountTooLarge",
      "кофе 100-250": "entry.error.amountNegative",
      "кофе 12++": "entry.error.badExpression",
      "кофе": "entry.error.amountMissing",
    ]
    for (line, key) in expected {
      XCTAssertEqual(parser.parse(line, today: today).missingAmountErrorKey, key, line)
    }
  }

  func testDeletingIsSoftSoUndoCanBringItBack() throws {
    let repository = try makeRepository()
    var draft = TransactionDraft(amount: AmountE4(whole: 100), note: "taxi")
    draft.normalizeSinglePart()
    let entry = try draft.materialize()
    try repository.save(entry)

    try repository.softDelete(id: entry.id)
    XCTAssertEqual(try repository.count(), 0)

    try repository.restore(id: entry.id)
    XCTAssertEqual(try repository.count(), 1)
  }

  /// Money given back comes in, so it is listed with the income — but it is not income:
  /// the day's income leaves it out and shows it as money back of its own.
  func testIncomeAndExpensesAreSeparatedInsideADay() throws {
    let repository = try makeRepository()
    let day = CalendarContext.utc.startOfDay(DateOnly(year: 2026, month: 9, day: 18))

    let operations: [(TransactionKind, Int64)] = [
      (.expense, 250), (.income, 50_000), (.reimbursement, 300), (.refund, 50),
    ]
    for (kind, amount) in operations {
      var draft = TransactionDraft(
        kind: kind, occurredAt: day.addingTimeInterval(3600), amount: AmountE4(whole: amount))
      draft.normalizeSinglePart()
      try repository.save(try draft.materialize())
    }

    let groups = TransactionsStore.group(try repository.recentEntries(), calendar: .utc)
    XCTAssertEqual(groups.count, 1)
    XCTAssertEqual(
      groups.first?.expenses.map(\.transaction.kind).sorted { $0.rawValue < $1.rawValue },
      [.expense, .refund])
    XCTAssertEqual(
      groups.first?.income.map(\.transaction.kind).sorted { $0.rawValue < $1.rawValue },
      [.income, .reimbursement])
    XCTAssertEqual(groups.first?.totals.income, AmountE4(whole: 50_000))
    XCTAssertEqual(groups.first?.totals.moneyReturned, AmountE4(whole: 300))
    XCTAssertEqual(groups.first?.totals.myExpenses, AmountE4(whole: 200))
  }

  func testStarterCategoriesCoverBothLanguagesAndSystemRoles() {
    let english = StarterCategories.tree(language: "en")
    let russian = StarterCategories.tree(language: "ru")

    XCTAssertEqual(english.count, russian.count)
    XCTAssertTrue(english.contains { $0.name == "Groceries" })
    XCTAssertTrue(russian.contains { $0.name == "Продукты" })

    let roles = Set(english.compactMap(\.systemRole))
    XCTAssertEqual(roles, Set(SystemRole.allCases))

    XCTAssertEqual(english.first { $0.name == "Fines" }?.quality, .bad)
    XCTAssertEqual(english.first { $0.name == "Fees" }?.quality, .bad)
    XCTAssertEqual(english.first { $0.name == "Education" }?.quality, .good)
    XCTAssertEqual(english.first { $0.systemRole == .goals }?.quality, .good)
  }

  /// First launch seeds the very list the synthetic sets and the screenshots are built from
  /// (`SampleCatalog`), numbered by one running `sort`, so the two can never drift apart — with
  /// the categories of every new database put in their places («Зарплата» under «Заработок»,
  /// «Налоги и сборы» with three taxes), and nothing else added or moved.
  func testFirstLaunchSeedsTheCoreCatalog() {
    for language in ["en", "ru"] {
      let seeded = StarterCategories.tree(language: language)
      let catalog = SampleCatalog.makeCategories(
        language: language, seeds: StarterSets.starterSeeds)
      let samples = SampleCatalog.makeCategories(language: language)
      func shape(_ tree: [CoreKit.Category]) -> [String] {
        let names = Dictionary(uniqueKeysWithValues: tree.map { ($0.id, $0.name) })
        return tree.map { category in
          let parent = category.parentId.flatMap { names[$0] } ?? "-"
          let quality = category.quality?.rawValue ?? "-"
          let role = category.systemRole?.rawValue ?? "-"
          return "\(category.kind.rawValue)|\(parent)|\(category.name)|\(quality)|\(role)"
        }
      }
      XCTAssertEqual(shape(seeded), shape(catalog), language)
      XCTAssertEqual(seeded.map(\.sort), Array(0..<seeded.count), language)
      // The samples' catalog is the seeded list without the new categories, in the same order.
      let added = Set(shape(seeded)).subtracting(shape(samples))
      XCTAssertEqual(
        shape(seeded).filter { !added.contains($0) }, shape(samples), language)
      let russian = language == "ru"
      XCTAssertEqual(
        added,
        Set(
          russian
            ? [
              "income|Заработок|Зарплата|-|-", "expense|-|Налоги и сборы|neutral|-",
              "expense|Налоги и сборы|Транспортный налог|-|-",
              "expense|Налоги и сборы|Имущественный налог|-|-",
              "expense|Налоги и сборы|НДФЛ|-|-",
            ]
            : [
              "income|Work|Salary|-|-", "expense|-|Taxes & fees|neutral|-",
              "expense|Taxes & fees|Vehicle tax|-|-", "expense|Taxes & fees|Property tax|-|-",
              "expense|Taxes & fees|Income tax|-|-",
            ]), language)
    }
  }

  func testDebugBuildsUseTheirOwnDataDirectory() {
    XCTAssertTrue(AppPaths.dataDirectory.path.contains("Application Support/OhMyMoney"))
    #if DEBUG
      XCTAssertEqual(AppPaths.dataDirectory.lastPathComponent, "Debug")
    #endif
  }
}

/// The month the Overview shows is read from the database by date range, so it does not
/// depend on how many rows the list happens to hold.
final class MonthRangeTests: XCTestCase {
  private func makeRepository() throws -> TransactionRepository {
    let stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    return TransactionRepository(writer: stack.writer)
  }

  func testTheRangeTakesTheWholeMonthAndNothingElse() throws {
    let repository = try makeRepository()
    let calendar = CalendarContext.utc
    let month = MonthKey(year: 2026, month: 9)

    let days = [
      DateOnly(year: 2026, month: 8, day: 31),
      DateOnly(year: 2026, month: 9, day: 1),
      DateOnly(year: 2026, month: 9, day: 30),
      DateOnly(year: 2026, month: 10, day: 1),
    ]
    for day in days {
      var draft = TransactionDraft(
        occurredAt: calendar.startOfDay(day).addingTimeInterval(12 * 3600),
        amount: AmountE4(whole: 100), note: day.iso)
      draft.normalizeSinglePart()
      try repository.save(try draft.materialize())
    }

    // The last moment of the last day must be inside the range.
    var lastMoment = TransactionDraft(
      occurredAt: calendar.endOfDay(DateOnly(year: 2026, month: 9, day: 30)),
      amount: AmountE4(whole: 100), note: "last moment")
    lastMoment.normalizeSinglePart()
    try repository.save(try lastMoment.materialize())

    let from = calendar.startOfDay(month.firstDay)
    let to = calendar.endOfDay(calendar.adding(days: -1, to: month.next.firstDay))
    let entries = try repository.entries(from: from, to: to)

    XCTAssertEqual(entries.count, 3)
    XCTAssertTrue(entries.contains { $0.transaction.note == "2026-09-01" })
    XCTAssertTrue(entries.contains { $0.transaction.note == "2026-09-30" })
    XCTAssertTrue(entries.contains { $0.transaction.note == "last moment" })
    XCTAssertFalse(entries.contains { $0.transaction.note == "2026-08-31" })
    XCTAssertFalse(entries.contains { $0.transaction.note == "2026-10-01" })
  }

  func testDeletedOperationsStayOutOfTheRange() throws {
    let repository = try makeRepository()
    let calendar = CalendarContext.utc
    let day = DateOnly(year: 2026, month: 9, day: 10)

    var draft = TransactionDraft(
      occurredAt: calendar.startOfDay(day), amount: AmountE4(whole: 100))
    draft.normalizeSinglePart()
    let entry = try draft.materialize()
    try repository.save(entry)
    try repository.softDelete(id: entry.id)

    let entries = try repository.entries(
      from: calendar.startOfDay(DateOnly(year: 2026, month: 9, day: 1)),
      to: calendar.endOfDay(DateOnly(year: 2026, month: 9, day: 30)))
    XCTAssertTrue(entries.isEmpty)
  }
}

/// What ⌘Z does, and what the store does when a write does not land.
@MainActor
final class TransactionsStoreTests: XCTestCase {
  /// The repository keeps the writer alive, so the in-memory database outlives the stack.
  private func makeStore() throws -> (TransactionsStore, TransactionRepository) {
    let stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    let repository = TransactionRepository(writer: stack.writer)
    let store = TransactionsStore(repository: repository)
    return (store, repository)
  }

  private func draft(_ whole: Int64, note: String) -> TransactionDraft {
    var draft = TransactionDraft(
      occurredAt: CalendarContext.utc.startOfDay(DateOnly(year: 2026, month: 9, day: 18))
        .addingTimeInterval(9 * 3600),
      amount: AmountE4(whole: whole),
      note: note)
    draft.normalizeSinglePart()
    return draft
  }

  /// Undo must never physically delete an operation that was already there. Whether a save
  /// creates or replaces is a fact about the database, not something a call site is asked
  /// to remember — and getting it wrong here costs the operation itself.
  func testUndoingASaveOverAnExistingOperationRestoresItInsteadOfDeletingIt() throws {
    let (store, repository) = try makeStore()
    let original = try draft(250, note: "coffee").materialize()
    store.save(original)

    var edited = draft(400, note: "coffee")
    edited.normalizeSinglePart()
    store.save(try edited.materialize(id: original.id))

    store.undo()

    XCTAssertEqual(try repository.count(), 1)
    XCTAssertEqual(
      try repository.entry(id: original.id)?.transaction.amountE4, AmountE4(whole: 250))
  }

  func testUndoingACreationTakesTheOperationAwayAgain() throws {
    let (store, repository) = try makeStore()
    let entry = try draft(250, note: "coffee").materialize()
    store.save(entry)
    XCTAssertTrue(store.canUndo)

    store.undo()

    XCTAssertEqual(try repository.count(), 0)
    XCTAssertFalse(store.canUndo)
  }

  func testUndoingADeletionBringsTheOperationBack() throws {
    let (store, repository) = try makeStore()
    let entry = try draft(250, note: "coffee").materialize()
    try repository.save(entry)

    store.delete(id: entry.id)
    XCTAssertEqual(try repository.count(), 0)

    store.undo()
    XCTAssertEqual(try repository.count(), 1)
  }

  /// A write that throws leaves the database as it was, so there is nothing to undo and the
  /// caller has to be told — otherwise the entry line clears itself over a save that never
  /// happened.
  func testAWriteThatDoesNotLandIsReportedAndLeavesNothingToUndo() throws {
    let (store, repository) = try makeStore()
    var unbalanced = TransactionDraft(amount: AmountE4(whole: 1_000), note: "dinner")
    unbalanced.parts = [PartDraft(amount: AmountE4(whole: 600))]

    XCTAssertFalse(store.save(try unbalanced.materialize()))
    XCTAssertFalse(store.canUndo)
    XCTAssertNotNil(store.lastError)
    XCTAssertEqual(try repository.count(), 0)
  }

  /// The pipeline lays every write over its data. Editing an operation inside a day the
  /// list already shows changes neither the number of days nor the number of rows, and the
  /// write still carries the operation as it is now, so the totals move.
  func testEveryChangeIsReportedWithTheOperationAsItIsNow() throws {
    let (store, _) = try makeStore()
    var writes: [StoreWrite] = []
    store.didWrite = { writes.append($0) }
    let entry = try draft(250, note: "coffee").materialize()
    store.save(entry)

    var edited = draft(400, note: "coffee")
    edited.normalizeSinglePart()
    store.save(try edited.materialize(id: entry.id))

    XCTAssertEqual(writes.count, 2)
    XCTAssertEqual(writes.last?.upserted.map(\.id), [entry.id])
    XCTAssertEqual(writes.last?.upserted.first?.transaction.amountE4, AmountE4(whole: 400))
  }
}

/// The numbers on the Overview cards follow the accounting rules, not the list of rows:
/// a refund takes money off, money coming back from a person is not spending at all, and a
/// part paid for somebody else is not mine until it is written off. They come from the
/// snapshot of the data step, as the cards get them.
final class OverviewTotalsTests: XCTestCase {
  private let today = DateOnly(year: 2026, month: 9, day: 18)

  private func entry(
    kind: TransactionKind, whole: Int64, parts: [PartDraft]? = nil
  ) throws -> TransactionEntry {
    var draft = TransactionDraft(
      kind: kind, occurredAt: CalendarContext.utc.startOfDay(today).addingTimeInterval(9 * 3600),
      amount: AmountE4(whole: whole))
    if let parts {
      draft.parts = parts
    } else {
      draft.normalizeSinglePart()
    }
    return try draft.materialize()
  }

  /// The month so far, as the cards show it.
  private func monthSoFar(_ entries: [TransactionEntry]) -> (expenses: AmountE4, income: AmountE4) {
    let summary = DataSnapshot.build(
      dataset: Dataset(entries: entries), calendar: .utc, today: today,
      context: SnapshotContext(), version: DataVersion(load: 0)
    ).summary
    return (summary.expenses.current, summary.income.current)
  }

  func testARefundTakesMoneyOffInsteadOfAddingIt() throws {
    let totals = monthSoFar([
      try entry(kind: .expense, whole: 1_000),
      try entry(kind: .refund, whole: 300),
    ])
    XCTAssertEqual(totals.expenses, AmountE4(whole: 700))
  }

  func testMoneyComingBackFromAPersonIsNeitherSpendingNorIncome() throws {
    let totals = monthSoFar([
      try entry(kind: .expense, whole: 1_000),
      try entry(kind: .reimbursement, whole: 500),
    ])
    XCTAssertEqual(totals.expenses, AmountE4(whole: 1_000))
    XCTAssertEqual(totals.income, .zero)
  }

  func testAPartPaidForSomebodyElseIsNotMySpendingYet() throws {
    let totals = monthSoFar([
      try entry(
        kind: .expense, whole: 1_000,
        parts: [
          PartDraft(amount: AmountE4(whole: 600)),
          PartDraft(amount: AmountE4(whole: 400), reimbursable: true),
        ])
    ])
    XCTAssertEqual(totals.expenses, AmountE4(whole: 600))
  }

  func testIncomeIsStillCountedInFull() throws {
    let totals = monthSoFar([
      try entry(kind: .income, whole: 50_000),
      try entry(kind: .expense, whole: 1_000),
    ])
    XCTAssertEqual(totals.income, AmountE4(whole: 50_000))
    XCTAssertEqual(totals.expenses, AmountE4(whole: 1_000))
  }
}

/// The width of the entry bar: 560–720 pt, never wider than 70% of the window, and always
/// 16 pt clear of the sides of the column it floats over.
final class EntryBarMetricsTests: XCTestCase {
  private func width(window: CGFloat, detail: CGFloat) -> CGFloat {
    EntryBarMetrics.columnWidth(windowWidth: window, detailWidth: detail)
  }

  /// The default window: 70% of 1120 is 784, so the cap of 720 applies, and the detail
  /// column next to a 210 pt sidebar is 910 − 32 = 878 wide, which leaves the cap alone.
  func testTheDefaultWindowGetsTheFullWidth() {
    XCTAssertEqual(width(window: 1120, detail: 910), 720)
    XCTAssertEqual(width(window: 1120, detail: 1120), 720)
  }

  func testTheShareOfTheWindowDecidesBetweenTheBounds() {
    XCTAssertEqual(width(window: 900, detail: 690), 630)
    XCTAssertEqual(width(window: 1000, detail: 1000), 700)
  }

  /// The owner's rule is «never wider than 70% of the window». Below 800 pt that share is
  /// under the 560 pt minimum, and the share wins even where the column has room.
  func testOnANarrowWindowTheShareWinsOverTheMinimum() {
    XCTAssertEqual(width(window: 700, detail: 700), 490, accuracy: 0.001)
    XCTAssertEqual(width(window: 780, detail: 590), 546)
  }

  func testANarrowColumnWinsOverTheMinimum() {
    // 70% of 800 is 560, but the column beside the sidebar is 590 − 32 = 558 wide.
    XCTAssertEqual(width(window: 800, detail: 590), 558)
    XCTAssertEqual(width(window: 800, detail: 20), 0)
  }

  func testAnUnmeasuredWindowFallsBackToTheColumnAndThenToTheMinimum() {
    XCTAssertEqual(width(window: 0, detail: 1000), 700)
    XCTAssertEqual(width(window: .nan, detail: 1000), 700)
    XCTAssertEqual(width(window: 0, detail: 0), 560)
    XCTAssertEqual(width(window: 1120, detail: 0), 720)
  }

}

/// The category filter of the Transactions window follows its type filter.
final class CategoryFilterTests: XCTestCase {
  func testTheCategoryFilterOffersCategoriesOfTheChosenKind() {
    let groceries = CoreKit.Category(kind: .expense, name: "Groceries")
    let coffee = CoreKit.Category(parentId: groceries.id, kind: .expense, name: "Coffee")
    let salary = CoreKit.Category(kind: .income, name: "Salary")
    let tree = [groceries, coffee, salary]

    func offered(_ kind: TransactionKind?) -> [UUID] {
      TransactionFilters.filterCategories(tree, kind: kind).map(\.id)
    }
    XCTAssertEqual(offered(nil), [groceries.id, salary.id])
    XCTAssertEqual(offered(.expense), [groceries.id])
    XCTAssertEqual(offered(.refund), [groceries.id])
    XCTAssertEqual(offered(.income), [salary.id])
  }
}

/// Editing through the sheet changes what the panel edits and nothing else.
@MainActor
final class EditingKeepsOriginTests: XCTestCase {
  func testAnEditKeepsWhenTheOperationWasCreatedAndWhereItCameFrom() throws {
    let stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    let repository = TransactionRepository(writer: stack.writer)
    let store = TransactionsStore(repository: repository)
    let created = Date(timeIntervalSince1970: 1_780_000_000)

    var draft = TransactionDraft(amount: AmountE4(whole: 250), note: "coffee")
    draft.normalizeSinglePart()
    var original = try draft.materialize(now: created)
    original.transaction.externalId = "bank:0042"
    XCTAssertTrue(store.save(original))

    var edit = TransactionDraft(entry: original)
    edit.amount = AmountE4(whole: 400)
    edit.normalizeSinglePart()
    let updated = try EditTransactionSheet.edited(
      original, with: edit, now: created.addingTimeInterval(60), rublesConverter: { $0 })
    XCTAssertTrue(store.save(updated))

    let stored = try XCTUnwrap(try repository.entry(id: original.id))
    XCTAssertEqual(stored.transaction.amountE4, AmountE4(whole: 400))
    XCTAssertEqual(
      stored.transaction.createdAt.timeIntervalSince1970, created.timeIntervalSince1970,
      accuracy: 0.001)
    XCTAssertEqual(stored.transaction.externalId, "bank:0042")

    // The import batch is kept as well; it cannot be written here without a batch row, so
    // the rule is checked on the operation itself.
    var imported = original
    imported.transaction.importBatchId = UUID()
    let edited = try EditTransactionSheet.edited(imported, with: edit, rublesConverter: { $0 })
    XCTAssertEqual(edited.transaction.importBatchId, imported.transaction.importBatchId)
  }
}

/// The ↓ panel's keys: ↓ is the list's and leaves the panel as it is, ↑ and Esc close an open
/// panel, and with the panel closed ↑ and Esc are left to the list and the window.
final class DetailsPanelKeyTests: XCTestCase {
  func testDownOpensNothingAndClosesNothing() {
    XCTAssertTrue(DetailsPanelKey.down.outcome(showing: false) == (false, true))
    XCTAssertTrue(DetailsPanelKey.down.outcome(showing: true) == (true, true))
  }

  func testEscapeAndUpCloseAnOpenPanel() {
    XCTAssertTrue(DetailsPanelKey.escape.outcome(showing: true) == (false, true))
    XCTAssertTrue(DetailsPanelKey.up.outcome(showing: true) == (false, true))
  }

  func testEscapeAndUpPassWhenThePanelIsClosed() {
    XCTAssertTrue(DetailsPanelKey.escape.outcome(showing: false) == (false, false))
    XCTAssertTrue(DetailsPanelKey.up.outcome(showing: false) == (false, false))
  }
}

/// «Сохранение — Enter»: a line to read, or the ↓ panel open. While the panel is open «Save»
/// and Return always answer — with the save, or with the reason there is none — whatever the
/// draft holds: a Return that does nothing is what the owner reported.
final class EntrySavingTests: XCTestCase {
  func testTheOpenPanelAlwaysAnswersReturn() {
    XCTAssertTrue(EntrySaving.isOffered(line: "", showsDetails: true))
    XCTAssertTrue(EntrySaving.isOffered(line: " \n", showsDetails: true))
  }

  func testNothingToSaveWithThePanelClosed() {
    XCTAssertFalse(EntrySaving.isOffered(line: "", showsDetails: false))
    XCTAssertFalse(EntrySaving.isOffered(line: "  ", showsDetails: false))
  }

  /// A line is read on Enter and says itself what stops it.
  func testALineIsAlwaysOffered() {
    XCTAssertTrue(EntrySaving.isOffered(line: "coffee 250", showsDetails: false))
    XCTAssertTrue(EntrySaving.isOffered(line: "coffee", showsDetails: true))
  }
}

/// Return in a text field of the ↓ panel is «Save» (spec, «Панель ↓»: «Сохранение — Enter»):
/// the panel hands it to the bar, which saves as Return in the line does.
@MainActor
final class DetailsPanelSubmitTests: XCTestCase {
  private final class Count { var value = 0 }

  private func textFields(in view: NSView) -> [NSTextField] {
    view.subviews.flatMap { subview -> [NSTextField] in
      ((subview as? NSTextField).map { [$0] } ?? []) + textFields(in: subview)
    }
  }

  func testReturnInAFieldOfThePanelSaves() throws {
    let deps = AppDependencies(
      environment: AppEnvironment(), store: TransactionsStore(),
      compute: ComputeStore(calendar: .system))
    let model = EntryDraftModel(references: nil, transactions: nil, calendar: .utc)
    let submitted = Count()
    let window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: 760, height: 900), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(
      rootView: DetailsPanel(model: model, submit: { submitted.value += 1 })
        .appDependencies(deps))
    window.makeKeyAndOrderFront(nil)
    defer {
      window.contentView = nil
      window.close()
    }
    RunLoop.current.run(until: Date().addingTimeInterval(0.3))

    let fields = textFields(in: try XCTUnwrap(window.contentView)).filter(\.isEditable)
    XCTAssertGreaterThanOrEqual(fields.count, 2, "the amount and the note at least")
    for field in fields {
      XCTAssertTrue(window.makeFirstResponder(field))
      let editor = try XCTUnwrap(window.firstResponder as? NSTextView, "the field editor")
      editor.insertNewline(nil)
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    XCTAssertEqual(submitted.value, fields.count, "every field of the panel saves on Return")
  }
}

/// Saving from the ↓ panel closes it, and the field that had the focus goes with it: the line
/// takes the focus back, as it does when the panel is closed by Esc or ×, so the next line is
/// typed into it and not into nothing.
@MainActor
final class EntryBarFocusTests: XCTestCase {
  private func textFields(in view: NSView) -> [NSTextField] {
    view.subviews.flatMap { subview -> [NSTextField] in
      ((subview as? NSTextField).map { [$0] } ?? []) + textFields(in: subview)
    }
  }

  private func settle(_ seconds: TimeInterval = 0.3) {
    RunLoop.current.run(until: Date().addingTimeInterval(seconds))
  }

  func testSavingFromThePanelGivesTheFocusBackToTheLine() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("entry-focus-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    setenv("OHMYMONEY_DATA_DIR", directory.path, 1)
    defer {
      unsetenv("OHMYMONEY_DATA_DIR")
      try? FileManager.default.removeItem(at: directory)
    }
    let environment = AppEnvironment()
    await environment.start(preparing: {
      try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    })
    let transactions = try XCTUnwrap(environment.transactions)
    // One category for the panel to choose: without any an operation cannot be filed.
    try XCTUnwrap(environment.references).save(
      CoreKit.Category(kind: .expense, name: "Cafe", quality: .neutral))
    let store = TransactionsStore()
    store.attach(
      transactions, references: try XCTUnwrap(environment.references),
      planning: try XCTUnwrap(environment.planning))
    let deps = AppDependencies(
      environment: environment, store: store, compute: ComputeStore(calendar: .system))

    let window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: 900, height: 900), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(
      rootView: EntryBar(windowWidth: 900, detailWidth: 900, opensDetails: true) { EmptyView() }
        .appDependencies(deps))
    window.makeKeyAndOrderFront(nil)
    defer {
      window.contentView = nil
      window.close()
    }
    settle()

    let content = try XCTUnwrap(window.contentView)
    // Told apart by their prompts: the line's, and the «0» of the amount of the panel.
    let prompt = environment.language("entry.placeholder", table: "Entry")
    let fields = textFields(in: content)
    let line = try XCTUnwrap(fields.first { $0.placeholderString == prompt }, "the line")
    let amount = try XCTUnwrap(fields.first { $0.placeholderString == "0" }, "the amount")
    XCTAssertTrue(window.makeFirstResponder(amount))
    let editor = try XCTUnwrap(window.firstResponder as? NSTextView, "the field editor")
    editor.insertText("250", replacementRange: editor.selectedRange())
    settle(0.1)
    // The panel alone says no category: the first Return asks for it, and the next one saves
    // only once one is chosen — ↓ in the line chooses the first of the menu.
    editor.insertNewline(nil)
    settle()
    XCTAssertEqual(try transactions.count(), 0, "the first Return asked for the category")
    XCTAssertTrue(window.makeFirstResponder(line))
    let arrow = String(UnicodeScalar(NSDownArrowFunctionKey)!)
    window.sendEvent(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [.function, .numericPad], timestamp: 0,
        windowNumber: window.windowNumber, context: nil, characters: arrow,
        charactersIgnoringModifiers: arrow, isARepeat: false, keyCode: 125)!)
    settle(0.1)
    XCTAssertTrue(window.makeFirstResponder(amount))
    let still = try XCTUnwrap(window.firstResponder as? NSTextView, "the amount field")
    still.insertNewline(nil)
    settle()

    XCTAssertEqual(try transactions.count(), 1, "Return in the panel saved the operation")
    let focused = (window.firstResponder as? NSTextView)?.delegate as? NSTextField
    XCTAssertTrue(
      focused === line, "the line has the focus, not \(String(describing: window.firstResponder))")
  }
}
