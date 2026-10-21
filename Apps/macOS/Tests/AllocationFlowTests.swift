import AppCore
import AppDatabase
import SwiftUI
import XCTest

@testable import OhMyMoney

/// The allocation of an income and self-employment in the app: the sheet's lines come from the
/// rules, «Записать» puts the contributions and the transfers in one record and one ⌘Z takes
/// them out, «Не надо» puts the income away, the rest of a month goes where the owner said, the
/// ready categories of self-employment are made once, and the tax is paid with its month's key.
@MainActor
final class AllocationFlowTests: XCTestCase {
  private var stack: DatabaseStack!
  private var references: ReferenceRepository!
  private var planning: PlanningRepository!
  private var store: TransactionsStore!
  private var compute: ComputeStore!
  private var environment: AppEnvironment!

  private let main = PaymentMethod(name: "Основной", kind: .card, isDefault: true)
  private let savings = PaymentMethod(name: "Накопительный", kind: .account, cushion: true)
  private let goals = CoreKit.Category(kind: .expense, name: "Цели", systemRole: .goals)
  private let earnings = CoreKit.Category(kind: .income, name: "Заработок")
  private var trip = Goal(name: "Отпуск", targetE4: AmountE4(whole: 200_000))
  private var income: TransactionEntry!

  override func setUp() async throws {
    stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    references = ReferenceRepository(writer: stack.writer)
    planning = PlanningRepository(writer: stack.writer)
    store = TransactionsStore()
    store.attach(
      TransactionRepository(writer: stack.writer), references: references, planning: planning)
    compute = ComputeStore(calendar: .utc, rebuildsInline: true)
    environment = AppEnvironment()
    trip.accountId = savings.id
    trip.transfersOnContribution = true
    let when = CalendarContext.utc.noon(of: environment.today)
    let id = UUID()
    income = TransactionEntry(
      transaction: Transaction(
        id: id, kind: .income, occurredAt: when, amountE4: AmountE4(whole: 120_000),
        paymentMethodId: main.id, createdAt: when, updatedAt: when),
      parts: [
        TransactionPart(
          transactionId: id, categoryId: earnings.id, amountE4: AmountE4(whole: 120_000))
      ])
    _ = try planning.apply(
      PlanningChange(
        created: [income],
        upsert: PlanningRows(
          categories: [goals, earnings], goals: [trip], paymentMethods: [main, savings])))
  }

  private var deps: AppDependencies {
    AppDependencies(environment: environment, store: store, compute: compute)
  }

  private func show(rules: [AllocationRule] = [], settings: AllocationSettings = .standard) {
    compute.applyLight(
      DataSnapshot.build(
        dataset: Dataset(
          entries: [income], categories: [goals, earnings], paymentMethods: [main, savings],
          goals: [trip], allocationRules: rules, allocationSettings: settings),
        calendar: .utc, today: environment.today, context: SnapshotContext(),
        version: DataVersion(load: 0)))
  }

  private func stored() async throws -> Dataset {
    try await DatasetRepository(writer: stack.writer).load(version: 0)
  }

  private func allocated(_ dataset: Dataset) -> (transfers: Int, contributions: Int) {
    (
      dataset.transfers.filter { Allocation.income(ofKey: $0.externalId) != nil }.count,
      dataset.entries.filter {
        !$0.transaction.isDeleted && Allocation.income(ofKey: $0.transaction.externalId) != nil
      }.count
    )
  }

