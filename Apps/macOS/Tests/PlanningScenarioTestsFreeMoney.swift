import AppCore
import XCTest

@testable import OhMyMoney

/// «Можно тратить сейчас» and its grey line as the Planning screen gets them from a snapshot:
/// a count of the main account on the 1st, then spending, bills on the 20th, a weekly class,
/// an overdue bill, a bill on an account out of the summary, dollars with and without a rate,
/// goal money, an event's budget, the tax of self-employment, the cushion kept apart, a later
/// day D, and the rest of the month offered on the 1st of the next.
final class PlanningScenarioTestsFreeMoney: XCTestCase {
  private typealias S = PlanningScenario

  /// The books of one person on one day, built into a snapshot the way the compute step does.
  private struct World {
    var main = PaymentMethod(name: "Основной", kind: .card, isDefault: true)
    var categories: [CoreKit.Category] = []
    var accounts: [PaymentMethod] = []
    var groups: [AccountGroup] = []
    var entries: [TransactionEntry] = []
    var transfers: [Transfer] = []
    var goals: [Goal] = []
    var events: [Event] = []
    var book = PlanningBook()
    var capital = CapitalSettings.standard
    var selfEmployment = SelfEmploymentSettings.standard
    var allocation = AllocationSettings.standard
    var rubPerUnit: [CurrencyCode: Decimal] = [:]

    init() { accounts = [main] }

    mutating func count(_ account: UUID, _ whole: Int64, on day: String) {
      let reconciliation = Reconciliation(
        date: S.day(day), reconciledAt: S.calendar.moment(S.day(day), hour: 9, minute: 0),
        actualTotalRubE4: S.rub(whole), kind: .accounts, origin: .account)
      book.reconciliations.append(reconciliation)
      book.reconciledBalances.append(
        ReconciledBalance(
          reconciliationId: reconciliation.id, accountId: account, currency: .rub,
          actualE4: S.rub(whole)))
    }

    func snapshot(today: String) -> PlanningSnapshot {
      var context = SnapshotContext()
      context.rubPerUnit = rubPerUnit
      return DataSnapshot.build(
        dataset: Dataset(
          entries: entries, categories: categories, events: events, paymentMethods: accounts,
          goals: goals, planning: book, transfers: transfers, accountGroups: groups,
          capitalSettings: capital, selfEmployment: selfEmployment,
          allocationSettings: allocation),
        calendar: S.calendar, today: S.day(today), context: context,
        version: DataVersion(load: 0)
      ).planning
    }
  }

  private let food = CoreKit.Category(kind: .expense, name: "Продукты")
  private let home = CoreKit.Category(kind: .expense, name: "Дом")

  private func counted(_ whole: Int64 = 100_000) -> World {
    var world = World()
    world.categories = [food, home]
    world.count(world.main.id, whole, on: "2026-10-01")
    return world
  }

  private func bill(
    _ world: World, _ whole: Int64, next: String, freq: Frequency = .monthly,
    currency: CurrencyCode = .rub, account: UUID? = nil, end: String? = nil,
    active: Bool = true, kind: ScheduledKind = .bill
  ) -> ScheduledPayment {
    let date = S.day(next)
    return ScheduledPayment(
      name: "Счёт", kind: kind, amountE4: S.rub(whole), currency: currency,
      categoryId: home.id, paymentMethodId: account ?? world.main.id, freq: freq,
      day: Recurrence.anchor(of: date, freq: freq).day,
      month: Recurrence.anchor(of: date, freq: freq).month, nextDate: date,
      endDate: end.map(S.day), active: active)
  }

  private func line(_ free: FreeMoney, _ key: String) -> AmountE4? {
    free.lines.first { $0.key == key }?.amount
  }

  // MARK: Money now

  func testWithoutACountThereIsNothingToSpendYet() {
    var world = World()
    world.categories = [food]
    let free = world.snapshot(today: "2026-10-14").freeMoney
    XCTAssertEqual(free.state, .noReconciliation)
    XCTAssertNil(free.main)
    XCTAssertNil(free.grey)
    XCTAssertEqual(free.dailyGuide, .zero)
  }

