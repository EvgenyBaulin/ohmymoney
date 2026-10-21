import AppCore
import XCTest

@testable import OhMyMoney

/// How the owner arranges the Planning screen and what it says on top: blocks dragged, moved up
/// and down, put back, an order carried by an archive of another build, three, five, ten or all
/// items of a long block, the nearest items first; the sentence over the blocks and the ribbon of
/// the next fourteen days — a bill on its last day and one a day too late, an advance and a
/// salary, dollars without a rate.
@MainActor
final class PlanningScenarioTestsLayout: XCTestCase {
  private typealias S = PlanningScenario
  // XCTest makes an instance for every test, so every test has a domain of its own.
  private let suiteName = "ohmymoney.tests.c.\(UUID())"
  private lazy var defaults = UserDefaults(suiteName: suiteName) ?? .standard

  override func tearDown() async throws {
    defaults.removePersistentDomain(forName: suiteName)
    try await super.tearDown()
  }

  // MARK: The order of the blocks

  func testANewMacShowsTheStandardOrder() {
    let store = PlanningLayoutStore(defaults: defaults)
    XCTAssertEqual(store.order, PlanningBlocks.standard)
    XCTAssertEqual(store.length(of: .payments), .count(5))
    XCTAssertFalse(store.canMove(.freeMoney, by: -1))
    XCTAssertFalse(store.canMove(.selfEmployment, by: 1))
  }

  func testDraggingABlockDownLandsItAfterTheTarget() {
    let store = PlanningLayoutStore(defaults: defaults)
    XCTAssertTrue(store.drop(.freeMoney, onto: .limits))
    XCTAssertEqual(
      Array(store.order.prefix(5)),
      [.payments, .subscriptions, .expectedIncome, .limits, .freeMoney])
    XCTAssertFalse(store.drop(.goals, onto: .goals))
  }

  func testDraggingABlockUpLandsItBeforeTheTarget() {
    let store = PlanningLayoutStore(defaults: defaults)
    store.drop(.advice, onto: .payments)
    XCTAssertEqual(Array(store.order.prefix(3)), [.freeMoney, .advice, .payments])
  }

  func testTheOrderLivesOnInTheDefaultsAndComesBack() {
    let store = PlanningLayoutStore(defaults: defaults)
    store.move(.goals, by: -1)
    let reopened = PlanningLayoutStore(defaults: defaults)
    XCTAssertEqual(reopened.order, store.order)
    XCTAssertEqual(reopened.order.firstIndex(of: .goals), 4)
    reopened.resetOrder()
    XCTAssertEqual(PlanningLayoutStore(defaults: defaults).order, PlanningBlocks.standard)
  }

  func testMovingPastTheEdgeMovesNothing() {
    let store = PlanningLayoutStore(defaults: defaults)
    store.move(.freeMoney, by: -1)
    store.move(.selfEmployment, by: 1)
    XCTAssertEqual(store.order, PlanningBlocks.standard)
    XCTAssertNil(defaults.string(forKey: PlanningLayoutStore.orderKey))
  }

  func testAStoredOrderOfAnotherBuildReadsAsEveryBlockOnce() {
    defaults.set(" goals, ribbon ,goals,,freeMoney", forKey: PlanningLayoutStore.orderKey)
    let order = PlanningLayoutStore(defaults: defaults).order
    XCTAssertEqual(Array(order.prefix(2)), [.goals, .freeMoney])
    XCTAssertEqual(order.count, PlanningBlock.allCases.count)
    XCTAssertEqual(Set(order), Set(PlanningBlock.allCases))
  }

  func testAnEmptyStoredOrderIsTheStandardOne() {
    XCTAssertEqual(PlanningBlocks.decode(""), PlanningBlocks.standard)
    XCTAssertEqual(PlanningBlocks.decode(nil), PlanningBlocks.standard)
    XCTAssertTrue(PlanningBlocks.isStandard([.freeMoney]))
  }

  func testTheArchiveCarriesTheOrderAsEveryBlockOnce() {
    PlanningLayoutStore.applyPortable(
      [PlanningLayoutStore.orderKey: "advice,unknown"], to: defaults)
    XCTAssertEqual(PlanningLayoutStore(defaults: defaults).order.first, .advice)
    XCTAssertTrue(PlanningLayoutStore.portableOrder(in: defaults).hasPrefix("advice,freeMoney"))
    let before = defaults.string(forKey: PlanningLayoutStore.orderKey)
    PlanningLayoutStore.applyPortable([:], to: defaults)
    XCTAssertEqual(defaults.string(forKey: PlanningLayoutStore.orderKey), before)
  }

  func testTheBlocksLayInTwoColumnsOneAfterAnother() {
    let columns = PlanningBlocks.columns([.freeMoney, .payments, .limits], count: 2)
    XCTAssertEqual(columns, [[.freeMoney, .limits], [.payments]])
    XCTAssertEqual(PlanningBlocks.columns([.goals], count: 0), [[.goals]])
  }

  // MARK: How many items

  func testABlocksOwnLengthWinsAndCanBeTakenBack() {
    let store = PlanningLayoutStore(defaults: defaults)
    store.setLength(.count(10))
    store.setOwnLength(.count(3), for: .subscriptions)
    XCTAssertEqual(store.length(of: .subscriptions), .count(3))
    XCTAssertEqual(store.length(of: .payments), .count(10))
    let reopened = PlanningLayoutStore(defaults: defaults)
    XCTAssertEqual(reopened.length(of: .subscriptions), .count(3))
    reopened.setOwnLength(nil, for: .subscriptions)
    XCTAssertNil(defaults.string(forKey: PlanningLayoutStore.lengthKey(for: .subscriptions)))
    XCTAssertEqual(PlanningLayoutStore(defaults: defaults).length(of: .subscriptions), .count(10))
  }

