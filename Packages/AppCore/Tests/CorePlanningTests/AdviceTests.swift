import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CorePlanning

// MARK: - Fixtures of the advice suite

/// One part of an operation of the advice fixtures.
struct AdvicePart {
  var amount: String
  var category: UUID?
  var quality: Quality? = .neutral
  var forWhom: ForWhom = .me
  var reimbursable = false
  var status: ReimbursementStatus? = nil
  var debtor: UUID? = nil
  var goal: UUID? = nil
  var event: UUID? = nil
}

/// A book built in code for the suggestions: system Goals and Loans, a goal subcategory, a few
/// spending categories (Cafe under Food; Snacks rated bad), salary and cashback, three people
/// and three payment methods.
struct AdviceData: SavingsFixtures {
  var goalsRoot: UUID { uid(1) }
  var goalSubcategory: UUID { uid(2) }
  var loansRoot: UUID { uid(3) }
  var food: UUID { uid(10) }
  var cafe: UUID { uid(11) }
  var home: UUID { uid(12) }
  var taxi: UUID { uid(13) }
  var books: UUID { uid(14) }
  var fun: UUID { uid(15) }
  var snacks: UUID { uid(16) }
  var salary: UUID { uid(31) }
  var cashbackCategory: UUID { uid(34) }
  var anna: UUID { uid(60) }
  var boris: UUID { uid(61) }
  var vera: UUID { uid(62) }
  var cardA: UUID { uid(70) }
  var cardB: UUID { uid(71) }
  var cash: UUID { uid(72) }
  var car: UUID { uid(500) }

  var categories: [CoreKit.Category] = []
  var entries: [TransactionEntry] = []
  var goals: [Goal] = []
  var debts: [Debt] = []
  var events: [Event] = []
  var links: [ReimbursementLink] = []
  var book = PlanningBook()
  var cashbackOn = false
  private var next = 2_000

  init() {
    categories = [
      CoreKit.Category(
        id: goalsRoot, kind: .expense, name: "Goals", quality: .good, systemRole: .goals),
      CoreKit.Category(id: goalSubcategory, parentId: goalsRoot, kind: .expense, name: "Car"),
      CoreKit.Category(
        id: loansRoot, kind: .expense, name: "Loans", quality: .neutral, systemRole: .loans),
      CoreKit.Category(id: food, kind: .expense, name: "Food", quality: .neutral),
      CoreKit.Category(id: cafe, parentId: food, kind: .expense, name: "Cafe"),
      CoreKit.Category(id: home, kind: .expense, name: "Home", quality: .neutral),
      CoreKit.Category(id: taxi, kind: .expense, name: "Taxi", quality: .neutral),
      CoreKit.Category(id: books, kind: .expense, name: "Books", quality: .neutral),
      CoreKit.Category(id: fun, kind: .expense, name: "Fun", quality: .neutral),
      CoreKit.Category(id: snacks, kind: .expense, name: "Snacks", quality: .bad),
      CoreKit.Category(id: salary, kind: .income, name: "Salary"),
      CoreKit.Category(id: cashbackCategory, kind: .income, name: "Cashback"),
    ]
  }

  /// Adds one operation and returns its id; the operation's amount is the sum of its parts.
  @discardableResult
  mutating func add(
    _ kind: TransactionKind, _ iso: String, _ parts: [AdvicePart], method: UUID? = nil,
    externalId: String? = nil
  ) -> UUID {
    next += 1
    let transactionId = uid(next)
    let when = noon(iso)
    let total = AmountE4.sum(parts.map { rub($0.amount) })
    let stored = parts.enumerated().map { index, part in
      TransactionPart(
        id: uid(next * 10 + index + 1_000_000), transactionId: transactionId,
        categoryId: part.category, quality: kind.hasQuality ? part.quality : nil,
        qualitySource: kind.hasQuality && part.quality != nil ? .manual : nil,
        amountE4: rub(part.amount), amountRubE4: rub(part.amount), forWhom: part.forWhom,
        reimbursable: part.reimbursable, debtorPersonId: part.debtor,
        reimbursementStatus: part.status, eventId: part.event, goalId: part.goal)
    }
    entries.append(
      TransactionEntry(
        transaction: Transaction(
          id: transactionId, kind: kind, occurredAt: when, amountE4: total, amountRubE4: total,
          paymentMethodId: method, externalId: externalId, createdAt: when, updatedAt: when),
        parts: stored))
    return transactionId
  }

  mutating func spend(
    _ iso: String, _ amount: String, _ category: UUID, quality: Quality = .neutral,
    forWhom: ForWhom = .me, method: UUID? = nil, event: UUID? = nil
  ) {
    add(
      .expense, iso,
      [
        AdvicePart(
          amount: amount, category: category, quality: quality, forWhom: forWhom, event: event)
      ],
      method: method)
  }

  mutating func refund(
    _ iso: String, _ amount: String, _ category: UUID, quality: Quality = .neutral
  ) {
    add(.refund, iso, [AdvicePart(amount: amount, category: category, quality: quality)])
  }

  /// A reimbursement of `amount` for the first part of the last operation added, linked to
  /// that part — the way the reimbursement sheet closes it.
  mutating func giveBack(_ amount: String, on iso: String) {
    guard let part = entries.last?.parts.first?.id else { return }
    let reimbursement = add(.reimbursement, iso, [AdvicePart(amount: amount, quality: nil)])
    links.append(
      ReimbursementLink(reimbursementTxId: reimbursement, partId: part, amountE4: rub(amount)))
  }

  mutating func contribute(_ iso: String, _ amount: String) {
    add(
      .expense, iso,
      [AdvicePart(amount: amount, category: goalSubcategory, quality: .good, goal: car)])
  }

  mutating func income(_ iso: String, _ amount: String, category: UUID? = nil, method: UUID? = nil)
  {
    add(.income, iso, [AdvicePart(amount: amount, category: category ?? salary)], method: method)
  }

  var ledger: Ledger {
    Ledger(
      dataset: Dataset(
        entries: entries, links: links, categories: categories,
        people: [
          Person(id: anna, name: "Anna"), Person(id: boris, name: "Boris"),
          Person(id: vera, name: "Vera"),
        ],
        events: events,
        paymentMethods: [
          PaymentMethod(id: cardA, name: "Card A"), PaymentMethod(id: cardB, name: "Card B"),
          PaymentMethod(id: cash, name: "Cash", kind: .cash),
        ],
        debts: debts, goals: goals, planning: book,
        settings: AnalyticsSettings(cashbackCategoryId: cashbackOn ? cashbackCategory : nil)),
      calendar: .utc)
  }

  func context(_ today: DateOnly) -> AdviceContext { AdviceContext(ledger: ledger, today: today) }
}

// MARK: - The suite

@Suite("Advice: every rule with its formula, and «not enough data» where there is too little")
struct AdviceTests: SavingsFixtures {
  let today = DateOnly(year: 2026, month: 9, day: 19)

  func term(
    _ key: String, _ op: AdviceOp, _ value: AdviceValue, _ subject: AdviceSubject? = nil
  ) -> AdviceTerm {
    AdviceTerm(key: key, op: op, value: value, subject: subject)
  }

  func term(_ key: String, _ value: AdviceValue, _ subject: AdviceSubject? = nil) -> AdviceTerm {
    AdviceTerm(key: key, value: value, subject: subject)
  }

  func money(_ text: String) -> AdviceValue { .money(rub(text)) }

