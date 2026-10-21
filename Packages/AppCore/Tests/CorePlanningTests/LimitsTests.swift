import CoreAccounting
import CoreAnalytics
import CoreKit
import CorePlanning
import Foundation
import Testing

/// A small book of operations built in code for the limit rules: Food with two
/// subcategories, Taxi, and the system categories a limit must never see.
private struct LimitsBook {
  let food = LimitsBook.id(1)
  let cafe = LimitsBook.id(2)
  let groceries = LimitsBook.id(3)
  let taxi = LimitsBook.id(4)
  let goals = LimitsBook.id(5)
  let vacation = LimitsBook.id(6)
  let unknown = LimitsBook.id(7)
  let salary = LimitsBook.id(8)
  let loans = LimitsBook.id(9)
  let carLoan = LimitsBook.id(50)

  var entries: [TransactionEntry] = []
  private var next = 1_000

  var categories: [CoreKit.Category] {
    [
      CoreKit.Category(id: food, kind: .expense, name: "Food", quality: .neutral),
      CoreKit.Category(id: cafe, parentId: food, kind: .expense, name: "Cafe"),
      CoreKit.Category(id: groceries, parentId: food, kind: .expense, name: "Groceries"),
      CoreKit.Category(id: taxi, kind: .expense, name: "Taxi", quality: .bad),
      CoreKit.Category(
        id: goals, kind: .expense, name: "Goals", quality: .good, systemRole: .goals),
      CoreKit.Category(id: vacation, parentId: goals, kind: .expense, name: "Vacation"),
      CoreKit.Category(
        id: unknown, kind: .expense, name: "Unknown", quality: .neutral, systemRole: .unknown),
      CoreKit.Category(id: salary, kind: .income, name: "Salary"),
      CoreKit.Category(
        id: loans, kind: .expense, name: "Loans", quality: .neutral, systemRole: .loans),
    ]
  }

  var tree: CategoryTree { CategoryTree(categories) }

  var ledger: Ledger {
    let debt = Debt(
      id: carLoan, direction: .iOwe, type: .loan, name: "Car", paymentsAreExpenses: true)
    return Ledger(
      dataset: Dataset(entries: entries, categories: categories, debts: [debt]), calendar: .utc)
  }

  static func id(_ number: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number)) ?? UUID()
  }

  static func money(_ text: String) -> AmountE4 {
    amountLiteral(text)
  }

  static func day(_ iso: String) -> DateOnly {
    DateOnly(iso: iso) ?? DateOnly(year: 1970, month: 1, day: 1)
  }

  /// One operation of one part, at noon UTC of the day.
  mutating func add(
    _ iso: String, _ amount: String, kind: TransactionKind = .expense, category: UUID?,
    quality: Quality = .neutral, forWhom: ForWhom = .me, reimbursable: Bool = false,
    status: ReimbursementStatus? = nil, goal: UUID? = nil, debt: UUID? = nil,
    externalId: String? = nil
  ) {
    next += 1
    let transactionId = Self.id(next)
    let when = CalendarContext.utc.startOfDay(Self.day(iso)).addingTimeInterval(12 * 3600)
    let part = TransactionPart(
      id: Self.id(next + 500_000), transactionId: transactionId, categoryId: category,
      quality: kind.hasQuality ? quality : nil, qualitySource: kind.hasQuality ? .manual : nil,
      amountE4: Self.money(amount), forWhom: forWhom, reimbursable: reimbursable,
      reimbursementStatus: status, goalId: goal)
    entries.append(
      TransactionEntry(
        transaction: Transaction(
          id: transactionId, kind: kind, occurredAt: when, amountE4: Self.money(amount),
          debtId: debt, externalId: externalId, createdAt: when, updatedAt: when),
        parts: [part]))
  }
}

@Suite("Limits: spent, pace, forecast, status, rollover, validation")
struct LimitsTests {
  private func money(_ text: String) -> AmountE4 { LimitsBook.money(text) }
  private func day(_ iso: String) -> DateOnly { LimitsBook.day(iso) }