  func testOnlyTheLengthsOnOfferAreRead() {
    XCTAssertEqual(PlanningListLength(stored: " all "), .all)
    XCTAssertEqual(PlanningListLength(stored: "10"), .count(10))
    XCTAssertNil(PlanningListLength(stored: "7"))
    XCTAssertNil(PlanningListLength(stored: "-3"))
    XCTAssertNil(PlanningListLength(stored: nil))
    defaults.set("4", forKey: PlanningLayoutStore.lengthKey)
    XCTAssertEqual(PlanningLayoutStore(defaults: defaults).length, .standard)
  }

  func testWhichBlocksHaveAShortList() {
    XCTAssertEqual(
      PlanningBlock.allCases.filter(\.hasShortList),
      [.payments, .subscriptions, .expectedIncome, .goals])
  }

  func testTheNearestComeFirstAndTheUndatedLast() {
    let items: [(String, DateOnly?)] = [
      ("b", S.day("2026-11-01")), ("none", nil), ("a", S.day("2026-10-20")),
      ("c", S.day("2026-11-01")),
    ]
    XCTAssertEqual(
      PlanningShortList.nearestFirst(items, date: \.1).map(\.0), ["a", "b", "c", "none"])
  }

  func testShowAllOnlyWhenThereIsMoreThanTheLength() {
    XCTAssertEqual(
      PlanningShortList.split(total: 7, length: .count(5), expanded: false).hidden, 2)
    XCTAssertEqual(PlanningShortList.split(total: 5, length: .count(5), expanded: false).hidden, 0)
    XCTAssertEqual(PlanningShortList.split(total: 7, length: .count(5), expanded: true).shown, 7)
    XCTAssertEqual(PlanningShortList.split(total: 70, length: .all, expanded: false).shown, 70)
  }

  // MARK: The sentence

  func testTheSentenceWaitsForTheFirstCount() {
    let free = FreeMoney(
      accounts: AccountsSnapshot.empty, plan: CashPlan(), stillExpected: .zero,
      today: S.day("2026-10-14"), until: S.day("2026-10-31"))
    XCTAssertNil(PlanningSummary(free))
  }

  // MARK: The ribbon

  private let home = CoreKit.Category(kind: .expense, name: "Дом")

  private func ribbon(
    scheduled: [ScheduledPayment] = [], expected: [ExpectedIncome] = [],
    rubPerUnit: [CurrencyCode: Decimal] = [:], today: String = "2026-10-14"
  ) -> PlanningRibbon {
    let book = PlanningBook(scheduled: scheduled, expected: expected)
    let ledger = S.ledger([], categories: [home], planning: book)
    let day = S.day(today)
    let plans = CalendarPlans.collect(
      ledger: ledger, book: book, today: day,
      through: PlanningRibbon.range(today: day).end, rubPerUnit: rubPerUnit)
    return PlanningRibbon.build(plans: plans, today: day, rubPerUnit: rubPerUnit)
  }

  private func bill(
    _ whole: Int64, _ next: String, currency: CurrencyCode = .rub
  )
    -> ScheduledPayment
  {
    ScheduledPayment(
      name: "Счёт \(next)", amountE4: S.rub(whole), currency: currency, categoryId: home.id,
      day: S.day(next).day, nextDate: S.day(next))
  }

  func testTheRibbonIsTodayAndThirteenDaysMore() {
    let empty = ribbon()
    XCTAssertEqual(empty.days.count, 14)
    XCTAssertEqual(empty.days.first?.day, S.day("2026-10-14"))
    XCTAssertEqual(empty.days.last?.day, S.day("2026-10-27"))
    XCTAssertTrue(empty.isEmpty)
  }

  func testABillOnTheLastDayIsOnItAndOneADayLaterIsNot() {
    let result = ribbon(scheduled: [bill(1_000, "2026-10-27"), bill(2_000, "2026-10-28")])
    XCTAssertEqual(result.days.last?.payments.count, 1)
    XCTAssertEqual(result.paymentsRub, S.rub(1_000))
  }

  func testTheRibbonCrossesTheEndOfTheYear() {
    let result = ribbon(scheduled: [bill(1_000, "2027-01-02")], today: "2026-12-25")
    XCTAssertEqual(result.days.first { !$0.isEmpty }?.day, S.day("2027-01-02"))
  }

  func testAnOverdueBillIsNotOnTheRibbon() {
    XCTAssertTrue(ribbon(scheduled: [bill(1_000, "2026-10-10")]).isEmpty)
  }

  func testAnExpectedSalaryIsOnTheIncomeLane() {
    let salary = ExpectedIncome(
      name: "Зарплата", kind: .recurring, totalE4: S.rub(80_000),
      dueDate: S.day("2026-10-25"), freq: .monthly, day: 25)
    let result = ribbon(expected: [salary])
    let day = result.days.first { $0.day == S.day("2026-10-25") }
    XCTAssertEqual(day?.incomes.map(\.amount), [S.rub(80_000)])
    XCTAssertEqual(result.incomesRub, S.rub(80_000))
    XCTAssertTrue(day?.payments.isEmpty ?? false)
  }

  func testDollarsWithoutARateAreShownButNotAdded() {
    let result = ribbon(scheduled: [bill(10, "2026-10-20", currency: .usd)])
    XCTAssertEqual(result.withoutRate, [.usd])
    XCTAssertEqual(result.paymentsRub, .zero)
    XCTAssertFalse(result.isEmpty)
    let rated = ribbon(scheduled: [bill(10, "2026-10-20", currency: .usd)], rubPerUnit: [.usd: 90])
    XCTAssertEqual(rated.paymentsRub, S.rub(900))
    XCTAssertTrue(rated.withoutRate.isEmpty)
  }
}