  /// Six complete months, March through August 2026, and nothing in September:
  ///
  /// * Food: 10 040, 12 000, —, 10 500 + Cafe 500, 9 010, 13 552 − a refund of 500;
  /// * Home 20 000 in June, July and August; Taxi 3 000 a month and 5 000 in August, with a
  ///   limit; Books 1 000 a month and 1 900 in August; Fun 5 000 and 6 000 in July and
  ///   August;
  /// * Snacks, rated bad: 4 000, 5 000, 3 000, 6 000, 5 500, 4 500 on the 15th;
  /// * 5 000 into the goal every month — never a category to limit.
  func history() -> AdviceData {
    var data = AdviceData()
    data.spend("2026-03-10", "10040", data.food)
    data.spend("2026-04-10", "12000", data.food)
    data.spend("2026-06-10", "10500", data.food)
    data.spend("2026-06-12", "500", data.cafe)
    data.spend("2026-07-10", "9010", data.food)
    data.spend("2026-08-10", "13552", data.food)
    data.refund("2026-08-12", "500", data.food)
    for month in ["06", "07", "08"] { data.spend("2026-\(month)-05", "20000", data.home) }
    for month in ["03", "04", "05", "06", "07"] {
      data.spend("2026-\(month)-05", "3000", data.taxi)
      data.spend("2026-\(month)-06", "1000", data.books)
    }
    data.spend("2026-08-05", "5000", data.taxi)
    data.spend("2026-08-06", "1900", data.books)
    data.spend("2026-07-07", "5000", data.fun)
    data.spend("2026-08-07", "6000", data.fun)
    for (month, amount) in [
      ("03", "4000"), ("04", "5000"), ("05", "3000"), ("06", "6000"), ("07", "5500"),
      ("08", "4500"),
    ] {
      data.spend("2026-\(month)-15", amount, data.snacks, quality: .bad)
      data.contribute("2026-\(month)-20", "5000")
    }
    data.book.budgets = [Budget(scope: .category, categoryId: data.taxi, amountE4: rub("4000"))]
    return data
  }

  // MARK: Can save