  func testTheSheetWritesOneRecordAndOneUndoTakesItOut() async throws {
    show(rules: [
      AllocationRule(target: .goal(trip.id), amount: .percent(10), sort: 0),
      AllocationRule(target: .cushion(nil), amount: .fixed(AmountE4(whole: 5_000), .rub), sort: 1),
    ])
    let snapshot = try XCTUnwrap(compute.snapshot)
    let sheet = try XCTUnwrap(AllocationActions.sheet(for: income.id, snapshot: snapshot))
    XCTAssertEqual(sheet.lines.count, 2)
    XCTAssertEqual(sheet.lines.first?.suggestedE4, AmountE4(whole: 12_000))
    var chosen: [String: AmountE4] = [:]
    for line in sheet.lines { chosen[line.id] = line.suggestedE4 }
    XCTAssertTrue(
      AllocationActions(deps).write(sheet: sheet, chosen: chosen, cushionAccount: savings.id))
    let written = try await stored()
    XCTAssertEqual(allocated(written).transfers, 2)
    XCTAssertEqual(allocated(written).contributions, 1)
    // The goal had no subcategory: it got one in the same record.
    XCTAssertNotNil(written.goals.first?.subcategoryId)
    XCTAssertEqual(written.allocationSettings.cushionAccountId, savings.id)
    XCTAssertEqual(
      Allocation.distributed(
        incomeId: income.id, entries: written.entries, transfers: written.transfers),
      AmountE4(whole: 17_000))
    store.undo()
    let undone = try await stored()
    XCTAssertEqual(allocated(undone).transfers, 0)
    XCTAssertEqual(allocated(undone).contributions, 0)
    XCTAssertNil(undone.goals.first?.subcategoryId)
  }

  /// «Удалить и распределение»: the income goes with its contributions and transfers, and one
  /// ⌘Z brings all of it back; an edit below what was allocated is said.
  func testDeletingAnIncomeTakesItsAllocationAlongInOneStep() async throws {
    show(rules: [
      AllocationRule(target: .goal(trip.id), amount: .percent(10), sort: 0),
      AllocationRule(target: .cushion(nil), amount: .fixed(AmountE4(whole: 5_000), .rub), sort: 1),
    ])
    let snapshot = try XCTUnwrap(compute.snapshot)
    let sheet = try XCTUnwrap(AllocationActions.sheet(for: income.id, snapshot: snapshot))
    var chosen: [String: AmountE4] = [:]
    for line in sheet.lines { chosen[line.id] = line.suggestedE4 }
    XCTAssertTrue(
      AllocationActions(deps).write(sheet: sheet, chosen: chosen, cushionAccount: savings.id))
    store.show(Ledger(dataset: try await stored(), calendar: .utc))
    let allocation = store.allocation(ofDeleting: [income.id])
    XCTAssertEqual(allocation.contributions.count, 1)
    XCTAssertEqual(allocation.transfers.count, 2)
    XCTAssertEqual(
      store.allocatedBeyond(incomeId: income.id, amount: AmountE4(whole: 10_000)),
      AmountE4(whole: 7_000))
    XCTAssertNil(store.allocatedBeyond(incomeId: income.id, amount: AmountE4(whole: 120_000)))
    XCTAssertTrue(
      store.delete(ids: [income.id] + allocation.contributions + allocation.transfers))
    let gone = try await stored()
    XCTAssertEqual(allocated(gone).transfers, 0)
    XCTAssertEqual(allocated(gone).contributions, 0)
    XCTAssertFalse(gone.entries.contains { $0.id == income.id && !$0.transaction.isDeleted })
    store.undo()
    let back = try await stored()
    XCTAssertEqual(allocated(back).transfers, 2)
    XCTAssertEqual(allocated(back).contributions, 1)
    XCTAssertTrue(back.entries.contains { $0.id == income.id && !$0.transaction.isDeleted })
  }

  func testNotNowPutsTheIncomeAway() async throws {
    show()
    XCTAssertTrue(AllocationActions(deps).decline(income.id))
    let declined = try await stored().allocationSettings.declined
    XCTAssertEqual(declined, [income.id])
  }

  func testTheDifferenceOfARaiseIsSpreadByTheRules() {
    let lines = [
      AllocationLine(
        id: "a", kind: .cushion(nil), ruleId: UUID(), suggestedE4: AmountE4(whole: 3_000),
        targetCurrency: .rub),
      AllocationLine(
        id: "b", kind: .account(UUID()), ruleId: UUID(), suggestedE4: AmountE4(whole: 1_000),
        targetCurrency: .rub),
      AllocationLine(
        id: "c", kind: .goal(UUID()), suggestedE4: AmountE4(whole: 9_000), targetCurrency: .rub),
    ]
    let spread = AllocationActions.spreading(AmountE4(whole: 1_000), over: lines)
    XCTAssertEqual(spread["a"], AmountE4(whole: 750))
    XCTAssertEqual(spread["b"], AmountE4(whole: 250))
    XCTAssertNil(spread["c"], "a hint without a rule is not spread over")
  }

