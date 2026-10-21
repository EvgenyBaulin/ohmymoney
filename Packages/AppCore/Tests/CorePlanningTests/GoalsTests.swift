import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CorePlanning

// MARK: - Fixtures of the savings suites

/// Helpers of the savings suites — goals, system subcategories, expected income, the income
/// estimate, «free to spend» and «can save». A protocol extension rather than free functions:
/// the other planning suites of this target bring helpers of their own, and a member always
/// wins over a global of the same name.
protocol SavingsFixtures {}

extension SavingsFixtures {
  func uid(_ number: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number))!
  }

  func date(_ iso: String) -> DateOnly { DateOnly(iso: iso)! }

  func rub(_ text: String) -> AmountE4 {
    amountLiteral(text)
  }

  func noon(_ iso: String) -> Date {
    CalendarContext.utc.startOfDay(date(iso)).addingTimeInterval(12 * 3600)
  }
}

/// A small book built in code: the system Goals and Loans categories, one goal subcategory,
/// groceries and three income categories.
struct SavingsBook: SavingsFixtures {
  var goalsRoot: UUID { uid(1) }
  /// The subcategory of the goal «Car».
  var carSubcategory: UUID { uid(2) }
  var loansRoot: UUID { uid(3) }
  var groceries: UUID { uid(10) }
  var salary: UUID { uid(31) }
  var help: UUID { uid(32) }
  var projects: UUID { uid(33) }

  var categories: [CoreKit.Category] = []
  var entries: [TransactionEntry] = []
  var goals: [Goal] = []
  private var next = 1000

  init() {
    categories = [
      CoreKit.Category(
        id: goalsRoot, kind: .expense, name: "Goals", quality: .good, systemRole: .goals),
      CoreKit.Category(id: carSubcategory, parentId: goalsRoot, kind: .expense, name: "Car"),
      CoreKit.Category(
        id: loansRoot, kind: .expense, name: "Loans", quality: .neutral, systemRole: .loans),
      CoreKit.Category(id: groceries, kind: .expense, name: "Groceries", quality: .neutral),
      CoreKit.Category(id: salary, kind: .income, name: "Salary"),
      CoreKit.Category(id: help, kind: .income, name: "Help"),
      CoreKit.Category(id: projects, kind: .income, name: "Projects"),
    ]
  }

  /// Adds one operation of one part and returns its id.
  @discardableResult
  mutating func add(
    _ kind: TransactionKind, _ iso: String, _ amount: String, category: UUID?,
    goal: UUID? = nil, currency: CurrencyCode = .rub, rubles: String? = nil,
    periodMonth: String? = nil, person: UUID? = nil, deleted: Bool = false
  ) -> UUID {
    next += 1
    let transactionId = uid(next)
    let when = noon(iso)
    let rubles = rubles.map(rub) ?? rub(amount)
    let part = TransactionPart(
      id: uid(next + 500_000), transactionId: transactionId, categoryId: category,
      quality: kind.hasQuality ? .neutral : nil, qualitySource: kind.hasQuality ? .category : nil,
      amountE4: rub(amount), amountRubE4: rubles, forPersonId: person, goalId: goal)
    entries.append(
      TransactionEntry(
        transaction: Transaction(
          id: transactionId, kind: kind, occurredAt: when, currency: currency,
          amountE4: rub(amount), amountRubE4: rubles,
          periodMonth: periodMonth.flatMap(MonthKey.init(iso:)), createdAt: when,
          updatedAt: when, deletedAt: deleted ? when : nil),
        parts: [part]))
    return transactionId
  }

  mutating func expense(_ iso: String, _ amount: String) {
    add(.expense, iso, amount, category: groceries)
  }

  mutating func contribute(_ iso: String, _ amount: String, goal: UUID?, category: UUID? = nil) {
    add(.expense, iso, amount, category: category ?? carSubcategory, goal: goal)
  }

  mutating func withdraw(_ iso: String, _ amount: String, goal: UUID?, category: UUID? = nil) {
    add(.refund, iso, amount, category: category ?? carSubcategory, goal: goal)
  }

  @discardableResult
  mutating func income(
    _ iso: String, _ amount: String, category: UUID? = nil, for month: String? = nil,
    currency: CurrencyCode = .rub, rubles: String? = nil, person: UUID? = nil
  ) -> UUID {
    add(
      .income, iso, amount, category: category ?? salary, currency: currency, rubles: rubles,
      periodMonth: month, person: person)
  }

  var ledger: Ledger {
    Ledger(
      dataset: Dataset(entries: entries, categories: categories, goals: goals), calendar: .utc)
  }
}

// MARK: - Goals

