import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// Expected income in Planning: «Удалить…» takes it away with its links and one ⌘Z brings both
/// back; «Закрыть полностью» is offered once no less than expected came in, puts it in the
/// archive, and «Вернуть» brings it back; two may share a name, and a menu tells them apart.
@MainActor
final class ExpectedIncomeArchiveTests: XCTestCase {
  private var store: TransactionsStore!
  private var transactions: TransactionRepository!
  private var references: ReferenceRepository!
  private var planning: PlanningRepository!
  private var compute: ComputeStore!
  private let today = DateOnly(year: 2026, month: 10, day: 7)

  override func setUp() async throws {
    let stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    transactions = TransactionRepository(writer: stack.writer)
    references = ReferenceRepository(writer: stack.writer)
    planning = PlanningRepository(writer: stack.writer)
    store = TransactionsStore()
    store.attach(transactions, references: references, planning: planning)
    compute = ComputeStore(calendar: .utc, rebuildsInline: true)
  }

  private var actions: PlanningActions {
    PlanningActions(AppDependencies(environment: AppEnvironment(), store: store, compute: compute))
  }

  private func noon(_ day: DateOnly) -> Date {
    CalendarContext.utc.startOfDay(day).addingTimeInterval(12 * 3600)
  }

  /// An income operation of `whole` rubles on `day`, written as the entry line writes one.
  private func earn(_ whole: Int64, on day: DateOnly) throws -> UUID {
    var draft = TransactionDraft(
      kind: .income, occurredAt: noon(day), amount: AmountE4(whole: whole), note: "project")
    draft.normalizeSinglePart()
    let entry = try draft.materialize()
    XCTAssertTrue(store.save(entry))
    return entry.id
  }

  private func project(_ whole: Int64, name: String = "Проект") -> ExpectedIncome {
    ExpectedIncome(
      name: name, totalE4: AmountE4(whole: whole), dueDate: DateOnly(year: 2026, month: 10, day: 15)
    )
  }

  /// The statuses the block lists, from what the database holds now.
  private func statuses() throws -> [ExpectedIncomeStatus] {
    let ledger = Ledger(
      dataset: Dataset(
        entries: try transactions.entries(from: .distantPast, to: .distantFuture)),
      calendar: .utc)
    return ExpectedIncomeRules.statuses(book: try planning.book(), ledger: ledger, today: today)
  }

  // MARK: Deleting

  /// «Удалить…»: the income goes and its links with it, the operations stay; one ⌘Z brings the
  /// income and every link back.
  func testDeletingTakesTheLinksAlongAndOneUndoBringsBothBack() throws {
    let income = project(100_000)
    XCTAssertTrue(actions.save(income))
    let first = try earn(30_000, on: DateOnly(year: 2026, month: 10, day: 1))
    let second = try earn(70_000, on: DateOnly(year: 2026, month: 10, day: 5))
    XCTAssertTrue(actions.link(income: first, to: income))
    XCTAssertTrue(actions.link(income: second, to: income))
    let links = try planning.book().expectedLinks
    XCTAssertEqual(links.count, 2)

    XCTAssertTrue(actions.delete(income))
    XCTAssertTrue(try planning.expected().isEmpty, "the income stayed")
    XCTAssertTrue(try planning.book().expectedLinks.isEmpty, "a link stayed")
    XCTAssertEqual(
      Set(try transactions.entries(from: .distantPast, to: .distantFuture).map(\.id)),
      [first, second], "an operation went with the income")
    XCTAssertTrue(store.canUndo)

    store.undo()
    XCTAssertEqual(try planning.expected().map(\.id), [income.id], "⌘Z left the income out")
    XCTAssertEqual(
      Set(try planning.book().expectedLinks.map(\.transactionId)), [first, second],
      "⌘Z left a link out")
    XCTAssertEqual(try statuses().first?.received, AmountE4(whole: 100_000))
  }

  // MARK: Closing

  /// Exactly as much as expected came in: «Закрыть полностью» is offered.
  func testClosingIsOfferedWhenTheWholeAmountCame() throws {
    let income = project(100_000)
    XCTAssertTrue(actions.save(income))
    XCTAssertTrue(actions.link(income: try earn(100_000, on: today), to: income))
    XCTAssertTrue(ExpectedIncomeRules.offersClosing(try XCTUnwrap(try statuses().first)))
  }