  func testACountIsTheMoneyNowUntilTheEndOfTheMonth() {
    let free = counted().snapshot(today: "2026-10-14").freeMoney
    XCTAssertEqual(free.state, .ready)
    XCTAssertEqual(free.main, S.rub(100_000))
    XCTAssertEqual(free.grey, S.rub(100_000))
    XCTAssertEqual(free.until, S.day("2026-10-31"))
    XCTAssertEqual(free.days, 18)
  }

  func testOnTheLastDayOfTheMonthOneDayIsLeft() {
    let free = counted().snapshot(today: "2026-10-31").freeMoney
    XCTAssertEqual(free.days, 1)
    XCTAssertEqual(free.dailyGuide, S.rub(100_000))
  }

  func testSpendingAfterTheCountComesOffTheMoney() {
    var world = counted()
    world.entries = [
      S.entry(.expense, S.rub(2_500), on: "2026-10-05", category: food.id, account: world.main.id)
    ]
    XCTAssertEqual(world.snapshot(today: "2026-10-14").freeMoney.main, S.rub(97_500))
  }

  func testSpendingBeforeTheCountIsAlreadyInIt() {
    var world = counted()
    world.entries = [
      S.entry(.expense, S.rub(2_500), on: "2026-09-25", category: food.id, account: world.main.id)
    ]
    XCTAssertEqual(world.snapshot(today: "2026-10-14").freeMoney.main, S.rub(100_000))
  }

  func testIncomeAfterTheCountAddsToTheMoney() {
    var world = counted()
    let salary = CoreKit.Category(kind: .income, name: "Зарплата")
    world.categories.append(salary)
    world.entries = [
      S.entry(.income, S.rub(50_000), on: "2026-10-10", category: salary.id, account: world.main.id)
    ]
    XCTAssertEqual(world.snapshot(today: "2026-10-14").freeMoney.main, S.rub(150_000))
  }

  // MARK: Bills

  func testABillOnThe20thIsHeldBack() {
    var world = counted()
    world.book.scheduled = [bill(world, 3_000, next: "2026-10-20")]
    let free = world.snapshot(today: "2026-10-14").freeMoney
    XCTAssertEqual(line(free, FreeMoney.Key.scheduled), S.rub(3_000))
    XCTAssertEqual(free.plan.scheduledDueCount, 1)
    XCTAssertEqual(free.grey, S.rub(97_000))
    XCTAssertEqual(free.main, S.rub(100_000))
  }

  func testABillOfNextMonthIsNotHeldBackThisMonth() {
    var world = counted()
    world.book.scheduled = [bill(world, 3_000, next: "2026-11-01")]
    let free = world.snapshot(today: "2026-10-14").freeMoney
    XCTAssertEqual(line(free, FreeMoney.Key.scheduled), .zero)
  }

  func testAWeeklyClassIsHeldBackForEveryWeekLeft() {
    var world = counted()
    world.book.scheduled = [bill(world, 500, next: "2026-10-15", freq: .weekly)]
    let free = world.snapshot(today: "2026-10-14").freeMoney
    XCTAssertEqual(line(free, FreeMoney.Key.scheduled), S.rub(1_500))
    XCTAssertEqual(free.plan.scheduledDueCount, 3)
  }

  func testAnOverdueBillIsStillHeldBackAndSaidToBeOverdue() {
    var world = counted()
    let late = bill(world, 3_000, next: "2026-10-05")
    world.book.scheduled = [late]
    let planning = world.snapshot(today: "2026-10-14")
    // The 5th of October and of nothing later this month.
    XCTAssertEqual(line(planning.freeMoney, FreeMoney.Key.scheduled), S.rub(3_000))
    XCTAssertEqual(planning.freeMoney.overdue, S.rub(3_000))
    XCTAssertTrue(planning.scheduled.first?.isOverdue ?? false)
    XCTAssertTrue(planning.overdue.contains { $0.subject == .scheduled(late.id) })
  }

  func testAPausedBillHoldsNothingBack() {
    var world = counted()
    world.book.scheduled = [bill(world, 3_000, next: "2026-10-20", active: false)]
    let planning = world.snapshot(today: "2026-10-14")
    XCTAssertEqual(line(planning.freeMoney, FreeMoney.Key.scheduled), .zero)
    XCTAssertTrue(planning.scheduled.isEmpty)
  }