@Suite("Goals: progress, needed contribution, realism, Contribute and Withdraw")
struct GoalsTests: SavingsFixtures {
  let today = DateOnly(year: 2026, month: 9, day: 19)

  /// The goal «Car» with 55 000 saved: 30 000 in July, 20 000 in August filed only under its
  /// subcategory, 5 000 withdrawn in August, 10 000 in September.
  func carBook(
    target: String = "100000", date: String? = nil, plan: String? = nil
  )
    -> (book: SavingsBook, goal: Goal)
  {
    var book = SavingsBook()
    let goal = Goal(
      id: uid(500), name: "Car", targetE4: rub(target), targetDate: date.map(self.date),
      monthlyPlanE4: plan.map(rub), subcategoryId: book.carSubcategory)
    book.contribute("2026-07-10", "30000", goal: goal.id)
    book.contribute("2026-08-10", "20000", goal: nil)
    book.withdraw("2026-08-20", "5000", goal: goal.id)
    book.contribute("2026-09-05", "10000", goal: goal.id)
    // Not the goal's: another goal's contribution in the same subcategory, and groceries.
    book.contribute("2026-09-06", "7000", goal: uid(501))
    book.expense("2026-09-07", "1000")
    return (book, goal)
  }

  func status(
    _ goal: Goal, _ book: SavingsBook, today: DateOnly? = nil, canSave: AmountE4? = nil
  ) throws -> GoalStatus {
    let statuses = GoalRules.statuses(
      goals: [goal], ledger: book.ledger, today: today ?? self.today, canSaveP50: canSave)
    return try #require(statuses.first)
  }

  /// 30 000 + 20 000 (by the subcategory) − 5 000 + 10 000 = 55 000 of 100 000.
  @Test func progressCountsTheSubcategoryAndTakesTheWithdrawalOff() throws {
    let (book, goal) = carBook()
    let status = try status(goal, book)
    #expect(status.saved == rub("55000"))
    #expect(status.remaining == rub("45000"))
    #expect(status.progressBp == 5_500)
    #expect(status.contributedThisMonth == rub("10000"))
    #expect(status.neededMonthly == nil)
    #expect(status.monthsLeft == nil)
    #expect(status.realism == .noDate)
  }

  /// Before the date: (100 000 − 45 000 saved before September) ÷ 4 months (Sep…Dec) =
  /// 13 750. No plan, so the pace is the average of July and August — the history starts in
  /// July: (30 000 + 15 000) ÷ 2 = 22 500. By 15 December: 55 000 + (22 500 − 10 000 done
  /// this month) + 22 500 × 3 = 135 000 — on track. Completion: 45 000 − 12 500 = 32 500
  /// left after September, ⌈32 500 ÷ 22 500⌉ = 2 months → November.
  @Test func neededMonthlyBeforeTheDate() throws {
    let (book, goal) = carBook(date: "2026-12-15")
    let status = try status(goal, book)
    #expect(status.monthsLeft == 4)
    #expect(status.neededMonthly == rub("13750"))
    #expect(status.pace == rub("22500"))
    #expect(status.paceSource == .history)
    #expect(status.amountByTargetDate == rub("135000"))
    #expect(status.realism == .onTrack)
    #expect(status.projectedCompletion == MonthKey(year: 2026, month: 11))
  }

  /// In the month of the date, before it: one month left, so everything missing before
  /// September is needed now — 55 000.
  @Test func theTargetMonthItselfIsOneMonth() throws {
    let (book, goal) = carBook(date: "2026-09-30")
    let status = try status(goal, book)
    #expect(status.monthsLeft == 1)
    #expect(status.neededMonthly == rub("55000"))
  }

  /// After the date the whole remainder is needed at once, and the goal is overdue.
  @Test func neededMonthlyAfterTheDateIsTheWholeRemainder() throws {
    let (book, goal) = carBook(date: "2026-12-15")
    let status = try status(goal, book, today: date("2027-01-10"))
    #expect(status.monthsLeft == 0)
    #expect(status.neededMonthly == rub("45000"))
    #expect(status.contributedThisMonth == .zero)
    #expect(status.realism == .overdue)
    #expect(status.amountByTargetDate == nil)
  }

  /// With a plan of 10 000 and the date at the end of October: 55 000 + 0 left of
  /// September's plan + 10 000 for October = 65 000 < 100 000 — behind plan. Needed:
  /// (100 000 − 45 000) ÷ 2 = 27 500, which «can save» 30 000 covers and 20 000 does not.
  @Test func behindPlanWithAMonthlyPlan() throws {
    let (book, goal) = carBook(date: "2026-10-31", plan: "10000")
    let status = try status(goal, book, canSave: rub("30000"))
    #expect(status.pace == rub("10000"))
    #expect(status.paceSource == .plan)
    #expect(status.amountByTargetDate == rub("65000"))
    #expect(status.realism == .behindPlan)
    #expect(status.neededMonthly == rub("27500"))
    #expect(status.coveredByCanSave == true)
    #expect(try self.status(goal, book, canSave: rub("20000")).coveredByCanSave == false)
    // Without «can save» there is nothing to compare with.
    #expect(try self.status(goal, book).coveredByCanSave == nil)
  }