  /// More than expected came in: it is offered too.
  func testClosingIsOfferedWhenMoreCame() throws {
    let income = project(100_000)
    XCTAssertTrue(actions.save(income))
    XCTAssertTrue(actions.link(income: try earn(60_000, on: today), to: income))
    XCTAssertTrue(actions.link(income: try earn(50_000, on: today), to: income))
    XCTAssertTrue(ExpectedIncomeRules.offersClosing(try XCTUnwrap(try statuses().first)))
  }

  /// Less came in: nothing is offered.
  func testClosingIsNotOfferedWhenLessCame() throws {
    let income = project(100_000)
    XCTAssertTrue(actions.save(income))
    XCTAssertFalse(ExpectedIncomeRules.offersClosing(try XCTUnwrap(try statuses().first)))
    XCTAssertTrue(actions.link(income: try earn(99_000, on: today), to: income))
    XCTAssertFalse(ExpectedIncomeRules.offersClosing(try XCTUnwrap(try statuses().first)))
  }

  /// «Закрыть полностью» puts it in the archive — out of the list, into
  /// `ExpectedIncomeBlock.archived` —; «Вернуть» brings it back into the list with its links,
  /// and each is one step of ⌘Z.
  func testClosingPutsItInTheArchiveAndRestoringBringsItBack() throws {
    let income = project(100_000)
    XCTAssertTrue(actions.save(income))
    let paid = try earn(100_000, on: today)
    XCTAssertTrue(actions.link(income: paid, to: income))

    XCTAssertTrue(actions.close(income))
    XCTAssertTrue(try statuses().isEmpty, "a closed income stayed in the list")
    XCTAssertEqual(
      ExpectedIncomeBlock.archived(try planning.book().expected).map(\.id), [income.id])

    let closed = try XCTUnwrap(try planning.expected().first)
    XCTAssertTrue(actions.reopen(closed))
    XCTAssertEqual(try statuses().map(\.id), [income.id], "«Вернуть» left it in the archive")
    XCTAssertTrue(ExpectedIncomeBlock.archived(try planning.book().expected).isEmpty)
    XCTAssertEqual(try statuses().first?.linkedTransactionIds, [paid])

    store.undo()
    XCTAssertEqual(
      ExpectedIncomeBlock.archived(try planning.book().expected).map(\.id), [income.id],
      "⌘Z of «Вернуть» did not put it back in the archive")
    store.undo()
    XCTAssertEqual(try statuses().map(\.id), [income.id], "⌘Z of closing left it closed")
  }

  // MARK: Names

  /// Names may repeat: a second «Зарплата» saves beside the first.
  func testTwoIncomesWithOneNameBothSave() throws {
    XCTAssertTrue(actions.save(project(50_000, name: "Зарплата")))
    XCTAssertTrue(actions.save(project(40_000, name: "Зарплата")))
    XCTAssertEqual(try planning.expected().map(\.name), ["Зарплата", "Зарплата"])
  }

  /// In a menu two incomes of one name are told apart by amount and date; a name of its own is
  /// shown alone.
  func testAMenuTellsNamesakesApartByAmountAndDate() throws {
    let october = ExpectedIncome(
      name: "Зарплата", totalE4: AmountE4(whole: 50_000),
      dueDate: DateOnly(year: 2026, month: 10, day: 15))
    let november = ExpectedIncome(
      name: "зарплата", totalE4: AmountE4(whole: 40_000),
      dueDate: DateOnly(year: 2026, month: 11, day: 20))
    let bonus = ExpectedIncome(
      name: "Премия", totalE4: AmountE4(whole: 10_000),
      dueDate: DateOnly(year: 2026, month: 10, day: 30))
    XCTAssertTrue(actions.save([october, november, bonus]))

    let titles = ExpectedIncomeLabels.titles(
      try statuses(), money: { "\($0.decimal) \($1.code)" }, day: { $0.iso })
    XCTAssertEqual(titles[october.id], "Зарплата · 50000 RUB · 2026-10-15")
    XCTAssertEqual(titles[november.id], "зарплата · 40000 RUB · 2026-11-20")
    XCTAssertEqual(titles[bonus.id], "Премия")
  }
}