  func testTheRestOfTheMonthGoesToTheCushionAndIsRemembered() throws {
    show()
    let snapshot = try XCTUnwrap(compute.snapshot)
    let offer = MonthRestOffer(
      month: environment.today.monthKey.previous, amountE4: AmountE4(whole: 7_000), target: nil)
    let change = try XCTUnwrap(
      AllocationActions.monthRestChange(
        offer, to: .cushion, amount: offer.amountE4, cushionAccount: savings.id,
        snapshot: snapshot, at: Date()))
    XCTAssertEqual(change.upsert.transfers.count, 1)
    XCTAssertEqual(change.upsert.transfers.first?.toAccountId, savings.id)
    XCTAssertEqual(
      change.settings[AllocationSettings.monthRestDoneKey] ?? nil, offer.month.iso)
    XCTAssertEqual(change.settings[AllocationSettings.monthRestTargetKey] ?? nil, "cushion")
    XCTAssertNil(
      AllocationActions.monthRestChange(
        offer, to: .cushion, amount: offer.amountE4, cushionAccount: nil, snapshot: snapshot,
        at: Date()))
  }

  func testTheRulesRefuseASecondRuleOfAGoalOrOfTheCushion() {
    let goalRule = AllocationRule(target: .goal(trip.id), amount: .percent(10))
    let cushionRule = AllocationRule(target: .cushion(nil), amount: .percent(10))
    XCTAssertEqual(
      AllocationRulesText.refusal(
        AllocationRule(target: .goal(trip.id), amount: .percent(5)), among: [goalRule]),
      "rules.refusal.goalTaken")
    XCTAssertEqual(
      AllocationRulesText.refusal(
        AllocationRule(target: .cushion(savings.id), amount: .percent(5)), among: [cushionRule]),
      "rules.refusal.cushionTaken")
    XCTAssertNil(AllocationRulesText.refusal(goalRule, among: [goalRule]))
    XCTAssertEqual(
      AllocationRulesText.refusal(
        AllocationRule(target: .account(main.id), amount: .percent(0)), among: []),
      "rules.refusal.amount")
    XCTAssertEqual(AllocationRulesText.percent("12,5"), Decimal(string: "12.5"))
    XCTAssertNil(AllocationRulesText.percent("120"))
  }

  // MARK: Self-employment

  func testTurningSelfEmploymentOnMakesTheReadyCategoriesOnce() throws {
    let names = SelfEmploymentActions.Names.of(environment)
    let first = SelfEmploymentActions.enabling(
      ready: true, categories: [goals, earnings], settings: .standard, allocation: .standard,
      names: names, at: Date())
    // «Заработок» is there: «Самозанятость» and its two are made under it.
    XCTAssertEqual(first.upsert.categories.count, 3)
    let rates = first.upsert.categories.compactMap(\.tax).map(\.rate).sorted()
    XCTAssertEqual(rates, [4, 6])
    XCTAssertTrue(first.upsert.categories.compactMap(\.tax).allSatisfy(\.npd))
    XCTAssertEqual(first.settings[SelfEmploymentSettings.enabledKey] ?? nil, "1")
    let again = SelfEmploymentActions.enabling(
      ready: true, categories: [goals, earnings] + first.upsert.categories, settings: .standard,
      allocation: .standard, names: names, at: Date())
    XCTAssertTrue(again.upsert.categories.isEmpty, "nothing is made twice")
    let own = SelfEmploymentActions.enabling(
      ready: false, categories: [], settings: .standard, allocation: .standard, names: names,
      at: Date())
    XCTAssertTrue(own.upsert.categories.isEmpty)
  }