  /// Without a date the plan still gives the month it will be done: September's plan is
  /// done, then ⌈45 000 ÷ 10 000⌉ = 5 months → February 2027.
  @Test func withoutADateThePlanGivesTheCompletionMonth() throws {
    let (book, goal) = carBook(plan: "10000")
    let status = try status(goal, book)
    #expect(status.realism == .noDate)
    #expect(status.projectedCompletion == MonthKey(year: 2027, month: 2))
    #expect(status.amountByTargetDate == nil)
    #expect(status.coveredByCanSave == nil)
  }

  @Test func aReachedGoalNeedsNothing() throws {
    let (book, goal) = carBook(target: "50000", date: "2026-12-15")
    let status = try status(goal, book)
    #expect(status.realism == .reached)
    #expect(status.remaining == .zero)
    #expect(status.progressBp == 10_000)
    #expect(status.neededMonthly == .zero)
    #expect(status.projectedCompletion == nil)
  }

  /// A date, no plan, and nothing put into the goal in the complete months (the history
  /// starts in August, with groceries only): the goal may be new, and there is not enough
  /// data to judge it.
  @Test func withoutAPaceTheRealismIsNotEnoughData() throws {
    var book = SavingsBook()
    let goal = Goal(
      id: uid(500), name: "Car", targetE4: rub("10000"), targetDate: date("2026-12-31"),
      subcategoryId: book.carSubcategory)
    book.expense("2026-08-05", "100")
    book.contribute("2026-09-02", "1000", goal: goal.id)
    let status = try status(goal, book)
    #expect(status.pace == nil)
    #expect(status.realism == .notEnoughData)
    // 10 000 ÷ 4: September's own 1 000 is a part of September's share, not a discount on it.
    #expect(status.neededMonthly == rub("2500"))
    #expect(status.projectedCompletion == nil)
  }

  /// A withdrawal this month raises what the months left have to bring: 45 000 before
  /// September − 5 000 taken out now leaves 60 000 over 4 months = 15 000.
  @Test func aWithdrawalThisMonthRaisesTheNeededContribution() throws {
    let car = carBook(date: "2026-12-15")
    var book = car.book
    let goal = car.goal
    book.entries.removeAll { $0.transaction.occurredAt == noon("2026-09-05") }
    book.withdraw("2026-09-08", "5000", goal: goal.id)
    let status = try status(goal, book)
    #expect(status.contributedThisMonth == rub("-5000"))
    #expect(status.neededMonthly == rub("15000"))
  }

  @Test func archivedGoalsAreLeftOutAndTheOrderIsKept() {
    let (book, car) = carBook()
    let flat = Goal(id: uid(502), name: "Flat", targetE4: rub("1000000"))
    let old = Goal(id: uid(503), name: "Old", targetE4: rub("1"), archived: true)
    let statuses = GoalRules.statuses(
      goals: [flat, old, car], ledger: book.ledger, today: today)
    #expect(statuses.map(\.id) == [flat.id, car.id])
    #expect(statuses[0].saved == .zero)
    #expect(statuses[0].progressBp == 0)
  }

  /// 29 999.9999 of 30 000 is 9 999 bp, not 100 %.
  @Test func progressIsRoundedDown() {
    #expect(GoalRules.progressBasisPoints(saved: rub("29999.9999"), target: rub("30000")) == 9_999)
    #expect(GoalRules.progressBasisPoints(saved: rub("-10"), target: rub("30000")) == 0)
    #expect(GoalRules.progressBasisPoints(saved: rub("40000"), target: rub("30000")) == 10_000)
  }

  // MARK: - Contribute and Withdraw