  private func line(
    _ budget: Budget, _ book: LimitsBook, today: String, planned: String = "0"
  ) -> LimitLine {
    LimitRules.line(budget: budget, ledger: book.ledger, today: day(today), planned: money(planned))
  }

  // MARK: - What is spent

  /// Food 500 directly, Cafe 1 000 and Groceries 2 000 under it: the parent's limit sees
  /// 3 500. Taxi is another category.
  @Test func aLimitOnAParentCoversItsSubcategories() {
    var book = LimitsBook()
    book.add("2026-09-03", "1000", category: book.cafe)
    book.add("2026-09-05", "2000", category: book.groceries)
    book.add("2026-09-10", "500", category: book.food)
    book.add("2026-09-04", "700", category: book.taxi)
    let limit = Budget(scope: .category, categoryId: book.food, amountE4: money("10000"))
    #expect(line(limit, book, today: "2026-09-19").spent == money("3500"))
  }

  /// A limit on Cafe sees Cafe only — not its parent, not its sibling.
  @Test func aLimitOnASubcategoryCoversOnlyItself() {
    var book = LimitsBook()
    book.add("2026-09-03", "1000", category: book.cafe)
    book.add("2026-09-05", "2000", category: book.groceries)
    book.add("2026-09-10", "500", category: book.food)
    let limit = Budget(scope: .category, categoryId: book.cafe, amountE4: money("10000"))
    #expect(line(limit, book, today: "2026-09-19").spent == money("1000"))
  }

  /// Only the month of today counts: August is another month's limit.
  @Test func onlyTheMonthOfTodayIsSpent() {
    var book = LimitsBook()
    book.add("2026-08-31", "4000", category: book.cafe)
    book.add("2026-09-01", "100", category: book.cafe)
    book.add("2026-10-01", "900", category: book.cafe)
    let limit = Budget(scope: .category, categoryId: book.food, amountE4: money("10000"))
    let result = line(limit, book, today: "2026-09-19")
    #expect(result.month == MonthKey(year: 2026, month: 9))
    #expect(result.spent == money("100"))
  }

  /// 3 000 at the cafe, 1 000 of it taken back: 2 000 spent.
  @Test func refundsLowerTheSpending() {
    var book = LimitsBook()
    book.add("2026-09-03", "3000", category: book.cafe)
    book.add("2026-09-06", "1000", kind: .refund, category: book.cafe)
    let limit = Budget(scope: .category, categoryId: book.food, amountE4: money("10000"))
    let result = line(limit, book, today: "2026-09-19")
    #expect(result.spent == money("2000"))
    #expect(result.remaining == money("8000"))
  }

  /// 800 paid for a friend and still expected back is not mine; 300 written off is.
  @Test func partsForOthersCountOnlyOnceWrittenOff() {
    var book = LimitsBook()
    book.add("2026-09-03", "1500", category: book.cafe)
    book.add(
      "2026-09-04", "800", category: book.cafe, forWhom: .friends, reimbursable: true,
      status: .expected)
    book.add(
      "2026-09-05", "300", category: book.cafe, forWhom: .friends, reimbursable: true,
      status: .writtenOff)
    let food = Budget(scope: .category, categoryId: book.food, amountE4: money("10000"))
    #expect(line(food, book, today: "2026-09-19").spent == money("1800"))
    let friends = Budget(scope: .forWhom, forWhom: .friends, amountE4: money("1000"))
    #expect(line(friends, book, today: "2026-09-19").spent == money("300"))
  }

  /// Money put into a goal — in the Goals category or tied to a goal elsewhere — and money in
  /// a system category never reach a limit, even one on everything «for me».
  @Test func goalContributionsAndSystemCategoriesStayOut() {
    var book = LimitsBook()
    book.add("2026-09-02", "1000", category: book.cafe)
    book.add("2026-09-03", "5000", category: book.vacation, quality: .good)
    book.add("2026-09-04", "2000", category: book.cafe, goal: LimitsBook.id(77))
    book.add("2026-09-05", "400", category: book.unknown)
    let me = Budget(scope: .forWhom, forWhom: .me, amountE4: money("10000"))
    #expect(line(me, book, today: "2026-09-19").spent == money("1000"))
    let food = Budget(scope: .category, categoryId: book.food, amountE4: money("10000"))
    #expect(line(food, book, today: "2026-09-19").spent == money("1000"))
  }

