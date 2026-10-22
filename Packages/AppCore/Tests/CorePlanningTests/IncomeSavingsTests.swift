import CoreAccounting
import CoreAnalytics
import CoreKit
import CoreSample
import Foundation
import Testing

@testable import CorePlanning

/// 2.2 «Доход и сбережения»: every figure is checked against a hand calculation on a small
/// synthetic book.
extension SavingsBook {
  var rent: UUID { uid(60) }
  var cafe: UUID { uid(61) }
  var lunch: UUID { uid(62) }
  var earnings: UUID { uid(63) }

  /// Rent is essential, cafe is not and «Lunch» hangs under it; «Earnings» is a top-level
  /// income category.
  mutating func addIncomeSavingsCategories() {
    categories += [
      CoreKit.Category(id: rent, kind: .expense, name: "Rent", essential: true),
      CoreKit.Category(id: cafe, kind: .expense, name: "Cafe"),
      CoreKit.Category(id: lunch, parentId: cafe, kind: .expense, name: "Lunch"),
      CoreKit.Category(id: earnings, kind: .income, name: "Заработок"),
    ]
  }

  /// One income on the 1st of every month from `first` through `last`.
  mutating func monthlyIncome(
    from first: MonthKey, through last: MonthKey, amounts: [String], category: UUID? = nil
  ) {
    for (index, month) in MonthKey.range(first, through: last).enumerated() {
      income(
        month.firstDay.iso, amounts[index % amounts.count], category: category)
    }
  }
}

@Suite("Settings of income and savings")
struct IncomeSavingsSettingsTests {
  @Test func proportionsMustAddUpToOneHundred() {
    #expect(BudgetProportions(needs: 60, wants: 25, savings: 15) != nil)
    #expect(BudgetProportions(needs: 60, wants: 25, savings: 16) == nil)
    #expect(BudgetProportions(needs: -10, wants: 60, savings: 50) == nil)
    #expect(BudgetProportions(storedValue: "60/25/15")?.storedValue == "60/25/15")
    #expect(BudgetProportions(storedValue: " 60 - 25 - 15 ") != nil)
    #expect(BudgetProportions(storedValue: "60/40") == nil)
    #expect(BudgetProportions(storedValue: "a/b/c") == nil)
    #expect(BudgetProportions.rule503020.targetBp(of: .savings) == 2_000)
  }

  @Test func theRowsRoundTripAndDefaultsDeleteTheirKeys() {
    let custom = IncomeSavingsSettings(
      proportions: BudgetProportions(needs: 60, wants: 25, savings: 15)!, earningsOnly: true,
      trendNudgeEnabled: false, trendNudgeShown: "2026-Q3")
    let rows = custom.storedValues.compactMapValues { $0 }
    #expect(IncomeSavingsSettings(storedValues: rows) == custom)
    // The defaults write nothing.
    #expect(IncomeSavingsSettings.standard.storedValues.values.allSatisfy { $0 == nil })
    #expect(
      Set(IncomeSavingsSettings.standard.storedValues.keys)
        == Set(IncomeSavingsSettings.storageKeys))
  }

  @Test func damagedValuesKeepTheirDefaults() {
    let settings = IncomeSavingsSettings(storedValues: [
      IncomeSavingsSettings.proportionsKey: "70/70/70",
      IncomeSavingsSettings.earningsOnlyKey: "maybe",
      IncomeSavingsSettings.trendNudgeEnabledKey: "",
      IncomeSavingsSettings.trendNudgeShownKey: "2026-Q9",
    ])
    #expect(settings == .standard)
  }
}

@Suite("Savings rate")
struct SavingsNormTests: SavingsFixtures {
  let today = DateOnly(year: 2026, month: 9, day: 19)
  let august = MonthKey(year: 2026, month: 8)

  /// Income 100 000, spending 80 000 of which 10 000 is a goal contribution: the rate is 30 %
  /// (goal money is kept), 20 % when the contribution is counted as spending.
  @Test func aGoalContributionIsKeptNotSpent() {
    var book = SavingsBook()
    book.income("2026-08-05", "100000")
    book.add(.expense, "2026-08-10", "70000", category: book.groceries)
    book.contribute("2026-08-12", "10000", goal: uid(500))
    let norm = SavingsNorm.month(august, ledger: book.ledger, today: today)
    #expect(norm.incomeRub == rub("100000"))
    #expect(norm.spendingRub == rub("80000"))
    #expect(norm.spendingWithoutGoalsRub == rub("70000"))
    #expect(norm.goalsNetRub == rub("10000"))
    #expect(norm.keptRub == rub("30000"))
    #expect(norm.rateBp == 3_000)
    #expect(norm.rateWithGoalsAsSpendingBp == 2_000)
    #expect(norm.state == .ready)
    #expect(!norm.isPartial)
  }

  /// More spent than came: the rate is negative as it is, not zero.
  @Test func aMonthInTheRedKeepsItsMinus() {
    var book = SavingsBook()
    book.income("2026-08-05", "100000")
    book.add(.expense, "2026-08-10", "115000", category: book.groceries)
    let norm = SavingsNorm.month(august, ledger: book.ledger, today: today)
    #expect(norm.keptRub == rub("-15000"))
    #expect(norm.rateBp == -1_500)
  }

  @Test func withoutIncomeThereIsNoRate() {
    var book = SavingsBook()
    book.add(.expense, "2026-08-10", "5000", category: book.groceries)
    let norm = SavingsNorm.month(august, ledger: book.ledger, today: today)
    #expect(norm.rateBp == nil)
    #expect(norm.rateWithGoalsAsSpendingBp == nil)
    #expect(norm.state == .noIncome)
  }