  @Test func contributionDraftIsAGoodExpenseOfTheGoal() throws {
    let book = SavingsBook()
    let goal = Goal(id: uid(500), name: "Car", targetE4: rub("100000"))
    let draft = GoalRules.contributionDraft(
      goal: goal, subcategoryId: book.carSubcategory, amount: rub("5000"),
      occurredAt: noon("2026-09-19"), paymentMethodId: uid(700))
    #expect(draft.kind == .expense)
    #expect(draft.currency == .rub)
    #expect(draft.amount == rub("5000"))
    #expect(draft.paymentMethodId == uid(700))
    #expect(draft.isBalanced)
    let part = try #require(draft.parts.first)
    #expect(draft.parts.count == 1)
    #expect(part.categoryId == book.carSubcategory)
    #expect(part.categorySource == .system)
    #expect(part.goalId == goal.id)
    #expect(part.quality == .good)
    #expect(part.qualitySource == .system)
    #expect(part.forWhom == .me)
    #expect(!part.reimbursable)
    // The panel may not offer another rating.
    #expect(
      !QualityResolver.canRateByHand(
        goalId: part.goalId, categoryId: part.categoryId,
        categories: CategoryTree(book.categories)))
  }

  /// The month a plan counts from: it starts in the month a plan appears — on a new goal or
  /// on one that had none, or a plan of zero —, goes when the plan goes, and stays through a
  /// change of the amount, of the name or of anything else.
  @Test func withPlanStartSetsClearsAndKeeps() {
    let september = MonthKey(year: 2026, month: 9)
    let june = MonthKey(year: 2026, month: 6)
    let planned = Goal(
      id: uid(500), name: "Car", targetE4: rub("100000"), monthlyPlanE4: rub("10000"))
    let unplanned = Goal(id: uid(500), name: "Car", targetE4: rub("100000"))
    // A plan appears.
    #expect(
      GoalRules.withPlanStart(planned, previous: nil, today: today).planStartMonth == september)
    #expect(
      GoalRules.withPlanStart(planned, previous: unplanned, today: today).planStartMonth
        == september)
    var zero = unplanned
    zero.monthlyPlanE4 = .zero
    #expect(
      GoalRules.withPlanStart(planned, previous: zero, today: today).planStartMonth == september)
    // No plan, or a plan of zero: no month.
    #expect(GoalRules.withPlanStart(unplanned, previous: nil, today: today).planStartMonth == nil)
    #expect(GoalRules.withPlanStart(zero, previous: nil, today: today).planStartMonth == nil)
    // A plan taken away takes its month along.
    var started = planned
    started.planStartMonth = june
    var removed = started
    removed.monthlyPlanE4 = nil
    #expect(GoalRules.withPlanStart(removed, previous: started, today: today).planStartMonth == nil)
    var zeroed = started
    zeroed.monthlyPlanE4 = .zero
    #expect(GoalRules.withPlanStart(zeroed, previous: started, today: today).planStartMonth == nil)
    // A new amount, a new name: the month stays, the one stored before the edit.
    var larger = started
    larger.monthlyPlanE4 = rub("15000")
    larger.name = "New car"
    let kept = GoalRules.withPlanStart(larger, previous: started, today: today)
    #expect(kept.planStartMonth == june)
    #expect(kept.monthlyPlanE4 == rub("15000"))
    #expect(kept.name == "New car")
    larger.planStartMonth = nil
    #expect(GoalRules.withPlanStart(larger, previous: started, today: today).planStartMonth == june)
    // A plan an older file kept without a month keeps counting from the first contribution.
    var older = planned
    older.planStartMonth = nil
    #expect(
      GoalRules.withPlanStart(larger, previous: older, today: today).planStartMonth == nil)
  }

  /// «Withdraw» is a refund with the same part; the amount loses its sign. Both drafts,
  /// saved, give 5 000 − 3 000 = 2 000 saved.
  @Test func withdrawalDraftIsARefundThatTakesTheProgressBack() throws {
    var book = SavingsBook()
    let goal = Goal(
      id: uid(500), name: "Car", targetE4: rub("100000"), subcategoryId: book.carSubcategory)
    let contribution = GoalRules.contributionDraft(
      goal: goal, subcategoryId: nil, amount: rub("5000"), occurredAt: noon("2026-09-10"))
    let withdrawal = GoalRules.withdrawalDraft(
      goal: goal, subcategoryId: nil, amount: rub("-3000"), occurredAt: noon("2026-09-12"))
    #expect(withdrawal.kind == .refund)
    #expect(withdrawal.amount == rub("3000"))
    let part = try #require(withdrawal.parts.first)
    // Without a subcategory passed, the goal's own is used.
    #expect(part.categoryId == book.carSubcategory)
    #expect(part.goalId == goal.id)
    #expect(part.quality == .good)
    #expect(part.qualitySource == .system)

    book.entries += [
      try contribution.materialize(id: uid(900)), try withdrawal.materialize(id: uid(901)),
    ]
    let status = try status(goal, book)
    #expect(status.saved == rub("2000"))
    #expect(status.contributedThisMonth == rub("2000"))
    // My expenses move the same way: +5 000 − 3 000.
    #expect(book.ledger.expenses(in: DayRange(date("2026-09-01"), today)) == rub("2000"))
  }
}