  func testABillThatEndedHasNoStatus() {
    var world = counted()
    world.book.scheduled = [bill(world, 3_000, next: "2026-10-20", end: "2026-10-19")]
    XCTAssertTrue(world.snapshot(today: "2026-10-14").scheduled.isEmpty)
  }

  func testAOneOffBillCostsNothingPerMonth() throws {
    var world = counted()
    world.book.scheduled = [bill(world, 7_000, next: "2026-10-25", end: "2026-10-25")]
    let status = try XCTUnwrap(world.snapshot(today: "2026-10-14").scheduled.first)
    XCTAssertTrue(status.isOneOff)
    XCTAssertEqual(status.monthly, .zero)
    XCTAssertEqual(status.yearly, .zero)
    XCTAssertEqual(
      line(world.snapshot(today: "2026-10-14").freeMoney, FreeMoney.Key.scheduled),
      S.rub(7_000))
  }

  func testABillOnAnAccountOutOfTheSummaryStaysOut() {
    var world = counted()
    let apart = AccountGroup(name: "Отложенное", inSummary: false)
    let stash = PaymentMethod(name: "Копилка", kind: .account, groupId: apart.id)
    world.groups = [apart]
    world.accounts.append(stash)
    world.count(stash.id, 40_000, on: "2026-10-01")
    world.book.scheduled = [bill(world, 3_000, next: "2026-10-20", account: stash.id)]
    let free = world.snapshot(today: "2026-10-14").freeMoney
    XCTAssertEqual(free.main, S.rub(100_000))
    XCTAssertEqual(line(free, FreeMoney.Key.scheduled), .zero)
    XCTAssertEqual(free.excluded.first?.totalRub, S.rub(40_000))
  }

  func testABillOnAnArchivedAccountIsTheMainAccountsAndSaysSo() throws {
    var world = counted()
    let old = PaymentMethod(name: "Старая карта", kind: .card, archived: true)
    world.accounts.append(old)
    world.book.scheduled = [bill(world, 3_000, next: "2026-10-20", account: old.id)]
    let planning = world.snapshot(today: "2026-10-14")
    XCTAssertEqual(line(planning.freeMoney, FreeMoney.Key.scheduled), S.rub(3_000))
    XCTAssertTrue(try XCTUnwrap(planning.scheduled.first).accountArchived)
  }

  func testADollarBillWithoutARateIsListedNotGuessed() {
    var world = counted()
    world.book.scheduled = [bill(world, 10, next: "2026-10-20", currency: .usd)]
    let free = world.snapshot(today: "2026-10-14").freeMoney
    XCTAssertEqual(line(free, FreeMoney.Key.scheduled), .zero)
    XCTAssertEqual(free.planWithoutRate, [.usd])
    XCTAssertEqual(free.plan.scheduledDueCount, 0)
  }

  func testADollarBillCountsAtTodaysRate() {
    var world = counted()
    world.rubPerUnit = [.usd: 90]
    world.book.scheduled = [bill(world, 10, next: "2026-10-20", currency: .usd)]
    let free = world.snapshot(today: "2026-10-14").freeMoney
    XCTAssertEqual(line(free, FreeMoney.Key.scheduled), S.rub(900))
    XCTAssertTrue(free.planWithoutRate.isEmpty)
  }

  func testTheStatusesComeSoonestFirst() {
    var world = counted()
    var late = bill(world, 1_000, next: "2026-10-28")
    late.name = "А"
    var soon = bill(world, 1_000, next: "2026-10-16")
    soon.name = "Я"
    world.book.scheduled = [late, soon]
    XCTAssertEqual(world.snapshot(today: "2026-10-14").scheduled.map(\.payment.name), ["Я", "А"])
  }

  func testSubscriptionsAddUpPerMonthAndPerYear() {
    var world = counted()
    world.book.scheduled = [
      bill(world, 300, next: "2026-10-20", kind: .subscription),
      bill(world, 1_200, next: "2027-03-01", freq: .yearly, kind: .subscription),
    ]
    let planning = world.snapshot(today: "2026-10-14")
    XCTAssertEqual(planning.subscriptionsMonthly, S.rub(400))
    XCTAssertEqual(planning.subscriptionsYearly, S.rub(4_800))
  }

  // MARK: A later day