  /// Income counts by the month it is for; spending by date. Rounded half away from zero:
  /// 1 / 3 → 3 333 bp.
  @Test func incomeFollowsItsMonthAndTheRateRounds() {
    var book = SavingsBook()
    book.income("2026-09-01", "30000", for: "2026-08")
    book.add(.expense, "2026-08-10", "20000", category: book.groceries)
    let norm = SavingsNorm.month(august, ledger: book.ledger, today: today)
    #expect(norm.incomeRub == rub("30000"))
    #expect(norm.rateBp == 3_333)
  }

  /// The current month is marked as not over.
  @Test func theCurrentMonthIsPartial() {
    var book = SavingsBook()
    book.income("2026-09-05", "100000")
    book.add(.expense, "2026-09-10", "10000", category: book.groceries)
    let series = SavingsNorm.series(count: 3, ledger: book.ledger, today: today)
    #expect(series.map(\.month.iso) == ["2026-09"])  // history starts in September
    #expect(series.last?.isPartial == true)
    #expect(series.last?.rateBp == 9_000)
  }

  @Test func theSeriesRunsOldestFirstFromTheFirstOperation() {
    var book = SavingsBook()
    book.monthlyIncome(
      from: MonthKey(year: 2026, month: 5), through: MonthKey(year: 2026, month: 9),
      amounts: ["100000"])
    let series = SavingsNorm.series(count: 12, ledger: book.ledger, today: today)
    #expect(series.map(\.month.iso) == ["2026-05", "2026-06", "2026-07", "2026-08", "2026-09"])
    #expect(series.map(\.isPartial) == [false, false, false, false, true])
    #expect(SavingsNorm.series(count: 0, ledger: book.ledger, today: today).isEmpty)
  }

  /// With «only earnings»: 100 000 salary, 1 200 cashback and 3 400 interest. The rate is
  /// against 100 000, otherwise against 104 600.
  @Test func onlyEarningsLeavesCashbackAndInterestOut() {
    var book = SavingsBook()
    book.addIncomeSavingsCategories()
    book.income("2026-08-05", "100000", category: book.earnings)
    book.income("2026-08-06", "1200", category: book.help)
    book.income("2026-08-07", "3400", category: book.projects)
    book.add(.expense, "2026-08-10", "50000", category: book.groceries)
    let all = SavingsNorm.month(august, ledger: book.ledger, today: today)
    let earned = SavingsNorm.month(
      august, ledger: book.ledger, today: today, earningsOnly: true)
    #expect(all.incomeRub == rub("104600"))
    #expect(all.rateBp == 5_220)  // 54 600 / 104 600 = 52.199 %
    #expect(earned.incomeRub == rub("100000"))
    #expect(earned.rateBp == 5_000)
    #expect(!earned.earningsFallback)
  }

  @Test func withoutAnEarningsCategoryAllIncomeIsTakenAndSaid() {
    var book = SavingsBook()
    book.income("2026-08-05", "100000")
    let norm = SavingsNorm.month(august, ledger: book.ledger, today: today, earningsOnly: true)
    #expect(norm.earningsFallback)
    #expect(norm.incomeRub == rub("100000"))
  }

  @Test func theEarningsCategoryIsTheChosenOneElseTheNamedOne() {
    var book = SavingsBook()
    book.addIncomeSavingsCategories()
    #expect(EarningsCategory.resolve(chosen: nil, in: book.categories) == book.earnings)
    #expect(EarningsCategory.resolve(chosen: book.projects, in: book.categories) == book.projects)
    // An expense category cannot be chosen; the named one stands in.
    #expect(EarningsCategory.resolve(chosen: book.groceries, in: book.categories) == book.earnings)
    #expect(EarningsCategory.resolve(chosen: nil, in: SavingsBook().categories) == nil)
  }

  @Test func theCombinedRateWeighsBigMonthsMore() {
    var book = SavingsBook()
    book.income("2026-07-05", "100000")
    book.add(.expense, "2026-07-10", "50000", category: book.groceries)
    book.income("2026-08-05", "300000")
    book.add(.expense, "2026-08-10", "300000", category: book.groceries)
    let series = SavingsNorm.series(count: 3, ledger: book.ledger, today: today)
    // (50 000 + 0) / 400 000 = 12.5 % — the current, empty month is left out.
    #expect(SavingsNorm.combinedRateBp(series) == 1_250)
    #expect(SavingsNorm.combinedRateBp([]) == nil)
  }
}

@Suite("Budget baskets")
struct BudgetBasketsTests: SavingsFixtures {
  let today = DateOnly(year: 2026, month: 9, day: 19)
  let august = MonthKey(year: 2026, month: 8)

  func book() -> SavingsBook {
    var book = SavingsBook()
    book.addIncomeSavingsCategories()
    book.income("2026-08-01", "100000")
    book.add(.expense, "2026-08-02", "40000", category: book.rent)
    book.add(.expense, "2026-08-03", "10000", category: book.groceries)
    book.add(.expense, "2026-08-04", "20000", category: book.cafe)
    book.add(.expense, "2026-08-05", "5000", category: book.lunch)
    book.add(.expense, "2026-08-06", "8000", category: book.loansRoot)
    book.contribute("2026-08-07", "12000", goal: uid(500))
    return book
  }