  /// Bad: Taxi 700 and a bad cafe visit 300. Friends: 600. Me: everything else I spent on
  /// myself, 700 + 300 + 2 000.
  @Test func badSpendingAndForWhomLimits() {
    var book = LimitsBook()
    book.add("2026-09-02", "700", category: book.taxi, quality: .bad)
    book.add("2026-09-03", "300", category: book.cafe, quality: .bad)
    book.add("2026-09-04", "2000", category: book.groceries, quality: .neutral)
    book.add("2026-09-05", "600", category: book.cafe, quality: .good, forWhom: .friends)
    let today = "2026-09-19"
    let bad = Budget(scope: .badTotal, amountE4: money("3000"))
    #expect(line(bad, book, today: today).spent == money("1000"))
    let friends = Budget(scope: .forWhom, forWhom: .friends, amountE4: money("3000"))
    #expect(line(friends, book, today: today).spent == money("600"))
    let me = Budget(scope: .forWhom, forWhom: .me, amountE4: money("5000"))
    #expect(line(me, book, today: today).spent == money("3000"))
  }

  // MARK: - Pace

  /// 6 000 of 10 000 on the 15th of 30 days: 60 % spent against 50 % gone — a pace of 120 %.
  @Test func paceIsTheSpentShareAgainstTheElapsedShare() {
    var book = LimitsBook()
    book.add("2026-09-03", "6000", category: book.cafe)
    let limit = Budget(scope: .category, categoryId: book.food, amountE4: money("10000"))
    let result = line(limit, book, today: "2026-09-15")
    #expect(result.spentShareBp == 6_000)
    #expect(result.elapsedShareBp == 5_000)
    #expect(result.paceBp == 12_000)
  }

  /// 3 333 of 10 000 on the 7th: shares 3 333 bp and 7/30 = 2 333.33… bp. The pace comes from
  /// the exact values, 3 333 × 30 / 7 = 14 284.29 → 14 284, not from the rounded shares
  /// (3 333 / 2 333 = 14 286).
  @Test func paceComesFromTheExactShares() {
    var book = LimitsBook()
    book.add("2026-09-03", "3333", category: book.cafe)
    let limit = Budget(scope: .category, categoryId: book.food, amountE4: money("10000"))
    let result = line(limit, book, today: "2026-09-07")
    #expect(result.spentShareBp == 3_333)
    #expect(result.elapsedShareBp == 2_333)
    #expect(result.paceBp == 14_284)
  }

  /// With nothing available there is no share and no pace, and any spending is over.
  @Test func noShareWithoutAvailableMoney() {
    var book = LimitsBook()
    book.add("2026-09-03", "100", category: book.cafe)
    let limit = Budget(scope: .category, categoryId: book.food, amountE4: .zero)
    let result = line(limit, book, today: "2026-09-15")
    #expect(result.spentShareBp == nil)
    #expect(result.paceBp == nil)
    #expect(result.elapsedShareBp == 5_000)
    #expect(result.status == .over)
  }

  // MARK: - Forecast