  /// The formula of `CanSave`: income 100 000 − spent 30 000 − planned 15 000 − the rest of
  /// the month 20 000 = 35 000; the range 24 000…43 000, 10 000 saved, 25 000 more.
  @Test func canSaveShowsItsFormula() {
    let canSave = CanSave(
      CanSaveInputs(
        income: MonthIncomeEstimate(
          month: today.monthKey, received: rub("60000"), expectedRemaining: rub("40000"),
          median3: nil, monthsInMedian: 0, value: rub("100000"), source: .expectations,
          lowData: false),
        spentWithoutGoals: rub("30000"), plannedStillDue: rub("15000"),
        remainder: MonthForecast.Remainder(
          p10: rub("12000"), middle: rub("20000"), p90: rub("31000"), lowData: false,
          computedFor: today, daysLeft: 11, windowDays: 90),
        alreadySaved: rub("10000")))
    let advice = AdviceRules.canSave(canSave)
    #expect(advice.id == "canSave")
    #expect(advice.status == .ready)
    #expect(
      advice.terms == [
        term("advice.canSave.income", .plus, money("100000")),
        term("advice.canSave.spent", .minus, money("30000")),
        term("advice.canSave.planned", .minus, money("15000")),
        term("advice.canSave.variable", .minus, money("20000")),
      ])
    #expect(advice.result == term("advice.term.canSave", .equals, money("35000")))
    #expect(
      advice.notes == [
        term("advice.term.canSaveRange", .range(rub("24000"), rub("43000"))),
        term("advice.term.alreadySaved", money("10000")),
        term("advice.term.canSaveMore", money("25000")),
      ])
  }

  @Test func canSaveWithoutIncomeHasNotEnoughData() {
    let canSave = CanSave(
      CanSaveInputs(
        income: MonthIncomeEstimate(
          month: today.monthKey, received: .zero, expectedRemaining: .zero, median3: nil,
          monthsInMedian: 0, value: nil, source: .receivedOnly, lowData: true),
        spentWithoutGoals: .zero, plannedStillDue: .zero,
        remainder: MonthForecast.Remainder(
          p10: .zero, middle: .zero, p90: .zero, lowData: true, computedFor: today,
          daysLeft: 11, windowDays: 0),
        alreadySaved: .zero))
    let advice = AdviceRules.canSave(canSave)
    #expect(advice.status == .notEnoughData(reasonKey: "advice.reason.noIncome"))
    #expect(advice.terms.isEmpty)
    #expect(advice.result == nil)
  }

  // MARK: Savings rate

  /// August: 12 000 into the goal of 80 000 income = 1 500 bp. September: 10 000 in, 2 000
  /// out of 100 000 = 800 bp, 200 bp short of the 10 % target.
  @Test func savingsRateAgainstTheTarget() {
    var data = AdviceData()
    data.income("2026-08-05", "80000")
    data.contribute("2026-08-06", "12000")
    data.income("2026-09-05", "100000")
    data.contribute("2026-09-06", "10000")
    data.add(
      .refund, "2026-09-10",
      [AdvicePart(amount: "2000", category: data.goalSubcategory, quality: .good, goal: data.car)])
    let ledger = data.ledger
    let september = SavingsRate.month(ledger: ledger, month: today.monthKey, targetBp: 1_000)
    let august = SavingsRate.month(
      ledger: ledger, month: today.monthKey.previous, targetBp: 1_000)
    let advice = AdviceRules.savingsRate(thisMonth: september, lastMonth: august)
    #expect(
      advice.terms == [
        term("advice.term.goalsNetThisMonth", money("8000")),
        term("advice.term.incomeThisMonth", money("100000")),
      ])
    #expect(advice.result == term("advice.term.savingsRate", .equals, .basisPoints(800)))
    #expect(
      advice.notes == [
        term("advice.term.savingsTarget", .basisPoints(1_000)),
        term("advice.term.shortOfTarget", .basisPoints(200)),
        term("advice.term.savingsRateLastMonth", .basisPoints(1_500)),
      ])
  }

  /// No September income yet: August stands in, 500 bp above the target. Neither month has
  /// income: not enough data.
  @Test func savingsRateFallsBackToLastMonthThenToNotEnoughData() {
    var data = AdviceData()
    data.income("2026-08-05", "80000")
    data.contribute("2026-08-06", "12000")
    data.contribute("2026-09-06", "10000")
    let ledger = data.ledger
    let advice = AdviceRules.savingsRate(
      thisMonth: SavingsRate.month(ledger: ledger, month: today.monthKey, targetBp: 1_000),
      lastMonth: SavingsRate.month(
        ledger: ledger, month: today.monthKey.previous, targetBp: 1_000))
    #expect(
      advice.terms == [
        term("advice.term.goalsNetLastMonth", money("12000")),
        term("advice.term.incomeLastMonth", money("80000")),
      ])
    #expect(
      advice.result == term("advice.term.savingsRateLastMonth", .equals, .basisPoints(1_500)))
    #expect(
      advice.notes == [
        term("advice.term.savingsTarget", .basisPoints(1_000)),
        term("advice.term.aboveTarget", .basisPoints(500)),
      ])

    let empty = AdviceData().ledger
    let none = AdviceRules.savingsRate(
      thisMonth: SavingsRate.month(ledger: empty, month: today.monthKey, targetBp: 1_000),
      lastMonth: SavingsRate.month(ledger: empty, month: today.monthKey.previous, targetBp: 1_000))
    #expect(none.status == .notEnoughData(reasonKey: "advice.reason.noIncomeForRate"))
  }

  // MARK: Goals

  func goalStatus(
    _ name: String, id: Int, remaining: String, date: String? = nil, monthsLeft: Int? = nil,
    needed: String? = nil, pace: String? = nil, projected: MonthKey? = nil,
    byDate: String? = nil
  ) -> GoalStatus {
    GoalStatus(
      goal: Goal(id: uid(id), name: name, targetE4: rub("100000"), targetDate: date.map(self.date)),
      saved: rub("100000") - rub(remaining), remaining: rub(remaining), progressBp: 0,
      contributedThisMonth: .zero, neededMonthly: needed.map(rub), monthsLeft: monthsLeft,
      pace: pace.map(rub), paceSource: pace == nil ? nil : .plan, realism: .behindPlan,
      projectedCompletion: projected, amountByTargetDate: byDate.map(rub),
      coveredByCanSave: nil)
  }

  /// «Car» needs 13 750 a month for 4 months; at 10 000 it is reached in February and has
  /// 85 000 by its date. «Trip» has no date: at 5 000 it is reached in December. «Laptop» has
  /// neither a date nor a pace; «Phone» is reached. All goals need 13 750 a month: «can save»
  /// of 12 000 is 1 750 short, of 20 000 leaves 6 250.
  @Test func goalsNeededPaceAndWhetherCanSaveCoversThem() {
    let statuses = [
      goalStatus(
        "Car", id: 500, remaining: "45000", date: "2026-12-31", monthsLeft: 4, needed: "13750",
        pace: "10000", projected: MonthKey(year: 2027, month: 2), byDate: "85000"),
      goalStatus(
        "Trip", id: 501, remaining: "20000", pace: "5000",
        projected: MonthKey(year: 2026, month: 12)),
      goalStatus("Laptop", id: 502, remaining: "30000"),
      goalStatus("Phone", id: 503, remaining: "0"),
    ]
    let items = AdviceRules.goals(statuses, canSaveP50: rub("12000"))
    #expect(items.map(\.id) == ["goal:\(ids(500))", "goal:\(ids(501))", "goal:\(ids(502))"])

    let car = items[0]
    #expect(car.subject == .goal("Car"))
    #expect(
      car.terms == [
        term("advice.term.goalRemaining", money("45000")),
        term("advice.term.goalTargetDate", .date(date("2026-12-31"))),
        term("advice.term.goalMonthsLeft", .months(4)),
        term("advice.term.goalPace", money("10000")),
      ])
    #expect(car.result == term("advice.term.goalNeededMonthly", .equals, money("13750")))
    #expect(
      car.notes == [
        term("advice.term.goalProjected", .month(MonthKey(year: 2027, month: 2))),
        term("advice.term.goalByTargetDate", money("85000")),
        term("advice.term.allGoalsNeed", money("13750")),
        term("advice.term.canSaveShort", money("1750")),
      ])

    let trip = items[1]
    #expect(
      trip.result
        == term("advice.term.goalProjected", .equals, .month(MonthKey(year: 2026, month: 12))))
    #expect(
      trip.notes == [
        term("advice.term.allGoalsNeed", money("13750")),
        term("advice.term.canSaveShort", money("1750")),
      ])

    #expect(items[2].status == .notEnoughData(reasonKey: "advice.reason.goalNoDateNoPace"))
    #expect(items[2].subject == .goal("Laptop"))

    let covered = AdviceRules.goals(statuses, canSaveP50: rub("20000"))
    #expect(covered[0].notes.last == term("advice.term.canSaveCovers", money("6250")))
    let unknown = AdviceRules.goals(statuses, canSaveP50: nil)
    #expect(unknown[1].notes.isEmpty)
  }

  func ids(_ number: Int) -> String { uid(number).uuidString.lowercased() }

  /// A goal in dollars: every amount of its status is dollars, and rubles for one dollar today.
  func dollarGoal(
    _ name: String, id: Int, remaining: String, date: String? = nil, monthsLeft: Int? = nil,
    needed: String? = nil, pace: String? = nil, rate: Decimal? = 95
  ) -> GoalStatus {
    GoalStatus(
      goal: Goal(
        id: uid(id), name: name, targetE4: rub("2000"), targetDate: date.map(self.date),
        currency: .usd),
      saved: rub("2000") - rub(remaining), remaining: rub(remaining), progressBp: 0,
      contributedThisMonth: .zero, neededMonthly: needed.map(rub), monthsLeft: monthsLeft,
      pace: pace.map(rub), paceSource: pace == nil ? nil : .plan, realism: .behindPlan,
      projectedCompletion: nil, amountByTargetDate: nil, coveredByCanSave: nil,
      rubPerUnit: rate)
  }

  func dollars(_ text: String) -> AdviceValue { .moneyIn(.usd, rub(text)) }

  /// A goal of 1 000 $ still to save needs 250 $ a month — 23 750 ₽ at today's 95 ₽ — and a
  /// ruble goal 10 000 ₽: together 33 750 ₽, so «can save» of 20 000 ₽ is 13 750 ₽ short, not
  /// «10 250, 9 750 left». The dollar goal shows its own amounts in dollars. A goal in a
  /// currency without a rate today leaves «all goals need» unsaid rather than guessed.
  @Test func goalsInAnotherCurrencyAreAddedInRubles() {
    let statuses = [
      dollarGoal(
        "Trip", id: 510, remaining: "1000", date: "2026-12-31", monthsLeft: 4, needed: "250",
        pace: "150"),
      goalStatus(
        "Car", id: 511, remaining: "40000", date: "2026-12-31", monthsLeft: 4, needed: "10000"),
    ]
    let items = AdviceRules.goals(statuses, canSaveP50: rub("20000"))
    let trip = items[0]
    #expect(
      trip.terms == [
        term("advice.term.goalRemaining", dollars("1000")),
        term("advice.term.goalTargetDate", .date(date("2026-12-31"))),
        term("advice.term.goalMonthsLeft", .months(4)),
        term("advice.term.goalPace", dollars("150")),
      ])
    #expect(trip.result == term("advice.term.goalNeededMonthly", .equals, dollars("250")))
    #expect(
      trip.notes == [
        term("advice.term.allGoalsNeed", money("33750")),
        term("advice.term.canSaveShort", money("13750")),
      ])
    #expect(items[1].notes == trip.notes)

    var noRate = statuses
    noRate[0] = dollarGoal(
      "Trip", id: 510, remaining: "1000", date: "2026-12-31", monthsLeft: 4, needed: "250",
      rate: nil)
    let unknown = AdviceRules.goals(noRate, canSaveP50: rub("20000"))
    #expect(unknown.allSatisfy { $0.notes.isEmpty })
  }

  /// The bad month is 2 000 ₽ on average; at today's 100 ₽ a cut of 10, 25 or 50 % frees 2, 5
  /// or 10 $ for a dollar goal with 100 $ to go at 10 $ a month: 9, 7 or 5 months instead of
  /// 10 — one, three and five sooner, not nine each as rubles added to dollars would say. A
  /// dollar goal without a rate today is left out.
  @Test func badCutScenarioFreesRublesIntoTheGoalsCurrency() {
    let trip = dollarGoal("Trip", id: 510, remaining: "100", pace: "10", rate: 100)
    let items = AdviceRules.badCutScenarios(badBook().context(today), goals: [trip])
    #expect(items.map(\.id) == ["badCutScenario:\(ids(510))"])
    #expect(
      items.first?.terms == [
        term("advice.term.badMonthlyAverage", money("2000")),
        term("advice.term.goalRemaining", dollars("100")),
        term("advice.term.goalPace", dollars("10")),
        term("advice.term.monthsAtPace", .months(10)),
        term("advice.term.sooner10", .months(1)),
        term("advice.term.sooner25", .months(3)),
        term("advice.term.sooner50", .months(5)),
      ])
    #expect(
      items.first?.notes == [
        term("advice.term.cut10", money("200")),
        term("advice.term.cut25", money("500")),
        term("advice.term.cut50", money("1000")),
      ])

    let noRate = dollarGoal("Trip", id: 510, remaining: "100", pace: "10", rate: nil)
    #expect(AdviceRules.badCutScenarios(badBook().context(today), goals: [noRate]).isEmpty)
  }

  // MARK: Limits

  /// Food: [10 040, 12 000, 0, 11 000, 9 010, 13 052] → median (10 040 + 11 000) ÷ 2 =
  /// 10 520, up to 10 600. Home: [0, 0, 0, 20 000, 20 000, 20 000] → 10 000. Snacks: median
  /// 4 750 → 4 800. Books (median 1 000) is the fourth and left out; Taxi has a limit; Fun
  /// spent in two months only; the goal is a system category.
  @Test func limitSuggestionsTakeTheMedianOfSixMonths() {
    let data = history()
    let items = AdviceRules.limitSuggestions(data.context(today), budgets: data.book.budgets)
    #expect(
      items.map(\.subject) == [.category(data.food), .category(data.home), .category(data.snacks)])
    #expect(items.map(\.result?.value) == [money("10600"), money("10000"), money("4800")])
    #expect(items[0].id == "limitSuggestion:\(data.food.uuidString.lowercased())")
    #expect(
      items[0].terms == [
        term("advice.term.monthsCounted", .count(6)),
        term("advice.term.monthsWithSpending", .count(5)),
        term("advice.term.monthlyRange", .range(.zero, rub("13052"))),
        term("advice.term.monthlyMedian", money("10520")),
      ])
    #expect(items[1].terms[1] == term("advice.term.monthsWithSpending", .count(3)))
    #expect(items[0].result?.key == "advice.term.suggestedLimit")
  }

  /// July and August only: two complete months are too few.
  @Test func limitSuggestionsNeedThreeMonths() {
    var data = AdviceData()
    data.spend("2026-07-10", "5000", data.food)
    data.spend("2026-08-10", "5000", data.food)
    let items = AdviceRules.limitSuggestions(data.context(today), budgets: [])
    #expect(
      items == [
        Advice(
          id: "limitSuggestion", kind: .limitSuggestion,
          status: .notEnoughData(reasonKey: "advice.reason.fewerThanThreeMonths"))
      ])
  }

  /// August against the median of March–July: Food 13 052 against 10 040 is exactly 1.3 ×
  /// and 3 012 more (+30 %); Taxi 5 000 against 3 000 is 2 000 more (+66.67 %). Books grew
  /// 1.9 × but only by 900; Snacks fell; Home and Fun had no usual spending.
  @Test func growingCategoriesAgainstTheUsualMonth() {
    let data = history()
    let items = AdviceRules.growingCategories(data.context(today))
    #expect(items.map(\.subject) == [.category(data.food), .category(data.taxi)])
    let food = items[0]
    #expect(
      food.terms == [
        term("advice.term.lastMonthSpent", .plus, money("13052")),
        term("advice.term.usualMedian", .minus, money("10040")),
      ])
    #expect(food.result == term("advice.term.aboveUsual", .equals, money("3012")))
    #expect(
      food.notes == [
        term("advice.term.lastCompleteMonth", .month(MonthKey(year: 2026, month: 8))),
        term("advice.term.growth", .basisPoints(3_000)),
        term("advice.term.monthsCounted", .count(5)),
      ])
    #expect(items[1].result == term("advice.term.aboveUsual", .equals, money("2000")))
    #expect(items[1].notes[1] == term("advice.term.growth", .basisPoints(6_667)))
  }

  /// June, July and August: three complete months, one short of four.
  @Test func growingCategoriesNeedFourMonths() {
    var data = AdviceData()
    for month in ["06", "07", "08"] { data.spend("2026-\(month)-10", "5000", data.food) }
    let items = AdviceRules.growingCategories(data.context(today))
    #expect(items.map(\.status) == [.notEnoughData(reasonKey: "advice.reason.fewerThanFourMonths")])
  }

  // MARK: Bad spending

  /// Bad: 600 on 1 June, 900 on 15 July, 1 500 on 10 and 3 000 on 25 August; in September
  /// 2 000 on the 5th, a refund of 200 on the 6th, and 1 000 on the 25th, still ahead.
  /// Groceries, rated neutral, and the goal never count.
  func badBook() -> AdviceData {
    var data = AdviceData()
    data.spend("2026-06-01", "600", data.snacks, quality: .bad)
    data.spend("2026-07-15", "900", data.snacks, quality: .bad)
    data.spend("2026-08-10", "1500", data.snacks, quality: .bad)
    data.spend("2026-08-25", "3000", data.snacks, quality: .bad)
    data.spend("2026-09-05", "2000", data.snacks, quality: .bad)
    data.refund("2026-09-06", "200", data.snacks, quality: .bad)
    data.spend("2026-09-25", "1000", data.snacks, quality: .bad)
    data.spend("2026-09-07", "5000", data.food)
    data.contribute("2026-09-08", "3000")
    return data
  }

  /// This month to date 2 000 − 200 = 1 800; 1–19 August 1 500; the same days of June, July
  /// and August 600, 900, 1 500 — 1 000 on average; whole months 600, 900, 4 500 — 2 000.
  /// 1 800 − 1 500 = 300: +20 % on last month, +80 % on the average.
  @Test func badComparisonTakesTheSameSpan() {
    let items = AdviceRules.badComparison(badBook().context(today))
    #expect(items.count == 1)
    let advice = items[0]
    #expect(
      advice.terms == [
        term("advice.term.badThisMonth", .plus, money("1800")),
        term("advice.term.badSameSpanLastMonth", .minus, money("1500")),
      ])
    #expect(advice.result == term("advice.term.badVsLastMonth", .equals, money("300")))
    #expect(
      advice.notes == [
        term("advice.term.badSameSpanAverage", money("1000")),
        term("advice.term.changeVsLastMonth", .basisPoints(2_000)),
        term("advice.term.changeVsAverage", .basisPoints(8_000)),
        term("advice.term.badMonthlyAverage", money("2000")),
        term("advice.term.monthsCounted", .count(3)),
      ])
  }

  @Test func badComparisonNeedsACompleteMonth() {
    var data = AdviceData()
    data.spend("2026-09-05", "2000", data.snacks, quality: .bad)
    #expect(
      AdviceRules.badComparison(data.context(today)).map(\.status) == [
        .notEnoughData(reasonKey: "advice.reason.noCompleteMonth")
      ])
    var clean = AdviceData()
    clean.spend("2026-08-05", "2000", clean.food)
    #expect(AdviceRules.badComparison(clean.context(today)).isEmpty)
  }

  /// The average bad month is 2 000. «Car»: 40 000 left at 4 000 a month is 10 months.
  /// Cutting 10 % frees 200: ⌈40 000 ÷ 4 200⌉ = 10, no sooner; 25 % frees 500: ⌈8.9⌉ = 9, one
  /// month sooner; 50 % frees 1 000: 8 months, two sooner. «Trip» has no pace, «Phone» is
  /// reached: neither is listed.
  @Test func badCutScenarioBringsGoalsForward() {
    let goals = [
      goalStatus("Car", id: 500, remaining: "40000", pace: "4000"),
      goalStatus("Trip", id: 501, remaining: "10000"),
      goalStatus("Phone", id: 502, remaining: "0", pace: "1000"),
    ]
    let items = AdviceRules.badCutScenarios(badBook().context(today), goals: goals)
    #expect(items.map(\.id) == ["badCutScenario:\(ids(500))"])
    #expect(items[0].subject == .goal("Car"))
    #expect(
      items[0].terms == [
        term("advice.term.badMonthlyAverage", money("2000")),
        term("advice.term.goalRemaining", money("40000")),
        term("advice.term.goalPace", money("4000")),
        term("advice.term.monthsAtPace", .months(10)),
        term("advice.term.sooner10", .months(0)),
        term("advice.term.sooner25", .months(1)),
        term("advice.term.sooner50", .months(2)),
      ])
    #expect(
      items[0].notes == [
        term("advice.term.cut10", money("200")),
        term("advice.term.cut25", money("500")),
        term("advice.term.cut50", money("1000")),
      ])
  }

  @Test func badCutScenarioWithoutDataOrWithoutPace() {
    let trip = goalStatus("Trip", id: 501, remaining: "10000")
    let paceless = AdviceRules.badCutScenarios(badBook().context(today), goals: [trip])
    #expect(paceless.map(\.status) == [.notEnoughData(reasonKey: "advice.reason.goalNoPace")])

    var september = AdviceData()
    september.spend("2026-09-05", "2000", september.snacks, quality: .bad)
    let fresh = AdviceRules.badCutScenarios(september.context(today), goals: [trip])
    #expect(fresh.map(\.status) == [.notEnoughData(reasonKey: "advice.reason.noCompleteMonth")])
    // No goal to bring forward, or every goal reached: nothing to say, even on a fresh
    // history.
    #expect(AdviceRules.badCutScenarios(september.context(today), goals: []).isEmpty)
    let reached = goalStatus("Bike", id: 502, remaining: "0")
    #expect(AdviceRules.badCutScenarios(september.context(today), goals: [reached]).isEmpty)

    var clean = AdviceData()
    clean.spend("2026-08-05", "2000", clean.food)
    let car = goalStatus("Car", id: 500, remaining: "40000", pace: "4000")
    #expect(AdviceRules.badCutScenarios(clean.context(today), goals: [car]).isEmpty)
  }

  /// Snacks over March–August: median (4 500 + 5 000) ÷ 2 = 4 750; 90 % of it is 4 275,
  /// which rounds to 4 300.
  @Test func badLimitSuggestionIsNinetyPercentOfTheMedian() {
    let data = history()
    let items = AdviceRules.badLimitSuggestion(data.context(today), budgets: data.book.budgets)
    #expect(items.count == 1)
    #expect(
      items[0].terms == [
        term("advice.term.monthsCounted", .count(6)),
        term("advice.term.monthlyMedian", money("4750")),
        term("advice.term.limitFactor", .basisPoints(9_000)),
      ])
    #expect(items[0].result == term("advice.term.suggestedLimit", .equals, money("4300")))

    let limited = AdviceRules.badLimitSuggestion(
      data.context(today),
      budgets: data.book.budgets + [Budget(scope: .badTotal, amountE4: rub("5000"))])
    #expect(limited.isEmpty)

    var two = AdviceData()
    two.spend("2026-07-15", "900", two.snacks, quality: .bad)
    two.spend("2026-08-10", "1500", two.snacks, quality: .bad)
    let short = AdviceRules.badLimitSuggestion(two.context(today), budgets: [])
    #expect(
      short.map(\.status) == [.notEnoughData(reasonKey: "advice.reason.fewerThanThreeMonths")])
  }

  // MARK: Debts

  /// Debts I owe: A — 120 000 ₽ at 12 %, 10 000 a month; B — 1 000 $ at 6 %, 100 $ a month
  /// (90 ₽ per dollar); C — 100 000 ₽ at 24 %, 1 900 a month, less than the 2 000 of the first
  /// month's interest; D — the same at 1 500; E — 5 000 ₽ to a friend, no payment set.
  func debtBook() -> AdviceData {
    var data = AdviceData()
    func debt(
      _ number: Int, _ name: String, rate: String?, payment: String?, day: Int?,
      currency: CurrencyCode = .rub, balance: String, type: DebtType = .loan
    ) {
      let id = uid(number)
      data.debts.append(
        Debt(
          id: id, direction: .iOwe, type: type, name: name, currency: currency,
          interestRate: rate.flatMap { Decimal(string: $0) }, monthlyPaymentE4: payment.map(rub),
          paymentDay: day, paymentsAreExpenses: false))
      data.book.debtEntries.append(
        DebtEntry(debtId: id, date: date("2026-09-01"), amountE4: rub(balance), kind: .borrowed))
    }
    debt(700, "A", rate: "12", payment: "10000", day: 5, balance: "120000")
    debt(701, "B", rate: "6", payment: "100", day: 10, currency: .usd, balance: "1000")
    debt(702, "C", rate: "24", payment: "1900", day: 15, balance: "100000")
    debt(703, "D", rate: "24", payment: "1500", day: 20, balance: "100000")
    debt(704, "E", rate: nil, payment: nil, day: nil, balance: "5000", type: .personal)
    return data
  }

  let usdRate: [CurrencyCode: Decimal] = [.usd: 90]

  func overview(_ data: AdviceData) -> DebtsOverview {
    let ledger = data.ledger
    return DebtsOverview.build(
      ledger: ledger, book: ledger.dataset.planning, today: today, rubPerUnit: usdRate)
  }

  /// Payments of the month 10 000 + 100 $ × 90 + 1 900 + 1 500 = 22 400 against the median
  /// 100 000 of «Заработок» of the six months before: 22.4 %. Balances 120 000 + 90 000 +
  /// 100 000 + 100 000 + 5 000 = 415 000; E has no payment.
  @Test func debtLoadIsPaymentsOverIncome() {
    var data = debtBook()
    for month in ["2026-03", "2026-04", "2026-05", "2026-06", "2026-07", "2026-08"] {
      data.add(.income, "\(month)-10", [AdvicePart(amount: "100000", category: data.salary)])
    }
    let salary = data.salary
    let items = AdviceRules.debtLoad(
      data.context(today), debts: overview(data), accounts: .empty, rubPerUnit: usdRate,
      earnings: { $0 == salary })
    #expect(items.count == 1)
    #expect(
      items[0].terms == [
        term("advice.term.debtTotal", money("415000")),
        term("advice.term.debtMonthlyPayments", money("22400")),
        term("advice.term.debtIncome", money("100000")),
      ])
    #expect(items[0].result == term("advice.term.debtLoad", .equals, .basisPoints(2_240)))
    #expect(items[0].notes == [term("advice.term.debtsWithoutPayment", .count(1))])
  }

  @Test func debtLoadWithoutIncomeOrWithoutDebts() {
    let data = debtBook()
    let items = AdviceRules.debtLoad(
      data.context(today), debts: overview(data), accounts: .empty, rubPerUnit: usdRate,
      earnings: { _ in true })
    #expect(items.map(\.status) == [.notEnoughData(reasonKey: "advice.reason.noIncome")])
    let none = AdviceData()
    #expect(
      AdviceRules.debtLoad(
        none.context(today), debts: overview(none), accounts: .empty, rubPerUnit: [:]
      ).isEmpty)
  }

  /// A: 13 months at 10 000, 12 at 11 000 — one sooner, 8 477.9133 − 7 711.4704 = 766.4429
  /// of interest saved (monthly interest rounded to stored units). B: 10 $ extra, 11 months
  /// against 10, 2.4218 $ saved. C: 190 → 200 extra makes 2 100 beat the interest — closed
  /// in 154 months, never without it. D: 150 → 200 extra, 1 700 never closes it. E has no
  /// rate.
  ///
  /// The advice follows the order of «Я должен» (nearest due first), which the debts screen
  /// owns: each debt is looked up by its own subject.
  @Test func debtPayoffWithTenPercentExtra() throws {
    let items = AdviceRules.debtPayoffs(overview(debtBook()))
    #expect(
      Set(items.compactMap(\.subject)) == [.debt("A"), .debt("B"), .debt("C"), .debt("D")])
    #expect(items.count == 4)
    func item(_ name: String) throws -> Advice {
      try #require(items.first { $0.subject == .debt(name) }, "no advice for \(name)")
    }
    let a = try item("A")
    #expect(a.id == "debtPayoff:\(ids(700))")
    #expect(
      a.terms == [
        term("advice.term.debtBalance", money("120000")),
        term("advice.term.debtRate", .basisPoints(1_200)),
        term("advice.term.debtPayment", money("10000")),
        term("advice.term.debtExtra", .plus, money("1000")),
      ])
    #expect(a.result == term("advice.term.monthsSooner", .equals, .months(1)))
    #expect(
      a.notes == [
        term("advice.term.monthsWithoutExtra", .months(13)),
        term("advice.term.monthsWithExtra", .months(12)),
        term("advice.term.interestSaved", money("766.4429")),
      ])
    let b = try item("B")
    try #require(b.terms.count == 4 && b.notes.count == 3)
    #expect(b.terms[0] == term("advice.term.debtBalance", .moneyIn(.usd, rub("1000"))))
    #expect(b.terms[3] == term("advice.term.debtExtra", .plus, .moneyIn(.usd, rub("10"))))
    #expect(b.notes[2] == term("advice.term.interestSaved", .moneyIn(.usd, rub("2.4218"))))
    let c = try item("C")
    try #require(c.terms.count == 4)
    #expect(c.terms[3] == term("advice.term.debtExtra", .plus, money("200")))
    #expect(c.result == term("advice.term.closesOnlyWithExtra", .equals, .months(154)))
    #expect(c.notes.isEmpty)
    #expect(try item("D").result == term("advice.term.notClosedWithin", .months(600)))
  }

  /// 10 %, to 100 ₽ and never below it; to whole units of another currency, at least one.
  @Test func payoffExtraRounding() {
    #expect(AdviceRules.payoffExtra(rub("400"), currency: .rub) == rub("100"))
    #expect(AdviceRules.payoffExtra(rub("12345"), currency: .rub) == rub("1200"))
    #expect(AdviceRules.payoffExtra(rub("12550"), currency: .rub) == rub("1300"))
    #expect(AdviceRules.payoffExtra(rub("35"), currency: .usd) == rub("4"))
    #expect(AdviceRules.payoffExtra(rub("4"), currency: .usd) == rub("1"))
  }

  // MARK: Owed to me

  /// Anna: 1 500 of a 3 000 purchase on 1 August and 700 on 2 September; Boris: 3 000 on
  /// 15 July (and 999 in May, returned); 400 on 20 June for nobody in particular; Vera: a
  /// loan of 5 000 from 10 May.
  func owedBook() -> AdviceData {
    var data = AdviceData()
    addOwed(to: &data)
    return data
  }

  func addOwed(to data: inout AdviceData) {
    data.add(
      .expense, "2026-08-01",
      [
        AdvicePart(amount: "1500", category: data.food),
        AdvicePart(
          amount: "1500", category: data.food, forWhom: .friends, reimbursable: true,
          status: .expected, debtor: data.anna),
      ])
    data.add(
      .expense, "2026-09-02",
      [
        AdvicePart(
          amount: "700", category: data.food, forWhom: .friends, reimbursable: true,
          debtor: data.anna)
      ])
    data.add(
      .expense, "2026-07-15",
      [
        AdvicePart(
          amount: "3000", category: data.fun, forWhom: .friends, reimbursable: true,
          status: .expected, debtor: data.boris)
      ])
    data.add(
      .expense, "2026-05-01",
      [
        AdvicePart(
          amount: "999", category: data.fun, forWhom: .friends, reimbursable: true,
          status: .returned, debtor: data.boris)
      ])
    data.add(
      .expense, "2026-06-20",
      [
        AdvicePart(
          amount: "400", category: data.fun, forWhom: .other, reimbursable: true,
          status: .expected)
      ])
    let loan = uid(710)
    data.debts.append(
      Debt(id: loan, direction: .owedToMe, type: .personal, name: "Vera", personId: data.vera))
    data.book.debtEntries.append(
      DebtEntry(debtId: loan, date: date("2026-05-10"), amountE4: rub("5000"), kind: .borrowed))
  }

  /// Vera 5 000, Boris 3 000, Anna 2 200 and 400 for nobody in particular: 10 600.
  @Test func owedByPersonLargestFirst() {
    let data = owedBook()
    let items = AdviceRules.owedByPerson(data.context(today), debts: overview(data))
    #expect(items.count == 1)
    #expect(
      items[0].terms == [
        term("advice.term.owedBy", .plus, money("5000"), .person("Vera")),
        term("advice.term.owedBy", .plus, money("3000"), .person("Boris")),
        term("advice.term.owedBy", .plus, money("2200"), .person("Anna")),
        term("advice.term.owedBy", .plus, money("400"), .person(nil)),
      ])
    #expect(items[0].result == term("advice.term.owedTotal", .equals, money("10600")))
    #expect(
      AdviceRules.owedByPerson(AdviceData().context(today), debts: overview(AdviceData())).isEmpty)
  }

  /// Seven people owing 700, 600 … 100: five are named, the other two are 300 together.
  @Test func owedByPersonSumsTheRest() {
    let groups = (1...7).map { index in
      OwedToMeGroup(
        personId: uid(900 + index), debts: [], parts: [],
        totalRub: rub(String(800 - index * 100)), oldest: nil)
    }
    let debts = DebtsOverview(
      iOwe: [], owedToMe: groups, closed: [], totalIOweRub: .zero, totalOwedToMeRub: rub("2800"),
      monthlyPaymentsRub: .zero, withoutRate: [])
    let items = AdviceRules.owedByPerson(AdviceData().context(today), debts: debts)
    #expect(items[0].terms.count == 6)
    #expect(items[0].terms.last == term("advice.term.owedByOthers", .plus, money("300")))
    #expect(items[0].result == term("advice.term.owedTotal", .equals, money("2800")))
  }

  /// The three oldest: Vera's loan of 10 May, the 400 of 20 June, Boris's 3 000 of 15 July.
  @Test func oldestOwedListsThreeExpectations() {
    let data = owedBook()
    let items = AdviceRules.oldestOwed(data.context(today), debts: overview(data))
    #expect(
      items.first?.terms == [
        term("advice.term.owedSince", .date(date("2026-05-10")), .person("Vera")),
        term("advice.term.owedAmount", money("5000")),
        term("advice.term.owedSince", .date(date("2026-06-20")), .person(nil)),
        term("advice.term.owedAmount", money("400")),
        term("advice.term.owedSince", .date(date("2026-07-15")), .person("Boris")),
        term("advice.term.owedAmount", money("3000")),
      ])
    #expect(
      AdviceRules.oldestOwed(AdviceData().context(today), debts: overview(AdviceData())).isEmpty)
  }

  // MARK: Subscriptions

  /// «Family plan» for Anna, 600 a month of which she returns 400, and «Music» for me, 300.
  func subscriptionBook() -> AdviceData {
    var data = AdviceData()
    data.book.scheduled = [
      ScheduledPayment(
        id: uid(800), name: "Family plan", kind: .subscription, amountE4: rub("600"),
        categoryId: data.fun, forWhom: .friends, forPersonId: data.anna, reimbursable: true,
        debtorPersonId: data.anna, reimbursementAmountE4: rub("400"), day: 5,
        nextDate: date("2026-10-05")),
      ScheduledPayment(
        id: uid(801), name: "Music", kind: .subscription, amountE4: rub("300"),
        categoryId: data.fun, day: 5, nextDate: date("2026-10-05")),
      ScheduledPayment(
        id: uid(802), name: "Rent", kind: .bill, amountE4: rub("30000"), categoryId: data.home,
        day: 1, nextDate: date("2026-10-01")),
    ]
    return data
  }

  /// Two subscriptions run; the totals are the snapshot's.
  @Test func subscriptionsMonthAndYear() {
    let data = subscriptionBook()
    let ledger = data.ledger
    let statuses = ScheduledRules.statuses(book: data.book, ledger: ledger, today: today)
    let items = AdviceRules.subscriptions(
      scheduled: statuses, monthly: rub("900"), yearly: rub("10800"))
    #expect(
      items.first?.terms == [
        term("advice.term.subscriptionsCount", .count(2)),
        term("advice.term.subscriptionsYearly", money("10800")),
      ])
    #expect(items.first?.result == term("advice.term.subscriptionsMonthly", .equals, money("900")))
    #expect(AdviceRules.subscriptions(scheduled: [], monthly: .zero, yearly: .zero).isEmpty)
  }

  /// «Family plan» paid on 5 July, 5 August, 5 September (and in August 2025, before the
  /// twelve months): 3 × 600 = 1 800 paid, 400 + 400 returned, 400 still expected, 600 —
  /// my three shares of 200 — cost me. «Music», not for others, stays out.
  @Test func subscriptionsForOthersPaidAndReturned() {
    var data = subscriptionBook()
    func pay(_ due: String, _ status: ReimbursementStatus, payment: Int = 800) {
      data.add(
        .expense, due,
        payment == 800
          ? [
            AdvicePart(
              amount: "400", category: data.fun, forWhom: .friends, reimbursable: true,
              status: status, debtor: data.anna),
            AdvicePart(amount: "200", category: data.fun, forWhom: .friends),
          ] : [AdvicePart(amount: "300", category: data.fun)],
        externalId: OperationLink.scheduled(paymentId: uid(payment), due: date(due)).externalId)
      if status == .returned { data.giveBack("400", on: due) }
    }
    pay("2025-08-05", .returned)
    pay("2026-07-05", .returned)
    pay("2026-08-05", .returned)
    pay("2026-09-05", .expected)
    pay("2026-09-05", .expected, payment: 801)
    let items = AdviceRules.subscriptionsForOthers(data.context(today), book: data.book)
    #expect(
      items.first?.terms == [
        term("advice.term.forOthersPaid", .plus, money("1800")),
        term("advice.term.forOthersReturned", .minus, money("800")),
        term("advice.term.forOthersWaiting", .minus, money("400")),
      ])
    #expect(items.first?.result == term("advice.term.forOthersCostMe", .equals, money("600")))
    #expect(
      items.first?.notes == [
        term("advice.term.forOthersPayments", .count(1)),
        term("advice.term.forOthersOperations", .count(3)),
      ])
  }

  /// A share of 400 closed with 300 returned: returned is the money that came back, and the
  /// 100 it fell short by is what it cost me. «Вернули» is the sum of the links.
  @Test func subscriptionsForOthersCountsWhatReallyCameBack() {
    var data = subscriptionBook()
    data.add(
      .expense, "2026-08-05",
      [
        AdvicePart(
          amount: "400", category: data.fun, forWhom: .friends, reimbursable: true,
          status: .returned, debtor: data.anna),
        AdvicePart(amount: "200", category: data.fun, forWhom: .friends),
      ],
      externalId: OperationLink.scheduled(paymentId: uid(800), due: date("2026-08-05")).externalId)
    data.giveBack("300", on: "2026-08-20")
    let items = AdviceRules.subscriptionsForOthers(data.context(today), book: data.book)
    #expect(
      items.first?.terms == [
        term("advice.term.forOthersPaid", .plus, money("600")),
        term("advice.term.forOthersReturned", .minus, money("300")),
        term("advice.term.forOthersWaiting", .minus, money("0")),
      ])
    #expect(items.first?.result == term("advice.term.forOthersCostMe", .equals, money("300")))
  }

  /// A share in dollars worth 4 000 ₽, closed by 3 970 ₽ that came back: the 30 ₽ between them
  /// is the drift of the rate, within what closes a part, not spending. It costs me nothing,
  /// as «За других» shows no shortfall for it; only my own share of 2 000 is what it cost me.
  @Test func subscriptionsForOthersCountsNoDriftOfTheRateAsCost() {
    var data = subscriptionBook()
    data.add(
      .expense, "2026-08-05",
      [
        AdvicePart(
          amount: "4000", category: data.fun, forWhom: .friends, reimbursable: true,
          status: .returned, debtor: data.anna),
        AdvicePart(amount: "2000", category: data.fun, forWhom: .friends),
      ],
      externalId: OperationLink.scheduled(paymentId: uid(800), due: date("2026-08-05")).externalId)
    data.entries[data.entries.count - 1].transaction.currency = .usd
    data.entries[data.entries.count - 1].transaction.rate = 100
    data.giveBack("3970", on: "2026-08-20")
    let items = AdviceRules.subscriptionsForOthers(data.context(today), book: data.book)
    #expect(
      items.first?.terms == [
        term("advice.term.forOthersPaid", .plus, money("6000")),
        term("advice.term.forOthersReturned", .minus, money("4000")),
        term("advice.term.forOthersWaiting", .minus, money("0")),
      ])
    #expect(items.first?.result == term("advice.term.forOthersCostMe", .equals, money("2000")))
  }

  /// A share of 400 still expected after 150 came back: 150 returned, 250 waiting — what is
  /// left of it —, and the 200 of my own share is what it cost me.
  @Test func subscriptionsForOthersWaitsForWhatIsLeftOfAShare() {
    var data = subscriptionBook()
    data.add(
      .expense, "2026-08-05",
      [
        AdvicePart(
          amount: "400", category: data.fun, forWhom: .friends, reimbursable: true,
          status: .expected, debtor: data.anna),
        AdvicePart(amount: "200", category: data.fun, forWhom: .friends),
      ],
      externalId: OperationLink.scheduled(paymentId: uid(800), due: date("2026-08-05")).externalId)
    data.giveBack("150", on: "2026-08-20")
    let items = AdviceRules.subscriptionsForOthers(data.context(today), book: data.book)
    #expect(
      items.first?.terms == [
        term("advice.term.forOthersPaid", .plus, money("600")),
        term("advice.term.forOthersReturned", .minus, money("150")),
        term("advice.term.forOthersWaiting", .minus, money("250")),
      ])
    #expect(items.first?.result == term("advice.term.forOthersCostMe", .equals, money("200")))
  }

  @Test func subscriptionsForOthersBeforeTheFirstPayment() {
    let data = subscriptionBook()
    #expect(
      AdviceRules.subscriptionsForOthers(data.context(today), book: data.book).map(\.status) == [
        .notEnoughData(reasonKey: "advice.reason.nothingPaidForOthers")
      ])
    #expect(AdviceRules.subscriptionsForOthers(data.context(today), book: PlanningBook()).isEmpty)
  }

  // MARK: Events

  /// Anna's birthday on 10 October has no target; the trip of 20–27 December has a budget
  /// of 60 000 with 6 000 spent: 54 000 over the 3 months to December is 18 000 a month.
  @Test func eventSavingForTheNearestEventWithATarget() {
    var data = AdviceData()
    let birthday = Event(
      id: uid(600), name: "Anna's birthday", kind: .birthday, startDate: date("2026-10-10"),
      endDate: date("2026-10-10"))
    let trip = Event(
      id: uid(601), name: "Trip", kind: .trip, startDate: date("2026-12-20"),
      endDate: date("2026-12-27"), budgetE4: rub("60000"))
    data.events = [birthday, trip]
    data.spend("2026-09-10", "6000", data.fun, event: trip.id)
    let items = AdviceRules.eventSaving(EventPlanning.build(ledger: data.ledger, today: today))
    #expect(items.map(\.id) == ["eventSaving:\(ids(601))"])
    #expect(items[0].subject == .event("Trip"))
    #expect(
      items[0].terms == [
        term("advice.term.eventBudget", .plus, money("60000")),
        term("advice.term.eventSpent", .minus, money("6000")),
        term("advice.term.eventMonths", .months(3)),
      ])
    #expect(items[0].result == term("advice.term.eventMonthlySaving", .equals, money("18000")))
    #expect(items[0].notes == [term("advice.term.eventStart", .date(date("2026-12-20")))])

    data.events = [birthday]
    let alone = AdviceRules.eventSaving(EventPlanning.build(ledger: data.ledger, today: today))
    #expect(
      alone == [
        Advice(
          id: "eventSaving:\(ids(600))", kind: .eventSaving, subject: .event("Anna's birthday"),
          status: .notEnoughData(reasonKey: "advice.reason.eventNoTarget"))
      ])
    data.events = []
    #expect(AdviceRules.eventSaving(EventPlanning.build(ledger: data.ledger, today: today)).isEmpty)
  }

  /// New Year 2026 has no budget; the one of 2025 cost 9 000: 9 000 over 3 months.
  @Test func eventSavingFromLastYear() {
    var data = AdviceData()
    let series = uid(610)
    let last = Event(
      id: uid(611), name: "New Year", kind: .newYear, startDate: date("2025-12-31"),
      endDate: date("2025-12-31"), seriesId: series)
    let next = Event(
      id: uid(612), name: "New Year", kind: .newYear, startDate: date("2026-12-31"),
      endDate: date("2026-12-31"), seriesId: series)
    data.events = [last, next]
    data.spend("2025-12-20", "9000", data.fun, event: last.id)
    let items = AdviceRules.eventSaving(EventPlanning.build(ledger: data.ledger, today: today))
    #expect(items.first?.terms.first == term("advice.term.eventLastTime", .plus, money("9000")))
    #expect(items.first?.result == term("advice.term.eventMonthlySaving", .equals, money("3000")))
  }

  // MARK: For whom

  /// June 1 000 of 10 000 for friends, July 2 000 of 10 000, August 3 000 of 10 000 for the
  /// partner; September to date 3 000 + 1 000 of 10 000 — 40 %. The part Anna will return
  /// and the 25th, still ahead, stay out.
  @Test func forWhomShareAndItsTrend() {
    var data = AdviceData()
    for (month, mine, others, whom) in [
      ("06", "9000", "1000", ForWhom.friends), ("07", "8000", "2000", ForWhom.partner),
      ("08", "7000", "3000", ForWhom.partner),
    ] {
      data.spend("2026-\(month)-10", mine, data.food)
      data.spend("2026-\(month)-11", others, data.food, forWhom: whom)
    }
    data.spend("2026-09-10", "6000", data.food)
    data.spend("2026-09-11", "3000", data.food, forWhom: .partner)
    data.spend("2026-09-12", "1000", data.food, forWhom: .family)
    data.spend("2026-09-25", "5000", data.food, forWhom: .partner)
    data.add(
      .expense, "2026-09-03",
      [
        AdvicePart(
          amount: "2000", category: data.food, forWhom: .friends, reimbursable: true,
          debtor: data.anna)
      ])
    let items = AdviceRules.forWhomShare(data.context(today))
    #expect(
      items.first?.terms == [
        term("advice.term.forOthersThisMonth", money("4000")),
        term("advice.term.spentThisMonth", money("10000")),
      ])
    #expect(items.first?.result == term("advice.term.forOthersShare", .equals, .basisPoints(4_000)))
    #expect(
      items.first?.notes == [
        term("advice.term.forOthersShare1MonthsAgo", .basisPoints(3_000)),
        term("advice.term.forOthersShare2MonthsAgo", .basisPoints(2_000)),
        term("advice.term.forOthersShare3MonthsAgo", .basisPoints(1_000)),
        term("advice.term.forOthersShareAverage", .basisPoints(2_000)),
      ])
  }

  @Test func forWhomShareWithoutSpendingOrWithoutOthers() {
    #expect(
      AdviceRules.forWhomShare(AdviceData().context(today)).map(\.status) == [
        .notEnoughData(reasonKey: "advice.reason.noSpending")
      ])
    var mine = AdviceData()
    mine.spend("2026-08-10", "5000", mine.food)
    mine.spend("2026-09-10", "5000", mine.food)
    #expect(AdviceRules.forWhomShare(mine.context(today)).isEmpty)
  }

  // MARK: Cashback

  /// June–August: Card A turned over 90 000 and brought 900 + 1 000 + 800 = 2 700 of
  /// cashback — 3 %; Card B 20 000 and Cash 5 000 brought none. September is not counted.
  @Test func cashbackByPaymentMethod() {
    var data = AdviceData()
    data.cashbackOn = true
    for (month, back) in [("06", "900"), ("07", "1000"), ("08", "800")] {
      data.spend("2026-\(month)-10", "30000", data.food, method: data.cardA)
      data.income("2026-\(month)-25", back, category: data.cashbackCategory, method: data.cardA)
    }
    data.spend("2026-07-12", "20000", data.home, method: data.cardB)
    data.spend("2026-08-12", "5000", data.food, method: data.cash)
    data.spend("2026-09-10", "10000", data.food, method: data.cardA)
    data.income("2026-09-12", "500", category: data.cashbackCategory, method: data.cardA)
    let items = AdviceRules.cashback(data.context(today))
    #expect(
      items.map(\.subject) == [
        .paymentMethod("Card A"), .paymentMethod("Card B"), .paymentMethod("Cash"),
      ])
    #expect(
      items[0].terms == [
        term("advice.term.cashbackReceived", money("2700")),
        term("advice.term.cashbackTurnover", money("90000")),
      ])
    #expect(items[0].result == term("advice.term.cashbackShare", .equals, .basisPoints(300)))
    #expect(items[0].notes == [term("advice.term.monthsCounted", .count(3))])
    #expect(items[1].result?.value == .basisPoints(0))
    #expect(items[0].id == "cashback:\(data.cardA.uuidString.lowercased())")
  }

  @Test func cashbackNeedsTheCategoryAndACompleteMonth() {
    var data = AdviceData()
    data.spend("2026-09-10", "10000", data.food, method: data.cardA)
    data.income("2026-09-12", "500", category: data.cashbackCategory, method: data.cardA)
    #expect(AdviceRules.cashback(data.context(today)).isEmpty)
    data.cashbackOn = true
    #expect(
      AdviceRules.cashback(data.context(today)).map(\.status) == [
        .notEnoughData(reasonKey: "advice.reason.noCompleteMonth")
      ])
  }

  // MARK: The whole book

  /// The report from a planning snapshot: «can save» and the savings rate are the snapshot's
  /// own, the items come in the order of the block, every id is unique.
  @Test func buildKeepsTheOrderOfTheBlock() {
    var data = history()
    data.cashbackOn = true
    data.goals = [
      Goal(
        id: data.car, name: "Car", targetE4: rub("100000"), targetDate: date("2026-12-31"),
        monthlyPlanE4: rub("5000"), subcategoryId: data.goalSubcategory)
    ]
    data.income("2026-08-01", "90000")
    data.income("2026-09-01", "100000")
    data.spend("2026-09-05", "1000", data.snacks, quality: .bad)
    data.spend("2026-09-06", "2000", data.food, forWhom: .partner, method: data.cardA)
    data.income("2026-08-25", "300", category: data.cashbackCategory, method: data.cardA)
    data.spend("2026-08-11", "10000", data.food, method: data.cardA)
    let debts = debtBook()
    data.debts = debts.debts
    data.book.debtEntries = debts.book.debtEntries
    addOwed(to: &data)
    data.book.scheduled = subscriptionBook().book.scheduled
    data.events = [
      Event(
        id: uid(601), name: "Trip", kind: .trip, startDate: date("2026-12-20"),
        endDate: date("2026-12-27"), budgetE4: rub("60000"))
    ]
    let ledger = data.ledger
    let planning = PlanningSnapshot.build(
      ledger: ledger, today: today, now: noon("2026-09-19"), rubPerUnit: usdRate)
    let remainder = MonthForecast.Remainder(
      p10: rub("5000"), middle: rub("10000"), p90: rub("15000"), lowData: false,
      computedFor: today, daysLeft: 11, windowDays: 90)
    let report = AdviceBook.build(
      planning: planning, ledger: ledger, remainder: remainder, today: today)

    #expect(report.canSave == planning.canSave(remainder: remainder))
    #expect(
      report.savingsRate
        == SavingsRate.month(ledger: ledger, month: today.monthKey, targetBp: 1_000))
    #expect(Set(report.items.map(\.id)).count == report.items.count)

    let order: [AdviceKind] = [
      .canSave, .savingsRate, .goal, .limitSuggestion, .growingCategory, .badComparison,
      .badCutScenario, .badLimitSuggestion, .debtLoad, .debtPayoff, .owedByPerson, .oldestOwed,
      .subscriptions, .subscriptionsForOthers, .eventSaving, .forWhomShare, .cashback,
    ]
    let ranks = report.items.map { order.firstIndex(of: $0.kind) ?? -1 }
    #expect(ranks == ranks.sorted())
    #expect(Set(report.items.map(\.kind)) == Set(AdviceKind.allCases))
    #expect(report.items.first { $0.kind == .subscriptions }?.result?.value == money("900"))
    #expect(report.items.first { $0.kind == .subscriptions }?.terms.last?.value == money("10800"))
  }
}