  @Test func theDefaultsFollowTheNecessaryMarkAndTheSystemCategories() {
    let book = book()
    let tree = CategoryTree(book.categories)
    #expect(BudgetBaskets.basket(of: book.rent, tree: tree) == .needs)
    #expect(BudgetBaskets.basket(of: book.loansRoot, tree: tree) == .needs)
    #expect(BudgetBaskets.basket(of: book.groceries, tree: tree) == .wants)
    #expect(BudgetBaskets.basket(of: book.lunch, tree: tree) == .wants)
    #expect(BudgetBaskets.basket(of: book.carSubcategory, tree: tree) == .savings)
    #expect(BudgetBaskets.basket(of: nil, tree: tree) == .wants)
  }

  @Test func aSubcategoryTakesItsOwnBasketElseItsParents() {
    let book = book()
    let tree = CategoryTree(book.categories)
    #expect(
      BudgetBaskets.basket(of: book.lunch, tree: tree, overrides: [book.lunch: .needs]) == .needs)
    #expect(
      BudgetBaskets.basket(of: book.cafe, tree: tree, overrides: [book.lunch: .needs]) == .wants)
    // The parent's override reaches the subcategory that has none.
    #expect(
      BudgetBaskets.basket(of: book.lunch, tree: tree, overrides: [book.cafe: .needs]) == .needs)
    // The subcategory's own override wins over the parent's.
    #expect(
      BudgetBaskets.basket(
        of: book.lunch, tree: tree, overrides: [book.cafe: .needs, book.lunch: .savings])
        == .savings)
  }

  /// Needs 40 000 + 8 000 = 48 % · wants 10 000 + 20 000 + 5 000 = 35 % · savings 12 %.
  @Test func aMonthAgainstFiftyThirtyTwenty() throws {
    let book = book()
    let fit = BudgetBaskets.fit(
      month: august, ledger: book.ledger, today: today, income: rub("100000"),
      proportions: .rule503020)
    #expect(fit.lines.map(\.basket) == [.needs, .wants, .savings])
    #expect(fit.line(.needs)?.amountRub == rub("48000"))
    #expect(fit.line(.wants)?.amountRub == rub("35000"))
    #expect(fit.line(.savings)?.amountRub == rub("12000"))
    #expect(fit.line(.needs)?.shareBp == 4_800)
    #expect(fit.line(.needs)?.differenceBp == -200)
    #expect(fit.line(.needs)?.direction == .below)
    #expect(fit.line(.wants)?.differenceBp == 500)
    #expect(fit.line(.wants)?.direction == .above)
    #expect(fit.line(.savings)?.differenceBp == -800)
    #expect(fit.line(.savings)?.direction == .below)
    #expect(!fit.isPartial)
  }

  /// Own proportions 60 / 25 / 15, «Lunch» moved to needs, the cushion deposit goes to savings.
  @Test func ownProportionsOverridesAndTheCushion() throws {
    let book = book()
    let rule = try #require(BudgetProportions(needs: 60, wants: 25, savings: 15))
    let fit = BudgetBaskets.fit(
      month: august, ledger: book.ledger, today: today, income: rub("100000"), proportions: rule,
      overrides: [book.lunch: .needs], cushionDeposits: rub("3000"))
    #expect(fit.line(.needs)?.amountRub == rub("53000"))
    #expect(fit.line(.wants)?.amountRub == rub("30000"))
    #expect(fit.line(.savings)?.amountRub == rub("15000"))
    #expect(fit.line(.savings)?.direction == .onTarget)  // 15 % against 15 %
    #expect(fit.line(.needs)?.targetBp == 6_000)
    #expect(fit.line(.wants)?.direction == .above)  // 30 % against 25 %
    // They add up to 83 000 of spending + 12 000 to goals + 3 000 to the cushion.
    let total = AmountE4.sum(fit.lines.map(\.amountRub))
    #expect(total == rub("98000"))
  }

  @Test func withoutIncomeThereAreNoShares() {
    let book = book()
    let fit = BudgetBaskets.fit(
      month: august, ledger: book.ledger, today: today, income: .zero, proportions: .rule503020)
    #expect(fit.lines.allSatisfy { $0.shareBp == nil && $0.direction == nil })
  }
}

@Suite("Obligatory share and the cushion in days")
struct ObligatoryShareTests: SavingsFixtures {
  func spending(_ totals: [(MonthKey, String, String, String)]) -> ObligatorySpending {
    let months = totals.map {
      ObligatoryMonth(
        month: $0.0, scheduledRub: rub($0.1), debtsRub: rub($0.2), essentialRub: rub($0.3))
    }
    let median = IncomeEstimate.median(months.map(\.total))
    return ObligatorySpending(
      months: months, medianRub: median, committedRub: .zero, monthlyRub: median,
      state: .ready)
  }

  /// Obligatory 60 000 (median) against the median income 100 000 of the same months: 60 %,
  /// 40 % and 40 000 to manoeuvre with.
  @Test func theShareIsTheMedianOverTheMedian() throws {
    var book = SavingsBook()
    book.income("2026-06-01", "100000")
    book.income("2026-07-01", "90000")
    book.income("2026-08-01", "130000")
    let obligatory = spending([
      (MonthKey(year: 2026, month: 6), "20000", "15000", "25000"),
      (MonthKey(year: 2026, month: 7), "20000", "15000", "20000"),
      (MonthKey(year: 2026, month: 8), "20000", "15000", "35000"),
    ])
    let share = ObligatoryShare.build(obligatory: obligatory, ledger: book.ledger)
    #expect(share.state == .ready)
    #expect(share.obligatoryRub == rub("60000"))
    #expect(share.incomeRub == rub("100000"))
    #expect(share.shareBp == 6_000)
    #expect(share.roomBp == 4_000)
    #expect(share.roomRub == rub("40000"))
    #expect(share.scheduledRub == rub("20000"))
    #expect(share.debtsRub == rub("15000"))
    #expect(share.essentialRub == rub("25000"))
    #expect(share.months == 3)
  }