  /// Today is 19 September; Taxi has spending since 1 June, so the window is the full 90 days
  /// [21 June, 18 September]. Variable spending in it: 4 000 + 4 000 + 1 000 = 9 000, 100 a
  /// day; the scheduled payment (900, 600) and the loan payment (450) are planned, not
  /// variable, and the 500 of 1 June is before the window. Spent in September: 600 + 1 000
  /// + 200 (today) = 1 800. Forecast: 1 800 + planned 300 + 100 × 11 days left = 3 200 —
  /// above the 3 000 limit while 1 800 is only 60 % of it: a warning.
  @Test func forecastTakesTheMeanOfTheNinetyDayWindow() {
    var book = LimitsBook()
    let payment = LimitsBook.id(60)
    book.add("2026-06-01", "500", category: book.taxi)
    book.add("2026-07-01", "4000", category: book.taxi)
    book.add("2026-08-01", "4000", category: book.taxi)
    book.add(
      "2026-08-15", "900", category: book.taxi,
      externalId: OperationLink.scheduled(paymentId: payment, due: day("2026-08-15")).externalId)
    book.add("2026-08-20", "450", category: book.taxi, debt: book.carLoan)
    book.add(
      "2026-09-05", "600", category: book.taxi,
      externalId: OperationLink.scheduled(paymentId: payment, due: day("2026-09-05")).externalId)
    book.add("2026-09-10", "1000", category: book.taxi)
    book.add("2026-09-19", "200", category: book.taxi)
    let limit = Budget(scope: .category, categoryId: book.taxi, amountE4: money("3000"))

    let rate = LimitRules.meanDaily(of: limit, ledger: book.ledger, today: day("2026-09-19"))
    #expect(rate.amount == 100)
    #expect(!rate.lowData)

    let result = line(limit, book, today: "2026-09-19", planned: "300")
    #expect(result.spent == money("1800"))
    #expect(result.planned == money("300"))
    #expect(result.forecast == money("3200"))
    #expect(!result.lowData)
    #expect(result.status == .warning)
  }

  /// Cafe has spending only since 2 September: the window [2, 18 September] is 17 days, too
  /// short, so the rate is this month's: 1 000 ÷ 19 days × 11 days left = 578.947368… →
  /// 578.9474. The Groceries purchase of June is another limit's history and does not
  /// lengthen the window.
  @Test func forecastFallsBackToThisMonthWithShortHistory() {
    var book = LimitsBook()
    book.add("2026-06-01", "500", category: book.groceries)
    book.add("2026-09-02", "1000", category: book.cafe)
    let limit = Budget(scope: .category, categoryId: book.cafe, amountE4: money("2000"))
    let result = line(limit, book, today: "2026-09-19")
    #expect(result.lowData)
    #expect(result.forecast == money("1578.9474"))
    #expect(result.status == .ok)
  }

  // MARK: - Status

  /// On the last day nothing is left to forecast, so the status rests on what is spent:
  /// below 90 % ok, from 90 % through the limit itself a warning, above the limit over.
  @Test func statusesOkWarningOver() {
    let cases: [(String, LimitStatus)] = [
      ("899.9999", .ok), ("900", .warning), ("1000", .warning), ("1000.0001", .over),
    ]
    for (spent, status) in cases {
      var book = LimitsBook()
      book.add("2026-09-30", spent, category: book.cafe)
      let limit = Budget(scope: .category, categoryId: book.food, amountE4: money("1000"))
      let result = line(limit, book, today: "2026-09-30")
      #expect(result.forecast == money(spent))
      #expect(result.status == status, "spent \(spent)")
    }
  }

  // MARK: - Rollover

  /// A limit of 10 000 from June, with rollover. June spends 7 000 and hands on 3 000.
  /// July has 13 000 and spends 15 000: overspent, it hands on nothing (not −2 000). August
  /// spends 4 000 of 10 000 and hands on 6 000. May is before the start and counts for
  /// nothing. September: 16 000 available, 2 000 spent, 14 000 left.
  @Test func rolloverChainsLeftoversAndNeverCarriesOverspending() {
    var book = LimitsBook()
    book.add("2026-05-10", "1000", category: book.cafe)
    book.add("2026-06-10", "7000", category: book.cafe)
    book.add("2026-07-10", "15000", category: book.cafe)
    book.add("2026-08-10", "4000", category: book.cafe)
    book.add("2026-09-10", "2000", category: book.cafe)
    let limit = Budget(
      scope: .category, categoryId: book.food, amountE4: money("10000"), rollover: true,
      startMonth: MonthKey(year: 2026, month: 6))
    let ledger = book.ledger
    func carry(_ month: Int) -> AmountE4 {
      LimitRules.carry(of: limit, into: MonthKey(year: 2026, month: month), ledger: ledger)
    }
    #expect(carry(5) == .zero)
    #expect(carry(6) == .zero)
    #expect(carry(7) == money("3000"))
    #expect(carry(8) == .zero)
    #expect(carry(9) == money("6000"))

    let result = line(limit, book, today: "2026-09-19")
    #expect(result.carry == money("6000"))
    #expect(result.available == money("16000"))
    #expect(result.spent == money("2000"))
    #expect(result.remaining == money("14000"))
  }