  func testALaterDayHoldsBackTheBillsOfThatMonthToo() throws {
    var world = counted()
    world.book.scheduled = [bill(world, 3_000, next: "2026-10-20")]
    let planning = world.snapshot(today: "2026-10-14")
    let ledger = Ledger(
      dataset: Dataset(
        categories: world.categories, paymentMethods: world.accounts, planning: world.book),
      calendar: S.calendar)
    let later = planning.freeMoney(until: S.day("2026-11-30"), ledger: ledger)
    XCTAssertEqual(later.until, S.day("2026-11-30"))
    XCTAssertEqual(line(later, FreeMoney.Key.scheduled), S.rub(6_000))
  }

  func testTheWindowNeverStartsBeforeTodayNorEndsAfterAYear() {
    let today = S.day("2028-02-29")
    XCTAssertEqual(FreeMoney.window(today: today, until: S.day("2028-01-01")).end, today)
    XCTAssertEqual(
      FreeMoney.window(today: today, until: S.day("2030-01-01")).end, S.day("2029-02-28"))
    XCTAssertEqual(FreeMoney.window(today: today, until: nil).end, S.day("2028-02-29"))
  }

  // MARK: Goals and events

  private let goalsRoot = CoreKit.Category(kind: .expense, name: "Цели", systemRole: .goals)

  func testGoalMoneyIsNotFreeAndCanBeCountedIn() {
    var world = counted()
    let trip = Goal(name: "Отпуск", targetE4: S.rub(50_000))
    world.goals = [trip]
    world.categories.append(goalsRoot)
    world.entries = [
      S.entry(
        .expense, S.rub(10_000), on: "2026-10-05", category: goalsRoot.id,
        account: world.main.id, goal: trip.id)
    ]
    let free = world.snapshot(today: "2026-10-14").freeMoney
    XCTAssertEqual(free.goalSavings, S.rub(10_000))
    XCTAssertEqual(free.main, S.rub(90_000))
    world.book.settings.reconcileIncludesGoalSavings = false
    let apart = world.snapshot(today: "2026-10-14").freeMoney
    XCTAssertEqual(apart.goalSavings, .zero)
  }

  func testAnEventsBudgetIsHeldBackLessWhatWasSpent() {
    var world = counted()
    let trip = Event(
      name: "Поездка", startDate: S.day("2026-10-10"), endDate: S.day("2026-10-20"),
      budgetE4: S.rub(20_000))
    world.events = [trip]
    world.entries = [
      S.entry(
        .expense, S.rub(5_000), on: "2026-10-11", category: food.id, account: world.main.id,
        event: trip.id)
    ]
    let free = world.snapshot(today: "2026-10-14").freeMoney
    XCTAssertEqual(line(free, FreeMoney.Key.events), S.rub(15_000))
    XCTAssertEqual(free.grey, S.rub(80_000))
    world.book.settings.reserveEventBudgets = false
    XCTAssertEqual(
      line(world.snapshot(today: "2026-10-14").freeMoney, FreeMoney.Key.events), .zero)
  }

  func testAnEventThatIsOverHoldsNothingBack() {
    var world = counted()
    world.events = [
      Event(
        name: "Прошло", startDate: S.day("2026-10-01"), endDate: S.day("2026-10-05"),
        budgetE4: S.rub(20_000))
    ]
    XCTAssertEqual(
      line(world.snapshot(today: "2026-10-14").freeMoney, FreeMoney.Key.events), .zero)
  }

  // MARK: Tax and cushion

  func testTheTaxOfSelfEmploymentIsNotTheOwnersMoney() {
    var world = counted()
    let work = CoreKit.Category(
      kind: .income, name: "Самозанятость", tax: IncomeTax(rate: 4, npd: true))
    world.categories.append(work)
    world.selfEmployment = SelfEmploymentSettings(enabled: true)
    world.entries = [
      S.entry(.income, S.rub(10_000), on: "2026-10-05", category: work.id, account: world.main.id)
    ]
    let planning = world.snapshot(today: "2026-10-14")
    XCTAssertEqual(line(planning.freeMoney, FreeMoney.Key.npdTax), S.rub(400))
    XCTAssertEqual(planning.freeMoney.grey, S.rub(109_600))
    XCTAssertEqual(planning.npd?.accruedUnpaidE4, S.rub(400))
  }