  @Test func theCommittedFloorRaisesTheShareAndCanLeaveNoRoom() {
    var book = SavingsBook()
    book.income("2026-06-01", "50000")
    book.income("2026-07-01", "50000")
    book.income("2026-08-01", "50000")
    var obligatory = spending([
      (MonthKey(year: 2026, month: 6), "10000", "10000", "20000"),
      (MonthKey(year: 2026, month: 7), "10000", "10000", "20000"),
      (MonthKey(year: 2026, month: 8), "10000", "10000", "20000"),
    ])
    obligatory.monthlyRub = rub("60000")  // a new loan: the committed floor is higher
    let share = ObligatoryShare.build(obligatory: obligatory, ledger: book.ledger)
    #expect(share.shareBp == 12_000)
    #expect(share.roomBp == -2_000)
    #expect(share.roomRub == rub("-10000"))
  }

  @Test func withoutObligatoryOrIncomeThereIsOnlyTheReason() {
    let book = SavingsBook()
    #expect(
      ObligatoryShare.build(obligatory: .empty, ledger: book.ledger).state == .noObligatory)
    let months = ObligatorySpending(
      months: [
        ObligatoryMonth(
          month: MonthKey(year: 2026, month: 8), scheduledRub: rub("1"), debtsRub: .zero,
          essentialRub: .zero)
      ], medianRub: rub("1"), committedRub: .zero, monthlyRub: rub("1"), state: .ready)
    let noIncome = ObligatoryShare.build(obligatory: months, ledger: book.ledger)
    #expect(noIncome.state == .noIncome)
    #expect(noIncome.shareBp == nil)
  }

  /// 210 000 on the cushion, 60 000 a month: 210 000 ÷ (60 000 ÷ 30.4) = 106.4 → 106 days.
  @Test func daysAreRoundedDown() {
    let days = CushionDays.days(money: rub("210000"), monthly: rub("60000"))
    #expect(days.days == 106)
    #expect(days.perDayRub == rub("1973.6842"))
    #expect(days.state == .ready)
  }

  @Test func daysEdges() {
    #expect(CushionDays.days(money: .zero, monthly: rub("60000")).days == 0)
    #expect(CushionDays.days(money: rub("-5"), monthly: rub("60000")).days == 0)
    #expect(CushionDays.days(money: rub("100"), monthly: .zero).state == .notEnoughData)
    // Exactly a month of the money is 30 whole days: 60 000 ÷ 60 000 × 30.4 = 30.4.
    #expect(CushionDays.days(money: rub("60000"), monthly: rub("60000")).days == 30)
  }

  @Test func daysFromTheStatus() {
    let ready = CushionStatus(
      moneyRub: rub("210000"), accounts: [UUID()], unanchored: [],
      obligatory: ObligatorySpending(
        months: [], medianRub: rub("60000"), committedRub: .zero, monthlyRub: rub("60000"),
        state: .ready),
      months: 3.5, goal: nil, state: .ready)
    #expect(CushionDays.build(ready).days == 106)
    #expect(CushionDays.build(.empty).state == .noAccounts)
    var waiting = ready
    waiting.state = .notEnoughData
    #expect(CushionDays.build(waiting).state == .notEnoughData)
  }
}

@Suite("Income stability")
struct IncomeStabilityTests: SavingsFixtures {
  let august = MonthKey(year: 2026, month: 9)

  func book(_ amounts: [String], from first: MonthKey) -> SavingsBook {
    var book = SavingsBook()
    let last = first.adding(months: amounts.count - 1)
    book.monthlyIncome(from: first, through: last, amounts: amounts)
    return book
  }

  /// Twelve months of 62, 80, 85, 90, 95, 100, 100, 105, 110, 120, 130 and 140 thousand: the
  /// lowest fifth is two months, so the bad month is the second lowest (80 000); the usual range
  /// is what is left without the two lowest and the two highest.
  @Test func theBadMonthIsTheEdgeOfTheLowestFifth() {
    let incomes = [
      "100000", "62000", "80000", "85000", "90000", "95000", "100000", "105000",
      "110000", "120000", "130000", "140000",
    ]
    let stability = IncomeStability.build(
      ledger: book(incomes, from: MonthKey(year: 2025, month: 9)).ledger, before: august)
    #expect(stability.state == .ready)
    #expect(stability.months.count == 12)
    #expect(stability.badMonthRub == rub("80000"))
    #expect(stability.usualLowRub == rub("85000"))
    #expect(stability.usualHighRub == rub("120000"))
    #expect(stability.medianRub == rub("100000"))
    #expect(!stability.lowData)
    #expect(!stability.isUneven)
  }

  /// One lone dip of 40 000 is the lowest month, yet the bad month is the second lowest.
  @Test func oneDipDoesNotSetThePlans() {
    let incomes = [
      "100000", "40000", "100000", "100000", "100000", "100000", "100000",
      "100000", "100000", "100000", "100000", "100000",
    ]
    let stability = IncomeStability.build(
      ledger: book(incomes, from: MonthKey(year: 2025, month: 9)).ledger, before: august)
    #expect(stability.badMonthRub == rub("100000"))
    #expect(stability.incomes.min() == rub("40000"))
  }