  /// No rollover without the flag or without a start month.
  @Test func rolloverNeedsTheFlagAndAStartMonth() {
    var book = LimitsBook()
    book.add("2026-08-10", "1000", category: book.cafe)
    let june = MonthKey(year: 2026, month: 6)
    let off = Budget(
      scope: .category, categoryId: book.food, amountE4: money("10000"), startMonth: june)
    let noStart = Budget(
      scope: .category, categoryId: book.food, amountE4: money("10000"), rollover: true)
    #expect(line(off, book, today: "2026-09-19").carry == .zero)
    #expect(line(noStart, book, today: "2026-09-19").carry == .zero)
  }

  /// An edit restarts the rollover in its month. June to August spent all
  /// of 5 000, so nothing was left; raised to 20 000 in September, the limit must not find
  /// (20 000 − 5 000) × 3 = 45 000 left over in months lived under 5 000. Lowered again, the
  /// carry starts again too: October receives what September leaves under the new amount.
  @Test func anEditOfTheAmountStartsTheRolloverAgainInItsMonth() {
    var book = LimitsBook()
    for month in ["06", "07", "08"] { book.add("2026-\(month)-10", "5000", category: book.cafe) }
    book.add("2026-09-10", "4000", category: book.cafe)
    let june = MonthKey(year: 2026, month: 6)
    let september = MonthKey(year: 2026, month: 9)
    let limit = Budget(
      scope: .category, categoryId: book.food, amountE4: money("5000"), rollover: true,
      startMonth: june)
    #expect(LimitRules.carry(of: limit, into: september, ledger: book.ledger) == .zero)

    var raised = limit
    raised.amountE4 = money("20000")
    let saved = LimitRules.saving(raised, over: limit, in: september)
    #expect(saved.startMonth == september)
    let result = line(saved, book, today: "2026-09-19")
    #expect(result.carry == .zero)
    #expect(result.available == money("20000"))
    #expect(
      LimitRules.carry(of: saved, into: september.next, ledger: book.ledger) == money("16000"))