  /// «Заплатить…» of a quarter of a tax at another rate: the key of the quarter, which the tax of
  /// self-employment reads as paid; one ⌘Z takes it back.
  func testTheTaxOfAQuarterIsPaidWithTheKeyOfItsQuarter() async throws {
    show()
    let quarter = TaxQuarter(of: environment.today.monthKey)
    XCTAssertTrue(
      SelfEmploymentActions(deps).pay(
        quarter: quarter, amount: AmountE4(whole: 6_000), from: main.id, on: environment.today))
    let paid = try await stored()
    let payment = paid.entries.first { NPDTax.paidQuarter($0.transaction.externalId) != nil }
    XCTAssertEqual(payment?.transaction.externalId, quarter.paymentKey)
    XCTAssertEqual(payment?.transaction.amountE4, AmountE4(whole: 6_000))
    XCTAssertEqual(payment?.parts.first?.categoryId, paid.selfEmployment.taxCategoryId)
    store.undo()
    let undone = try await stored()
    XCTAssertFalse(
      undone.entries.contains {
        !$0.transaction.isDeleted && NPDTax.paidQuarter($0.transaction.externalId) != nil
      })
  }

  func testTheTaxIsPaidInItsCategoryWithTheKeyOfItsMonth() async throws {
    show()
    let month = environment.today.monthKey.previous
    XCTAssertTrue(
      SelfEmploymentActions(deps).pay(
        month: month, amount: AmountE4(whole: 2_178), from: main.id, on: environment.today))
    let paid = try await stored()
    let payment = paid.entries.first { NPDTax.paidMonth($0.transaction.externalId) != nil }
    XCTAssertEqual(payment?.transaction.externalId, NPDTax.paymentKey(month: month))
    let tax = SelfEmploymentActions.Names.of(environment).tax
    XCTAssertTrue(paid.categories.contains { $0.kind == .expense && $0.name == tax })
    XCTAssertNotNil(paid.selfEmployment.taxCategoryId)
    store.undo()
    let undone = try await stored()
    XCTAssertFalse(
      undone.entries.contains {
        !$0.transaction.isDeleted && NPDTax.paidMonth($0.transaction.externalId) != nil
      })
  }

  func testTheWordsAreInBothLanguages() {
    let keys = [
      "allocation.title", "allocation.unallocated", "allocation.write", "allocation.decline",
      "allocation.shownNotWritten", "allocation.note.goalComplete", "rules.title",
      "monthRest.title", "npd.pay.title", "npd.gap.less", "selfEmployed.block.tax",
      "selfEmployed.setup.title", "selfEmployed.category.tax",
    ]
    for choice in [AppLanguage.Choice.russian, .english] {
      let environment = AppEnvironment()
      environment.language.choice = choice
      for key in keys {
        XCTAssertNotEqual(AllocationText.t(key, environment), key, "\(key) in \(choice)")
      }
      XCTAssertNotEqual(
        environment.language("planning.free.npdTax", table: "Planning"), "planning.free.npdTax")
    }
    let ru = AppEnvironment()
    ru.language.choice = .russian
    XCTAssertEqual(
      AllocationText.format("allocation.earlier", ru, "70,000 ₽", "120,000 ₽"),
      "Распределено 70,000 ₽ из 120,000 ₽")
    XCTAssertEqual(
      SelfEmploymentFigures.gapText(AmountE4(whole: -2), ru).hasPrefix("ФНС насчитала на"), true)
  }

  /// The sheet lays out in a window narrower than a phone column at least, in both languages.
  func testTheSheetLaysOut() throws {
    show(rules: [AllocationRule(target: .goal(trip.id), amount: .percent(10))])
    for choice in [AppLanguage.Choice.russian, .english] {
      environment.language.choice = choice
      let host = NSHostingView(
        rootView: AllocationSheetView(request: AllocationRequest(incomeId: income.id))
          .appDependencies(deps))
      host.layoutSubtreeIfNeeded()
      XCTAssertGreaterThanOrEqual(host.fittingSize.width, 460)
      XCTAssertLessThan(host.fittingSize.width, 1_024, "\(choice)")
    }
  }
}