  @Test func fewMonthsMeanNoFigureAndSomeMeanLowData() {
    let few = IncomeStability.build(
      ledger: book(Array(repeating: "100000", count: 6), from: MonthKey(year: 2026, month: 3))
        .ledger,
      before: august)
    // Six months are there (March … August), enough, but fewer than twelve.
    #expect(few.state == .ready)
    #expect(few.lowData)
    let tooFew = IncomeStability.build(
      ledger: book(Array(repeating: "100000", count: 5), from: MonthKey(year: 2026, month: 4))
        .ledger,
      before: august)
    #expect(tooFew.state == .notEnoughData(months: 5))
    #expect(tooFew.badMonthRub == nil)
  }

  @Test func monthsBeforeTheFirstIncomeAreNoHistory() {
    var book = SavingsBook()
    // Spending since January, income from May: the months before May are no zeros of income.
    book.add(.expense, "2026-01-01", "100", category: book.groceries)
    book.monthlyIncome(
      from: MonthKey(year: 2026, month: 5), through: MonthKey(year: 2026, month: 8),
      amounts: ["100000"])
    let stability = IncomeStability.build(ledger: book.ledger, before: august)
    #expect(stability.months.first?.iso == "2026-05")
    #expect(stability.months.count == 4)
  }

  @Test func aWideRangeIsSaidToBeUneven() {
    let incomes = [
      "50000", "50000", "50000", "100000", "100000", "100000", "150000", "150000",
      "150000", "200000", "200000", "200000",
    ]
    let stability = IncomeStability.build(
      ledger: book(incomes, from: MonthKey(year: 2025, month: 9)).ledger, before: august)
    #expect(stability.usualLowRub == rub("50000"))
    #expect(stability.usualHighRub == rub("200000"))
    #expect(stability.isUneven)
  }

  @Test func theLookBackStopsAtTwoYears() {
    let incomes = Array(repeating: "100000", count: 36)
    let stability = IncomeStability.build(
      ledger: book(incomes, from: MonthKey(year: 2023, month: 9)).ledger, before: august)
    #expect(stability.months.count == IncomeStability.maximumMonths)
    #expect(stability.months.last?.iso == "2026-08")
  }
}

@Suite("Spending follows income")
struct SpendingFollowsIncomeTests: SavingsFixtures {
  let today = DateOnly(year: 2026, month: 9, day: 19)

  /// `from` through August 2026: income and spending per month by a function of the month.
  func book(
    from first: MonthKey, income: (MonthKey) -> String, spending: (MonthKey) -> String
  ) -> SavingsBook {
    var book = SavingsBook()
    for month in MonthKey.range(first, through: MonthKey(year: 2026, month: 8)) {
      book.income(month.firstDay.iso, income(month))
      book.add(
        .expense, month.firstDay.adding(days: 9).iso, spending(month), category: book.groceries)
    }
    return book
  }

  /// Income 100 000 → 120 000 (+20 %), spending 60 000 → 75 000 (+25 %) against the same three
  /// months a year ago: the gap is exactly the five points the line needs.
  @Test func threeMonthsAgainstTheSameThreeAYearAgo() {
    let book = book(
      from: MonthKey(year: 2025, month: 6),
      income: { $0.year == 2026 ? "120000" : "100000" },
      spending: { $0.year == 2026 ? "75000" : "60000" })
    let trend = SpendingFollowsIncome.build(ledger: book.ledger, today: today)
    #expect(trend.comparison == .yearOverYear)
    #expect(trend.recentMonths.map(\.iso) == ["2026-06", "2026-07", "2026-08"])
    #expect(trend.earlierMonths.map(\.iso) == ["2025-06", "2025-07", "2025-08"])
    #expect(trend.incomeChangeBp == 2_000)
    #expect(trend.spendingChangeBp == 2_500)
    #expect(trend.spendingOutpacesIncome)
    #expect(trend.state == .ready)
  }