  func testWithSelfEmploymentOffThereIsNoTaxLine() {
    var world = counted()
    let work = CoreKit.Category(
      kind: .income, name: "Самозанятость", tax: IncomeTax(rate: 4, npd: true))
    world.categories.append(work)
    world.entries = [
      S.entry(.income, S.rub(10_000), on: "2026-10-05", category: work.id, account: world.main.id)
    ]
    XCTAssertNil(line(world.snapshot(today: "2026-10-14").freeMoney, FreeMoney.Key.npdTax))
  }

  func testTheCushionCanBeKeptOutOfTheFreeSum() {
    var world = counted()
    let savings = PaymentMethod(name: "Накопительный", kind: .account, cushion: true)
    world.accounts.append(savings)
    world.count(savings.id, 50_000, on: "2026-10-01")
    XCTAssertEqual(world.snapshot(today: "2026-10-14").freeMoney.main, S.rub(150_000))
    world.capital = CapitalSettings(outOfFreeMoney: true)
    let free = world.snapshot(today: "2026-10-14").freeMoney
    XCTAssertEqual(free.cushion, S.rub(50_000))
    XCTAssertEqual(free.main, S.rub(100_000))
    XCTAssertEqual(free.cushionLine?.amount, S.rub(50_000))
  }

  // MARK: The rest of the month

  func testOnTheFirstTheRestOfLastMonthIsOffered() throws {
    let world = counted()
    let offer = try XCTUnwrap(world.snapshot(today: "2026-11-01").monthRest)
    XCTAssertEqual(offer.month, MonthKey(iso: "2026-10"))
    XCTAssertEqual(offer.amountE4, S.rub(100_000))
    XCTAssertNil(offer.target)
  }

  func testTheRestLeavesOutTheBillsAhead() throws {
    var world = counted()
    world.book.scheduled = [bill(world, 3_000, next: "2026-11-05")]
    let offer = try XCTUnwrap(world.snapshot(today: "2026-11-01").monthRest)
    XCTAssertEqual(offer.amountE4, S.rub(97_000))
  }

  func testAfterTheTenthOrOnceDoneThereIsNoRestToOffer() {
    var world = counted()
    XCTAssertNotNil(world.snapshot(today: "2026-11-10").monthRest)
    XCTAssertNil(world.snapshot(today: "2026-11-11").monthRest)
    world.allocation.monthRestDone = MonthKey(iso: "2026-10")
    XCTAssertNil(world.snapshot(today: "2026-11-02").monthRest)
  }

  func testTheRestGoesToTheGoalChosenLastWhileItLives() throws {
    var world = counted()
    let trip = Goal(name: "Отпуск", targetE4: S.rub(50_000))
    world.goals = [trip]
    world.allocation.monthRestTarget = .goal(trip.id)
    XCTAssertEqual(
      try XCTUnwrap(world.snapshot(today: "2026-11-01").monthRest).target,
      .goal(trip.id))
    world.goals = [Goal(id: trip.id, name: "Отпуск", targetE4: S.rub(50_000), archived: true)]
    XCTAssertNil(try XCTUnwrap(world.snapshot(today: "2026-11-01").monthRest).target)
  }

  func testTheRestOfJanuaryIsOfferedForDecember() throws {
    var world = World()
    world.count(world.main.id, 10_000, on: "2026-12-01")
    XCTAssertEqual(
      try XCTUnwrap(world.snapshot(today: "2027-01-01").monthRest).month,
      MonthKey(iso: "2026-12"))
  }

  // MARK: Allocation offers

  func testASalaryInEarningsIsOfferedForAllocation() {
    var world = counted()
    let earnings = CoreKit.Category(kind: .income, name: "Заработок")
    world.categories.append(earnings)
    let salary = S.entry(
      .income, S.rub(80_000), on: "2026-10-10", category: earnings.id, account: world.main.id)
    world.entries = [salary]
    XCTAssertEqual(world.snapshot(today: "2026-10-14").allocationOffers, [salary.id])
    world.allocation.declined = [salary.id]
    XCTAssertTrue(world.snapshot(today: "2026-10-14").allocationOffers.isEmpty)
  }
}
