import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// Two «Премия» expected — 10,000 today and 5,000 tomorrow — as the owner meets them: both save;
/// «+10000 премия» offers both in «Ожидаемое поступление», told apart by amount and date; the
/// first chosen and written is tied to it; «Закрыть полностью» only on the one that came whole;
/// «Архив (1)», «Вернуть» and ⌘Z; «Удалить…» asks in words, ⌘Z brings it back.
@MainActor
final class ExpectedIncomeFlowTests: XCTestCase {
  private var store: TransactionsStore!
  private var transactions: TransactionRepository!
  private var references: ReferenceRepository!
  private var planning: PlanningRepository!
  private var environment: AppEnvironment!
  private var compute: ComputeStore!
  private let today = DateOnly(year: 2026, month: 10, day: 7)
  private let salary = CoreKit.Category(kind: .income, name: "Заработок")

  override func setUp() async throws {
    let stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    transactions = TransactionRepository(writer: stack.writer)
    references = ReferenceRepository(writer: stack.writer)
    planning = PlanningRepository(writer: stack.writer)
    try references.save(salary)
    store = TransactionsStore()
    store.attach(transactions, references: references, planning: planning)
    environment = AppEnvironment()
    compute = ComputeStore(calendar: .utc, rebuildsInline: true)
  }

  private var actions: PlanningActions {
    PlanningActions(AppDependencies(environment: environment, store: store, compute: compute))
  }

  private func statuses() throws -> [ExpectedIncomeStatus] {
    let ledger = Ledger(
      dataset: Dataset(entries: try transactions.entries(from: .distantPast, to: .distantFuture)),
      calendar: .utc)
    return ExpectedIncomeRules.statuses(book: try planning.book(), ledger: ledger, today: today)
  }

  private static func russian(_ key: String) -> String {
    GuideFlowTests.russian(key, table: "Planning")
  }

  private let bonus = ExpectedIncome(
    name: "Премия", totalE4: AmountE4(whole: 10_000),
    dueDate: DateOnly(year: 2026, month: 10, day: 7))
  private let smaller = ExpectedIncome(
    name: "Премия", totalE4: AmountE4(whole: 5_000),
    dueDate: DateOnly(year: 2026, month: 10, day: 8))

  /// The whole walk of the hand check, step by step.
  func testTwoNamesakesFromSavingToClosingAndBack() throws {
    // «+ Поступление» twice, one name: both are kept.
    XCTAssertEqual(Self.russian("expected.add"), "+ Поступление")
    XCTAssertTrue(actions.save(bonus))
    XCTAssertTrue(actions.save(smaller))
    XCTAssertEqual(try planning.expected().map(\.name), ["Премия", "Премия"])

    // «+10000 премия», Tab: both offered in «Ожидаемое поступление», told apart.
    let open = try statuses().filter { !$0.isFulfilled && !$0.income.closed }
    XCTAssertEqual(Set(open.map(\.id)), [bonus.id, smaller.id])
    let titles = ExpectedIncomeLabels.titles(open, environment)
    XCTAssertEqual(
      titles[bonus.id],
      "Премия · " + environment.money.rounded(AmountE4(whole: 10_000), currency: .rub) + " · "
        + environment.dates.dayAndMonth(bonus.dueDate!))
    XCTAssertEqual(
      titles[smaller.id],
      "Премия · " + environment.money.rounded(AmountE4(whole: 5_000), currency: .rub) + " · "
        + environment.dates.dayAndMonth(smaller.dueDate!))

    // The first chosen, Return: the income is written and tied to it.
    let model = EntryDraftModel(references: references, transactions: transactions, calendar: .utc)
    model.reload()
    let parsed = InputLineParser(vocabulary: .empty, calendar: .utc)
      .parse("+10000 премия", today: today)
    model.apply(parsed, amount: AmountE4(whole: 10_000), today: today)
    XCTAssertEqual(model.draft.kind, .income)
    XCTAssertTrue(model.linksExpectedIncome)
    model.setCategory(salary.id, forPartAt: 0)
    model.expectedIncomeId = bonus.id
    let entry = try model.draftForSaving.materialize()
    let change = try XCTUnwrap(
      EntryCommit.change(
        entry: entry, openedCredit: nil, paidDebt: nil, expectedIncomeId: model.expectedIncomeId,
        day: today))
    XCTAssertTrue(store.apply(change))

    // «Закрыть полностью» on the one that came whole, not on the other.
    let after = try statuses()
    XCTAssertTrue(
      ExpectedIncomeRules.offersClosing(try XCTUnwrap(after.first { $0.id == bonus.id })))
    XCTAssertFalse(
      ExpectedIncomeRules.offersClosing(try XCTUnwrap(after.first { $0.id == smaller.id })))
    XCTAssertEqual(Self.russian("expected.closeFully"), "Закрыть полностью")

    // Closed: out of the list, «Архив (1)».
    XCTAssertTrue(actions.close(bonus))
    XCTAssertEqual(try statuses().map(\.id), [smaller.id])
    let archived = ExpectedIncomeBlock.archived(try planning.book().expected)
    XCTAssertEqual(archived.map(\.id), [bonus.id])
    let language = AppLanguage()
    XCTAssertTrue(
      language.format("expected.archive", table: "Planning", counts: archived.count)
        .hasSuffix("(1)"))

    // «Вернуть»: back in the list; ⌘Z: in the archive again.
    XCTAssertEqual(Self.russian("expected.restore"), "Вернуть")
    XCTAssertTrue(actions.reopen(try XCTUnwrap(archived.first)))
    XCTAssertEqual(Set(try statuses().map(\.id)), [bonus.id, smaller.id])
    store.undo()
    XCTAssertEqual(
      ExpectedIncomeBlock.archived(try planning.book().expected).map(\.id), [bonus.id])
  }

  /// «Удалить…»: «Удалить «Премия»?» and what stays; the income goes, ⌘Z brings it back.
  func testDeletingAsksInWordsAndUndoBringsItBack() throws {
    XCTAssertTrue(actions.save(bonus))
    XCTAssertTrue(actions.save(smaller))
    XCTAssertEqual(Self.russian("expected.delete"), "Удалить…")
    XCTAssertEqual(
      String(format: Self.russian("expected.deleteTitle"), smaller.name), "Удалить «Премия»?")
    XCTAssertEqual(
      Self.russian("expected.deleteMessage"),
      "Полученные доходы останутся, удалится только ожидание и привязки к нему. ⌘Z вернёт их.")
    XCTAssertTrue(actions.delete(smaller))
    XCTAssertEqual(try planning.expected().map(\.id), [bonus.id])
    store.undo()
    XCTAssertEqual(Set(try planning.expected().map(\.id)), [bonus.id, smaller.id])
  }
}