  @Test func aSmallGapOrFallingIncomeIsNotAnAlarm() {
    let near = book(
      from: MonthKey(year: 2025, month: 6),
      income: { $0.year == 2026 ? "120000" : "100000" },
      spending: { $0.year == 2026 ? "74000" : "60000" })  // +23.3 %
    #expect(
      !SpendingFollowsIncome.build(ledger: near.ledger, today: today).spendingOutpacesIncome)
    let falling = book(
      from: MonthKey(year: 2025, month: 6),
      income: { $0.year == 2026 ? "90000" : "100000" },
      spending: { $0.year == 2026 ? "75000" : "60000" })
    #expect(
      !SpendingFollowsIncome.build(ledger: falling.ledger, today: today).spendingOutpacesIncome)
  }

  @Test func goalContributionsAreNotGrowthOfSpending() {
    var book = book(
      from: MonthKey(year: 2025, month: 6), income: { _ in "100000" }, spending: { _ in "60000" })
    book.contribute("2026-07-12", "30000", goal: uid(500))
    let trend = SpendingFollowsIncome.build(ledger: book.ledger, today: today)
    #expect(trend.spendingChangeBp == 0)
  }

  /// Less than a year and three months of history: six months against the six before them,
  /// marked as such.
  @Test func withoutAYearItIsSixToSix() {
    let book = book(
      from: MonthKey(year: 2025, month: 9),
      income: { $0.year == 2026 && $0.month >= 3 ? "120000" : "100000" },
      spending: { $0.year == 2026 && $0.month >= 3 ? "75000" : "60000" })
    let trend = SpendingFollowsIncome.build(ledger: book.ledger, today: today)
    #expect(trend.comparison == .sixToSix)
    #expect(trend.recentMonths.map(\.iso).first == "2026-03")
    #expect(trend.earlierMonths.map(\.iso).first == "2025-09")
    #expect(trend.incomeChangeBp == 2_000)
    #expect(trend.spendingOutpacesIncome)
  }

  @Test func withTooLittleHistoryThereIsNothing() {
    let book = book(
      from: MonthKey(year: 2026, month: 3), income: { _ in "100000" }, spending: { _ in "1" })
    let trend = SpendingFollowsIncome.build(ledger: book.ledger, today: today)
    #expect(trend.state == .notEnoughData)
    #expect(trend.comparison == nil)
    #expect(!trend.spendingOutpacesIncome)
  }

  @Test func theNudgeComesOnceAQuarterAndCanBeSwitchedOff() {
    let trend = SpendingFollowsIncome(
      comparison: .yearOverYear, recentMonths: [], earlierMonths: [], incomeRub: .zero,
      earlierIncomeRub: .zero, spendingRub: .zero, earlierSpendingRub: .zero,
      incomeChangeBp: 2_000, spendingChangeBp: 2_500, spendingOutpacesIncome: true,
      state: .ready)
    let settings = IncomeSavingsSettings.standard
    #expect(TrendNudge.quarterKey(of: today) == "2026-Q3")
    #expect(TrendNudge.quarterKey(of: DateOnly(year: 2026, month: 12, day: 31)) == "2026-Q4")
    #expect(TrendNudge.quarterKey(of: DateOnly(year: 2027, month: 1, day: 1)) == "2027-Q1")
    #expect(TrendNudge.shouldShow(trend, settings: settings, today: today))

    let shown = TrendNudge.markShown(settings, today: today)
    #expect(shown.trendNudgeShown == "2026-Q3")
    #expect(!TrendNudge.shouldShow(trend, settings: shown, today: today))
    #expect(
      !TrendNudge.shouldShow(
        trend, settings: shown, today: DateOnly(year: 2026, month: 9, day: 30)))
    #expect(
      TrendNudge.shouldShow(trend, settings: shown, today: DateOnly(year: 2026, month: 10, day: 1)))

    let off = TrendNudge.turnedOff(settings)
    #expect(!TrendNudge.shouldShow(trend, settings: off, today: today))
    // Nothing worth saying: no line, whatever the settings.
    var calm = trend
    calm.spendingOutpacesIncome = false
    #expect(!TrendNudge.shouldShow(calm, settings: settings, today: today))
  }
}

@Suite("Salary effect")
struct SalaryEffectTests: SavingsFixtures {
  let today = DateOnly(year: 2026, month: 9, day: 19)

  func status(
    _ id: Int, _ name: String, dues: [(String, UUID)]
  ) -> ExpectedIncomeStatus {
    let income = ExpectedIncome(
      id: uid(id), name: name, kind: .recurring, totalE4: rub("1"), dueDate: nil)
    let occurrences = dues.map {
      ExpectedOccurrence(
        due: date($0.0), total: rub("1"), received: rub("1"), remaining: .zero, remainingRub: .zero,
        partsReceived: 1, transactionIds: [$0.1])
    }
    return ExpectedIncomeStatus(
      income: income, occurrences: occurrences, received: rub("1"), receivedRub: rub("1"),
      remaining: .zero, remainingRub: .zero, partsReceived: occurrences.count,
      partsExpected: occurrences.count, isFulfilled: true, isOverdue: false,
      linkedTransactionIds: dues.map(\.1), withoutRate: false)
  }

  /// A salary on the 10th of May … August and an advance on the 25th of May and June. Every
  /// day costs 1 000, but the three days from a salary cost 2 100 and the three days from an
  /// advance stay 1 000.
  func fixture() -> (SavingsBook, [ExpectedIncomeStatus]) {
    var book = SavingsBook()
    let salaryDays = ["2026-05-10", "2026-06-10", "2026-07-10", "2026-08-10"]
    let advanceDays = ["2026-05-25", "2026-06-25"]
    var salaryDues: [(String, UUID)] = []
    var advanceDues: [(String, UUID)] = []
    for day in salaryDays { salaryDues.append((day, book.income(day, "50000"))) }
    for day in advanceDays { advanceDues.append((day, book.income(day, "20000"))) }
    var windowDays: Set<Int> = []
    for day in salaryDays {
      for offset in 0..<3 { windowDays.insert(date(day).dayNumber + offset) }
    }
    var cursor = date("2026-04-01")
    while cursor <= date("2026-09-18") {
      book.add(
        .expense, cursor.iso, windowDays.contains(cursor.dayNumber) ? "2100" : "1000",
        category: book.groceries)
      cursor = cursor.adding(days: 1)
    }
    return (
      book,
      [status(700, "Salary", dues: salaryDues), status(701, "Advance", dues: advanceDues)]
    )
  }