    var lowered = saved
    lowered.amountE4 = money("5000")
    let again = LimitRules.saving(lowered, over: raised, in: september)
    #expect(
      LimitRules.carry(of: again, into: september.next, ledger: book.ledger) == money("1000"))
  }

  /// What starts the rollover again: a new limit, a new amount or target, rollover switched
  /// on. A save that changes nothing, or switches rollover off, keeps the start; a limit made
  /// before limits had a start gets one.
  @Test func onlyAChangeOfWhatIsCarriedStartsTheRolloverAgain() {
    let book = LimitsBook()
    let june = MonthKey(year: 2026, month: 6)
    let september = MonthKey(year: 2026, month: 9)
    let limit = Budget(
      scope: .category, categoryId: book.food, amountE4: money("5000"), rollover: true,
      startMonth: june)
    func start(_ edit: (inout Budget) -> Void, over stored: Budget? = nil) -> MonthKey? {
      var edited = stored ?? limit
      edit(&edited)
      return LimitRules.saving(edited, over: stored ?? limit, in: september).startMonth
    }
    #expect(start { _ in } == june)
    #expect(start { $0.rollover = false } == june)
    #expect(start { $0.categoryId = book.cafe } == september)
    #expect(
      start {
        $0.scope = .badTotal
        $0.categoryId = nil
      } == september)
    var off = limit
    off.rollover = false
    #expect(start({ $0.rollover = true }, over: off) == september)
    var old = limit
    old.startMonth = nil
    #expect(start({ _ in }, over: old) == september)
    #expect(LimitRules.saving(limit, over: nil, in: september).startMonth == september)
  }

  // MARK: - The lines of the book

  /// Lines follow the book. A limit on Food takes what is due under Food and under its
  /// subcategories; a limit on Cafe only Cafe's; bad spending has no plan.
  @Test func linesTakeThePlannedPaymentsOfTheirScope() {
    let book = LimitsBook()
    let limits = [
      Budget(scope: .category, categoryId: book.food, amountE4: money("5000")),
      Budget(scope: .category, categoryId: book.cafe, amountE4: money("5000")),
      Budget(scope: .badTotal, amountE4: money("5000")),
      Budget(scope: .forWhom, forWhom: .friends, amountE4: money("5000")),
    ]
    let lines = LimitRules.lines(
      book: PlanningBook(budgets: limits), ledger: book.ledger, today: day("2026-09-19"),
      plannedByCategory: [
        book.cafe: money("200"), book.food: money("100"), book.taxi: money("50"),
      ],
      plannedByForWhom: [.friends: money("70"), .me: money("1")])
    #expect(lines.map(\.budget.id) == limits.map(\.id))
    #expect(lines.map(\.planned) == [money("300"), money("200"), .zero, money("70")])
    #expect(lines.map(\.forecast) == [money("300"), money("200"), .zero, money("70")])
  }

  // MARK: - Validation

  @Test func systemCategoriesTakeNoLimit() {
    let book = LimitsBook()
    for category in [book.goals, book.vacation, book.unknown, book.loans] {
      let limit = Budget(scope: .category, categoryId: category, amountE4: money("1000"))
      #expect(LimitRules.validate(limit, tree: book.tree, existing: []) == .systemCategory)
    }
  }

  @Test func incomeCategoriesAndMissingTargetsAreRefused() {
    let book = LimitsBook()
    let tree = book.tree
    func issue(_ budget: Budget) -> BudgetIssue? {
      LimitRules.validate(budget, tree: tree, existing: [])
    }
    #expect(
      issue(Budget(scope: .category, categoryId: book.salary, amountE4: money("1")))
        == .incomeCategory)
    #expect(issue(Budget(scope: .category, amountE4: money("1"))) == .missingTarget)
    #expect(
      issue(Budget(scope: .category, categoryId: LimitsBook.id(999), amountE4: money("1")))
        == .missingTarget)
    #expect(issue(Budget(scope: .forWhom, amountE4: money("1"))) == .missingTarget)
    #expect(
      issue(Budget(scope: .category, categoryId: book.cafe, amountE4: .zero)) == .nonPositive)
    #expect(issue(Budget(scope: .badTotal, amountE4: money("-5"))) == .nonPositive)
    #expect(issue(Budget(scope: .category, categoryId: book.cafe, amountE4: money("1"))) == nil)
  }

  /// One limit per category, per «for whom» value and on bad spending. A limit on a parent
  /// and one on its subcategory live side by side, and editing a limit is not a duplicate
  /// of itself.
  @Test func duplicatesAreRefused() {
    let book = LimitsBook()
    let tree = book.tree
    let food = Budget(scope: .category, categoryId: book.food, amountE4: money("1000"))
    let bad = Budget(scope: .badTotal, amountE4: money("1000"))
    let friends = Budget(scope: .forWhom, forWhom: .friends, amountE4: money("1000"))
    let existing = [food, bad, friends]
    func issue(_ budget: Budget) -> BudgetIssue? {
      LimitRules.validate(budget, tree: tree, existing: existing)
    }
    #expect(
      issue(Budget(scope: .category, categoryId: book.food, amountE4: money("5")))
        == .duplicate)
    #expect(issue(Budget(scope: .badTotal, amountE4: money("5"))) == .duplicate)
    #expect(issue(Budget(scope: .forWhom, forWhom: .friends, amountE4: money("5"))) == .duplicate)
    #expect(issue(Budget(scope: .forWhom, forWhom: .family, amountE4: money("5"))) == nil)
    #expect(issue(Budget(scope: .category, categoryId: book.cafe, amountE4: money("5"))) == nil)
    var edited = food
    edited.amountE4 = money("2000")
    #expect(issue(edited) == nil)
  }
}
