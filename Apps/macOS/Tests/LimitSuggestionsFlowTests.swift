import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// «Предложить лимиты…» end to end against a database: the suggestions come from the data on
/// screen, the kept rows are written as one write, and one ⌘Z takes every one of them back.
@MainActor
final class LimitSuggestionsFlowTests: XCTestCase {
  private var store: TransactionsStore!
  private var references: ReferenceRepository!
  private var planning: PlanningRepository!
  private var compute: ComputeStore!
  private var environment: AppEnvironment!

  private let food = CoreKit.Category(kind: .expense, name: "Food")
  private let taxi = CoreKit.Category(kind: .expense, name: "Taxi")
  private let gifts = CoreKit.Category(kind: .expense, name: "Gifts")
  private let unknown = CoreKit.Category(kind: .expense, name: "Unknown", systemRole: .unknown)

  override func setUp() async throws {
    let stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    references = ReferenceRepository(writer: stack.writer)
    planning = PlanningRepository(writer: stack.writer)
    store = TransactionsStore()
    store.attach(
      TransactionRepository(writer: stack.writer), references: references, planning: planning)
    compute = ComputeStore(calendar: .utc, rebuildsInline: true)
    environment = AppEnvironment()
    for category in [food, taxi, gifts, unknown] { try references.save(category) }
  }

  private var deps: AppDependencies {
    AppDependencies(environment: environment, store: store, compute: compute)
  }

  /// Food and Taxi in each of the three full months before today, Gifts in one only, and
  /// money in «Не помню», which takes no limit.
  private func show(budgets: [Budget] = []) {
    let today = environment.today
    var entries: [TransactionEntry] = []
    var month = today.monthKey
    for _ in 0..<3 {
      month = month.previous
      entries.append(entry(food, rubles: 12_300, on: month.firstDay))
      entries.append(entry(taxi, rubles: 2_100, on: month.firstDay))
      entries.append(entry(unknown, rubles: 900, on: month.firstDay))
    }
    entries.append(entry(gifts, rubles: 5_000, on: month.firstDay))
    compute.applyLight(
      DataSnapshot.build(
        dataset: Dataset(
          entries: entries, categories: [food, taxi, gifts, unknown],
          planning: PlanningBook(budgets: budgets)),
        calendar: .utc, today: today, context: SnapshotContext(),
        version: DataVersion(load: 0)))
  }

  private func entry(
    _ category: CoreKit.Category, rubles: Int64, on day: DateOnly
  )
    -> TransactionEntry
  {
    let when = CalendarContext.utc.startOfDay(day).addingTimeInterval(12 * 3600)
    let transaction = Transaction(
      kind: .expense, occurredAt: when, amountE4: AmountE4(whole: rubles), createdAt: when,
      updatedAt: when)
    return TransactionEntry(
      transaction: transaction,
      parts: [
        TransactionPart(
          transactionId: transaction.id, categoryId: category.id, quality: .neutral,
          qualitySource: .manual, amountE4: AmountE4(whole: rubles), forWhom: .me)
      ])
  }

  func testTheSuggestionsAreTheCategoriesSpentOnWithoutALimit() {
    show()
    let suggestions = PlanningActions(deps).suggestedLimits()
    XCTAssertEqual(suggestions.map(\.categoryId), [food.id, taxi.id])
    XCTAssertEqual(suggestions.map(\.usual), [AmountE4(whole: 13_000), AmountE4(whole: 2_500)])
    XCTAssertEqual(
      suggestions.map(\.tenPercentLess), [AmountE4(whole: 12_000), AmountE4(whole: 2_000)])
  }

  func testTheKeptRowsAreOneWriteAndOneUndoTakesThemAllBack() throws {
    show()
    let written = PlanningActions(deps).addSuggestedLimits([
      (food.id, AmountE4(whole: 13_000)), (taxi.id, AmountE4(whole: 1_800)),
    ])
    XCTAssertEqual(written, 2)
    let stored = try planning.budgets()
    XCTAssertEqual(Set(stored.compactMap(\.categoryId)), [food.id, taxi.id])
    XCTAssertEqual(
      stored.first { $0.categoryId == taxi.id }?.amountE4, AmountE4(whole: 1_800),
      "the amount typed over the suggestion")
    XCTAssertTrue(
      stored.allSatisfy { $0.startMonth == environment.today.monthKey && !$0.rollover })

    store.undo()
    XCTAssertEqual(try planning.budgets(), [], "one step of ⌘Z for every limit")
  }

  /// A limit saved since the sheet opened is not written twice, a row the rules refuse is left
  /// out, and the rest is still written.
  func testACategoryThatGotALimitMeanwhileIsLeftOut() throws {
    show()
    let first = Budget(scope: .category, categoryId: food.id, amountE4: AmountE4(whole: 9_000))
    XCTAssertTrue(PlanningActions(deps).save(first))
    show(budgets: try planning.budgets())
    let written = PlanningActions(deps).addSuggestedLimits([
      (food.id, AmountE4(whole: 13_000)), (taxi.id, AmountE4(whole: 2_500)),
      (unknown.id, AmountE4(whole: 1_000)),
    ])
    XCTAssertEqual(written, 1)
    let stored = try planning.budgets()
    XCTAssertEqual(stored.count, 2)
    XCTAssertEqual(stored.first { $0.categoryId == food.id }?.amountE4, AmountE4(whole: 9_000))

    show(budgets: stored)
    XCTAssertEqual(PlanningActions(deps).suggestedLimits(), [], "nothing left to suggest")
  }

  func testNothingChosenWritesNothing() throws {
    show()
    XCTAssertEqual(PlanningActions(deps).addSuggestedLimits([]), 0)
    XCTAssertEqual(try planning.budgets(), [])
  }

  func testTheWordsOfTheSheetAreTranslated() {
    for key in [
      "limits.suggest.open", "limits.suggest.title", "limits.suggest.subtitle",
      "limits.suggest.none", "limits.suggest.basis.usual", "limits.suggest.basis.tenPercentLess",
      "limits.suggest.usualMonth", "limits.suggest.amount", "limits.suggest.amountOf",
    ] {
      XCTAssertNotEqual(environment.language(key, table: "Planning"), key, key)
    }
    XCTAssertNotEqual(
      environment.format("limits.suggest.add", table: "Planning", counts: 3), "limits.suggest.add")
  }
}