  @Test func theFirstThreeDaysAgainstTheRestOfTheMonth() throws {
    let (book, statuses) = fixture()
    let effect = SalaryEffect.build(ledger: book.ledger, statuses: statuses, today: today)
    #expect(effect.state == .ready)
    let salary = try #require(effect.perIncome.first { $0.incomeId == uid(700) })
    #expect(salary.events == 4)
    #expect(salary.afterPerDayRub == rub("2100"))
    #expect(salary.restPerDayRub == rub("1000"))
    #expect(salary.ratioHundredths == 210)
    let advance = try #require(effect.perIncome.first { $0.incomeId == uid(701) })
    #expect(advance.events == 2)
    #expect(advance.ratioHundredths == 100)
    // 12 days at 2 100 and 6 at 1 000 → 1 733.33 against 1 000.
    let overall = try #require(effect.overall)
    #expect(overall.events == 6)
    #expect(overall.ratioHundredths == 173)
  }

  @Test func oneEventIsNoPattern() {
    var (book, statuses) = fixture()
    statuses = [status(700, "Salary", dues: [("2026-08-10", book.income("2026-08-10", "50000"))])]
    let effect = SalaryEffect.build(ledger: book.ledger, statuses: statuses, today: today)
    #expect(effect.state == .notEnoughData)
    #expect(effect.overall == nil)
  }

  /// The money that came yesterday has not had its three days yet: not an event.
  @Test func anUnfinishedWindowIsNotCounted() throws {
    var (book, statuses) = fixture()
    let late = book.income("2026-09-17", "50000")
    statuses[0].occurrences.append(
      ExpectedOccurrence(
        due: date("2026-09-17"), total: rub("1"), received: rub("1"), remaining: .zero,
        remainingRub: .zero, partsReceived: 1, transactionIds: [late]))
    let effect = SalaryEffect.build(ledger: book.ledger, statuses: statuses, today: today)
    let salary = try #require(effect.perIncome.first { $0.incomeId == uid(700) })
    #expect(salary.events == 4)
    #expect(salary.ratioHundredths == 210)
  }

  @Test func noStatusesNoEffect() {
    let (book, _) = fixture()
    #expect(
      SalaryEffect.build(ledger: book.ledger, statuses: [], today: today).state == .notEnoughData)
  }
}

@Suite("Financial health")
struct FinancialHealthTests: SavingsFixtures {
  func noPayments() -> DebtLoad {
    DebtLoad(
      monthlyPaymentsRub: .zero, incomeRub: rub("100000"), incomeSource: .given, loadBp: 0,
      withoutRate: [], withoutPayment: [], status: .ready)
  }

  func load(_ bp: Int) -> DebtLoad {
    DebtLoad(
      monthlyPaymentsRub: rub("\(bp * 10)"), incomeRub: rub("100000"), incomeSource: .given,
      loadBp: bp, withoutRate: [], withoutPayment: [], status: .ready)
  }

  func stability(bad: String, median: String) -> IncomeStability {
    IncomeStability(
      months: [], incomes: [], badMonthRub: rub(bad), usualLowRub: rub(bad),
      usualHighRub: rub(median), medianRub: rub(median), lowData: false, isUneven: false,
      state: .ready)
  }

  func inputs(
    cushion: Decimal? = 6, load: DebtLoad? = nil, savings: Int? = 2_000, overdue: Int = 0,
    stability: IncomeStability? = nil
  ) -> HealthInputs {
    HealthInputs(
      cushionMonths: cushion, debtLoad: load ?? noPayments(), savingsRateBp: savings,
      overdueCount: overdue, stability: stability ?? self.stability(bad: "100", median: "100"))
  }

  @Test func theWeightsAddUpToOneHundred() {
    #expect(HealthPart.allCases.map(\.weight).reduce(0, +) == 100)
    #expect(HealthPart.cushion.weight == 30)
    #expect(HealthPart.debtLoad.weight == 30)
  }

  @Test func everythingInOrderIsOneHundred() {
    let health = FinancialHealth.build(inputs())
    #expect(health.state == .ready)
    #expect(health.total == 100)
    #expect(health.parts.map(\.maxPoints) == [30, 30, 14, 13, 13])
    #expect(health.parts.map(\.points) == [30, 30, 14, 13, 13])
    #expect(health.notCounted.isEmpty)
  }

  /// Cushion 3 of 6 months → half of 30; load 30 % → half of 30; savings 10 % → half of 14;
  /// one overdue → three quarters of 13; income bad month 80 % of the median → 80 % of 13.
  /// 15 + 15 + 7 + 9.75 + 10.4 = 57.15 → 57, the breakdown adds up to it.
  @Test func theBreakdownAddsUpToTheNumber() {
    let health = FinancialHealth.build(
      inputs(
        cushion: 3, load: load(3_000), savings: 1_000, overdue: 1,
        stability: stability(bad: "80", median: "100")))
    #expect(health.parts.map(\.scoreBp) == [5_000, 5_000, 5_000, 7_500, 8_000])
    #expect(health.total == 57)
    #expect(health.parts.map(\.points).reduce(0, +) == 57)
    #expect(health.parts.map(\.points) == [15, 15, 7, 10, 10])
    #expect(zip(health.parts.map(\.points), health.parts.map(\.maxPoints)).allSatisfy { $0 <= $1 })
  }

  /// No cushion accounts: the other four are scaled to 100 and the cushion is said not to be
  /// counted — the owner is not punished for what is not set up.
  @Test func aMissingPartIsLeftOutAndTheRestAreScaled() {
    let health = FinancialHealth.build(inputs(cushion: nil))
    #expect(health.notCounted == [.cushion])
    #expect(health.total == 100)
    #expect(health.parts.map(\.maxPoints) == [0, 43, 20, 19, 18])
    #expect(health.parts.map(\.maxPoints).reduce(0, +) == 100)
    #expect(health.parts[0].scoreBp == nil)
  }

  @Test func noDebtsIsAFullScoreButPaymentsWithoutIncomeAreNotCounted() {
    #expect(FinancialHealth.score(.debtLoad, inputs()) == 10_000)
    let withoutIncome = DebtLoad(
      monthlyPaymentsRub: rub("5000"), incomeRub: nil, incomeSource: .none, loadBp: nil,
      withoutRate: [], withoutPayment: [],
      status: .notEnoughData(reasonKey: DebtLoad.noIncomeKey))
    #expect(FinancialHealth.score(.debtLoad, inputs(load: withoutIncome)) == nil)
    #expect(FinancialHealth.score(.debtLoad, inputs(load: load(1_000))) == 10_000)
    #expect(FinancialHealth.score(.debtLoad, inputs(load: load(5_000))) == 0)
    #expect(FinancialHealth.score(.debtLoad, inputs(load: load(7_000))) == 0)
    #expect(FinancialHealth.score(.debtLoad, inputs(load: load(3_000))) == 5_000)
  }

  @Test func scalesAreClamped() {
    #expect(FinancialHealth.score(.cushion, inputs(cushion: 12)) == 10_000)
    #expect(FinancialHealth.score(.cushion, inputs(cushion: 0)) == 0)
    #expect(FinancialHealth.score(.savings, inputs(savings: -1_500)) == 0)
    #expect(FinancialHealth.score(.savings, inputs(savings: 5_000)) == 10_000)
    #expect(FinancialHealth.score(.savings, inputs(savings: nil)) == nil)
    #expect(FinancialHealth.score(.overdue, inputs(overdue: 9)) == 0)
    var short = inputs()
    short.stability = IncomeStability(
      months: [], incomes: [], badMonthRub: nil, usualLowRub: nil, usualHighRub: nil,
      medianRub: nil, lowData: true, isUneven: false, state: .notEnoughData(months: 2))
    #expect(FinancialHealth.score(.stability, short) == nil)
  }

  @Test func fewerThanTwoPartsGiveNoNumber() {
    var only = inputs(cushion: nil, savings: nil)
    only.debtLoad = nil
    only.stability = nil
    // Only the overdue count is left.
    let health = FinancialHealth.build(only)
    #expect(health.state == .notEnoughData)
    #expect(health.total == nil)
    #expect(health.notCounted.count == 4)
  }

  @Test func apportioningKeepsTheTotalAndTheOrderOfRemainders() {
    let shares = FinancialHealth.apportion(
      [Decimal(string: "33.3")!, Decimal(string: "33.3")!, Decimal(string: "33.4")!], to: 100)
    #expect(shares == [33, 33, 34])
    for seed in 1...50 {
      var generator = SeededRandom(seed: UInt64(seed))
      let count = 2 + Int(generator.next() % 4)
      let exact = (0..<count).map { _ in Decimal(Int(generator.next() % 5_000)) / 100 }
      let total = (try? DecimalMath.int64(rounding: exact.reduce(0, +))).map(Int.init) ?? 0
      let result = FinancialHealth.apportion(exact, to: total)
      #expect(result.reduce(0, +) == total)
      // Each share is the floor or the ceiling of its exact value.
      for (value, share) in zip(exact, result) {
        #expect(Decimal(share) >= value - 1 && Decimal(share) <= value + 1)
      }
    }
  }

  /// The history is worked out from the data each time: a corrected operation moves the number
  /// of its month.
  @Test func theHistoryFollowsTheData() {
    var book = SavingsBook()
    book.monthlyIncome(
      from: MonthKey(year: 2026, month: 1), through: MonthKey(year: 2026, month: 8),
      amounts: ["100000"])
    book.add(.expense, "2026-07-10", "50000", category: book.groceries)
    func parts(_ month: MonthKey) -> HealthInputs {
      let ledgerParts = FinancialHealth.ledgerParts(ledger: book.ledger, asOf: month)
      return HealthInputs(
        cushionMonths: 3, debtLoad: noPayments(), savingsRateBp: ledgerParts.savingsRateBp,
        overdueCount: 0, stability: ledgerParts.stability)
    }
    let months = [MonthKey(year: 2026, month: 7), MonthKey(year: 2026, month: 8)]
    let before = FinancialHealth.series(months: months, inputs: parts)
    #expect(before.map(\.month) == months)
    // July looks back over April–June (all kept), August over May–July (50 000 spent in July).
    #expect(before.map { $0.health.parts[2].scoreBp } == [10_000, 10_000])
    #expect(
      FinancialHealth.ledgerParts(ledger: book.ledger, asOf: MonthKey(year: 2026, month: 7))
        .savingsRateBp == 10_000)
    #expect(
      FinancialHealth.ledgerParts(ledger: book.ledger, asOf: MonthKey(year: 2026, month: 8))
        .savingsRateBp == 8_333)  // (300 000 − 50 000) ÷ 300 000
    // The spending is corrected afterwards: the rate of August follows.
    book.entries.removeAll()
    book.monthlyIncome(
      from: MonthKey(year: 2026, month: 1), through: MonthKey(year: 2026, month: 8),
      amounts: ["100000"])
    #expect(
      FinancialHealth.ledgerParts(ledger: book.ledger, asOf: MonthKey(year: 2026, month: 8))
        .savingsRateBp == 10_000)
  }
}
