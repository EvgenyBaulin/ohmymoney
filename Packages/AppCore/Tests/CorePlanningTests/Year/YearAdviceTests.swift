import CoreKit
import Foundation
import Testing

@testable import CorePlanning

@Suite("Seasonal limits: an exception for the dear month")
struct LimitSeasonTests {
  typealias Fx = YearFx

  static let gifts = Budget(
    id: Fx.id(50), scope: .category, categoryId: Fx.id(1), amountE4: Fx.rub(5_000))

  /// Gifts: 3 000 a month, 20 000 in December, two years running.
  static var history: SpendingHistory {
    Fx.history(months: 24, base: 3_000, heavy: [12: 20_000])
  }

  @Test func inNovemberDecemberIsOffered() throws {
    let found = LimitSeasonAdvisor.suggestions(
      budgets: [Self.gifts], history: Self.history, exceptions: [], today: Fx.day("2026-11-10"))
    let suggestion = try #require(found.first)
    #expect(found.count == 1)
    #expect(suggestion.month == Fx.m(2026, 12))
    #expect(suggestion.typical == Fx.rub(20_000))
    #expect(suggestion.suggested == Fx.rub(20_000))
    #expect(suggestion.currentLimit == Fx.rub(5_000))
    #expect(suggestion.basis == .twoYears)
  }

  @Test func onlyTheMonthBeforeAsks() {
    let history = Self.history
    #expect(
      LimitSeasonAdvisor.suggestions(
        budgets: [Self.gifts], history: history, exceptions: [], today: Fx.day("2026-10-31")
      )
      .isEmpty)
  }

  @Test func theSuggestionIsRoundedUpToAHundred() throws {
    let history = Fx.history(months: 24, base: 3_000, heavy: [12: 20_050])
    let found = LimitSeasonAdvisor.suggestions(
      budgets: [Self.gifts], history: history, exceptions: [], today: Fx.day("2026-11-01"))
    #expect(found.first?.suggested == Fx.rub(20_100))
  }

  @Test func aLimitThatCoversTheMonthIsLeftAlone() {
    var roomy = Self.gifts
    roomy.amountE4 = Fx.rub(19_000)
    #expect(
      LimitSeasonAdvisor.suggestions(
        budgets: [roomy], history: Self.history, exceptions: [], today: Fx.day("2026-11-10")
      )
      .isEmpty)
  }

  @Test func withoutAYearOfHistoryNothingIsOffered() {
    let short = Fx.history(months: 11, base: 3_000, heavy: [12: 20_000])
    #expect(
      LimitSeasonAdvisor.suggestions(
        budgets: [Self.gifts], history: short, exceptions: [], today: Fx.day("2026-11-10")
      )
      .isEmpty)
  }

  @Test func anExistingExceptionOrDismissalSilencesIt() throws {
    let exceptions = [
      LimitMonthException(budgetId: Self.gifts.id, month: Fx.m(2026, 12), amountE4: Fx.rub(15_000))
    ]
    #expect(
      LimitSeasonAdvisor.suggestions(
        budgets: [Self.gifts], history: Self.history, exceptions: exceptions,
        today: Fx.day("2026-11-10")
      ).isEmpty)
    let first = try #require(
      LimitSeasonAdvisor.suggestions(
        budgets: [Self.gifts], history: Self.history, exceptions: [], today: Fx.day("2026-11-10")
      ).first)
    #expect(
      LimitSeasonAdvisor.suggestions(
        budgets: [Self.gifts], history: Self.history, exceptions: [], today: Fx.day("2026-11-10"),
        dismissed: [first.id]
      ).isEmpty)
  }

  @Test func anAlwaysTooSmallLimitIsNotASeasonalOne() {
    let flat = Fx.history(months: 24, base: 9_000)
    #expect(
      LimitSeasonAdvisor.suggestions(
        budgets: [Self.gifts], history: flat, exceptions: [], today: Fx.day("2026-11-10")
      ).isEmpty)
  }

  @Test func theExceptionHoldsForItsMonthOnly() {
    let exceptions = LimitSchedule.setting(
      Fx.rub(20_000), for: Self.gifts.id, in: Fx.m(2026, 12), exceptions: [])
    #expect(
      LimitSchedule.amount(of: Self.gifts, in: Fx.m(2026, 12), exceptions: exceptions)
        == Fx.rub(20_000))
    #expect(
      LimitSchedule.amount(of: Self.gifts, in: Fx.m(2027, 1), exceptions: exceptions)
        == Fx.rub(5_000))
    #expect(
      LimitSchedule.amount(of: Self.gifts, in: Fx.m(2026, 11), exceptions: exceptions)
        == Fx.rub(5_000))
    // One exception per budget and month: setting again replaces.
    let again = LimitSchedule.setting(
      Fx.rub(18_000), for: Self.gifts.id, in: Fx.m(2026, 12), exceptions: exceptions)
    #expect(again.count == 1)
    #expect(
      LimitSchedule.budget(Self.gifts, in: Fx.m(2026, 12), exceptions: again).amountE4
        == Fx.rub(18_000))
  }

  @Test func theStoredFormHasTheColumnNamesOfTheTable() throws {
    let exception = LimitMonthException(
      id: Fx.id(9), budgetId: Fx.id(50), month: Fx.m(2026, 12), amountE4: Fx.rub(1))
    let data = try JSONEncoder().encode(exception)
    let text = String(decoding: data, as: UTF8.self)
    #expect(text.contains("\"budget_id\"") && text.contains("\"amount_e4\":10000"))
    #expect(text.contains("\"2026-12\""))
    #expect(try JSONDecoder().decode(LimitMonthException.self, from: data) == exception)
  }
}

@Suite("Yearly expenses and the savings for them")
struct YearlyExpenseTests {
  typealias Fx = YearFx

  static let insurance = Fx.id(70)
  static let groceries = Fx.id(71)

  static func record(
    _ iso: String, _ whole: Int64, _ category: UUID, _ title: String = "OSAGO"
  )
    -> YearlyRecord
  {
    YearlyRecord(day: Fx.day(iso), amount: Fx.rub(whole), categoryId: category, title: title)
  }

  static var records: [YearlyRecord] {
    var result = [
      record("2025-03-12", 11_500, insurance), record("2026-03-10", 12_500, insurance),
    ]
    // Groceries every few days for two years.
    var day = Fx.day("2025-01-01")
    while day < Fx.day("2027-01-31") {
      result.append(
        YearlyRecord(day: day, amount: Fx.rub(900), categoryId: groceries, title: "Shop"))
      day = day.adding(days: 3)
    }
    return result
  }

  @Test func theInsuranceIsFoundAndGroceriesAreNot() throws {
    let found = YearlyExpenseFinder.find(records: Self.records)
    #expect(found.count == 1)
    let expense = try #require(found.first)
    #expect(expense.key == .category(Self.insurance))
    #expect(expense.expectedDate == Fx.day("2027-03-10"))
    #expect(expense.expectedAmount == Fx.rub(12_000))
    #expect(expense.years == 2)
  }

  @Test func itIsOfferedInFebruaryNotInSeptember() {
    let records = Self.records.filter { $0.categoryId == Self.insurance }
    #expect(
      YearlyExpenseFinder.suggestions(records: records, today: Fx.day("2027-02-05")).count == 1)
    #expect(YearlyExpenseFinder.suggestions(records: records, today: Fx.day("2026-09-05")).isEmpty)
    // Past its date it is not offered any more.
    #expect(YearlyExpenseFinder.suggestions(records: records, today: Fx.day("2027-03-11")).isEmpty)
  }

  @Test func oneYearIsNotEnough() {
    let records = [Self.record("2026-03-10", 12_000, Self.insurance)]
    #expect(YearlyExpenseFinder.find(records: records).isEmpty)
  }

  @Test func twoPaymentsMoreThanAYearApartAreNotYearly() {
    let records = [
      Self.record("2024-03-10", 12_000, Self.insurance),
      Self.record("2026-03-10", 12_000, Self.insurance),
    ]
    #expect(YearlyExpenseFinder.find(records: records).isEmpty)
  }

  @Test func amountsThatDifferALotAreNotTheSameExpense() {
    let records = [
      Self.record("2025-03-10", 12_000, Self.insurance),
      Self.record("2026-03-10", 40_000, Self.insurance),
    ]
    #expect(YearlyExpenseFinder.find(records: records).isEmpty)
  }

  @Test func aPaymentInTwoPartsIsOneOccurrence() throws {
    let records = [
      Self.record("2025-03-05", 6_000, Self.insurance),
      Self.record("2025-03-20", 6_000, Self.insurance),
      Self.record("2026-03-08", 7_000, Self.insurance),
      Self.record("2026-03-25", 5_000, Self.insurance),
    ]
    let expense = try #require(YearlyExpenseFinder.find(records: records).first)
    #expect(expense.expectedAmount == Fx.rub(12_000))
  }

  @Test func anInterveningPaymentBreaksTheRun() {
    let records = [
      Self.record("2025-03-10", 12_000, Self.insurance),
      Self.record("2025-09-10", 12_000, Self.insurance),
      Self.record("2026-03-10", 12_000, Self.insurance),
    ]
    #expect(YearlyExpenseFinder.find(records: records).isEmpty)
  }

  @Test func whatIsAlreadySavedForOrPutOffStaysAway() throws {
    let records = Self.records.filter { $0.categoryId == Self.insurance }
    let today = Fx.day("2027-02-05")
    #expect(
      YearlyExpenseFinder.suggestions(
        records: records, today: today, covered: [.category(Self.insurance)]
      ).isEmpty)
    let expense = try #require(
      YearlyExpenseFinder.suggestions(records: records, today: today).first)
    #expect(
      YearlyExpenseFinder.suggestions(records: records, today: today, dismissed: [expense.id])
        .isEmpty)
  }

  @Test func aPlaceAndACategoryOfTheSamePaymentGiveOneSuggestion() {
    let place = Fx.id(72)
    let records = Self.records.filter { $0.categoryId == Self.insurance }.map {
      YearlyRecord(
        day: $0.day, amount: $0.amount, categoryId: $0.categoryId, placeId: place, title: $0.title)
    }
    let found = YearlyExpenseFinder.suggestions(records: records, today: Fx.day("2027-02-05"))
    #expect(found.count == 1)
    #expect(found.first?.key == .place(place))
  }

  @Test func theSavingIsAnOrdinaryGoalWithAPlanThatReachesTheTarget() throws {
    let expense = try #require(
      YearlyExpenseFinder.suggestions(
        records: Self.records.filter { $0.categoryId == Self.insurance },
        today: Fx.day("2027-02-05")
      ).first)
    let goal = AnnualReserve.goal(for: expense, today: Fx.day("2027-02-05"))
    #expect(goal.name == "OSAGO" && goal.targetE4 == Fx.rub(12_000))
    #expect(goal.targetDate == Fx.day("2027-03-10"))
    // February and March: two months, 6 000 each.
    #expect(goal.monthlyPlanE4 == Fx.rub(6_000))
    #expect(goal.planStartMonth == Fx.m(2027, 2))
    // Seven months ahead: 12 000 / 8 = 1 500.
    let early = AnnualReserve.goal(for: expense, today: Fx.day("2026-08-01"))
    #expect(early.monthlyPlanE4 == Fx.rub(1_500))
    // A target that does not divide rounds the plan up.
    var odd = expense
    odd.expectedAmount = Fx.rub(10_000)
    #expect(
      AnnualReserve.goal(for: odd, today: Fx.day("2026-12-15")).monthlyPlanE4 == Fx.rub(2_500))
  }

  @Test func startingAgainMovesTheDateAYearOn() {
    let goal = Goal(
      name: "OSAGO", targetE4: Fx.rub(12_000), targetDate: Fx.day("2027-03-10"),
      monthlyPlanE4: Fx.rub(6_000))
    let next = AnnualReserve.restarted(
      goal, spentOn: Fx.day("2027-03-09"), today: Fx.day("2027-03-12"))
    #expect(next.id != goal.id && next.name == goal.name && next.targetE4 == goal.targetE4)
    #expect(next.targetDate == Fx.day("2028-03-10"))
    // 13 months to go (March 2027 … March 2028): 12 000 / 13 rounded up to a ruble.
    #expect(next.monthlyPlanE4 == Fx.rub(924))
    #expect(
      AnnualReserve.restartMonth(goal, spentOn: Fx.day("2027-03-09"), today: Fx.day("2027-03-12"))
        == Fx.m(2028, 3))
    // A goal without a date counts from the day it was spent.
    var undated = goal
    undated.targetDate = nil
    #expect(
      AnnualReserve.restarted(undated, spentOn: Fx.day("2027-03-09"), today: Fx.day("2027-03-12"))
        .targetDate == Fx.day("2028-03-09"))
  }
}

@Suite("Property tax in November")
struct PropertyTaxTests {
  typealias Fx = YearFx

  static let taxes = Fx.id(80)

  static let records = [
    TaxRecord(
      day: Fx.day("2025-11-20"), amount: Fx.rub(8_000), categoryId: taxes, title: "Transport tax"),
    TaxRecord(
      day: Fx.day("2025-04-02"), amount: Fx.rub(3_000), categoryId: Fx.id(81), title: "Duty"),
  ]

  @Test func inNovemberLastAutumnsTaxIsOffered() throws {
    let hints = PropertyTaxHints.hints(records: Self.records, today: Fx.day("2026-11-03"))
    let hint = try #require(hints.first)
    #expect(hints.count == 1)
    #expect(hint.lastAmount == Fx.rub(8_000) && hint.title == "Transport tax")
    #expect(hint.due == Fx.day("2026-12-01"))
    #expect(hint.remindOn == Fx.day("2026-11-17"))
  }

  @Test func onlyFromTheFirstOfNovemberToTheDueDate() {
    #expect(PropertyTaxHints.hints(records: Self.records, today: Fx.day("2026-10-31")).isEmpty)
    #expect(PropertyTaxHints.hints(records: Self.records, today: Fx.day("2026-12-01")).count == 1)
    #expect(PropertyTaxHints.hints(records: Self.records, today: Fx.day("2026-12-02")).isEmpty)
  }

  @Test func noTaxLastYearNoHint() {
    let old = [TaxRecord(day: Fx.day("2024-11-20"), amount: Fx.rub(8_000), categoryId: Self.taxes)]
    #expect(PropertyTaxHints.hints(records: old, today: Fx.day("2026-11-03")).isEmpty)
    #expect(PropertyTaxHints.hints(records: [], today: Fx.day("2026-11-03")).isEmpty)
  }

  @Test func aPlannedPaymentOrADismissalSilencesIt() throws {
    let planned = ScheduledPayment(
      name: "Transport tax", amountE4: Fx.rub(8_000), categoryId: Self.taxes, freq: .yearly,
      day: 1, month: 12, nextDate: Fx.day("2026-12-01"))
    #expect(
      PropertyTaxHints.hints(records: Self.records, today: Fx.day("2026-11-03"), planned: [planned])
        .isEmpty)
    var inactive = planned
    inactive.active = false
    #expect(
      PropertyTaxHints.hints(
        records: Self.records, today: Fx.day("2026-11-03"), planned: [inactive]
      )
      .count == 1)
    let hint = try #require(
      PropertyTaxHints.hints(records: Self.records, today: Fx.day("2026-11-03")).first)
    #expect(
      PropertyTaxHints.hints(
        records: Self.records, today: Fx.day("2026-11-03"), dismissed: [hint.id]
      ).isEmpty)
  }

  @Test func planningMakesAYearlyPaymentOnTheFirstOfDecember() throws {
    let hint = try #require(
      PropertyTaxHints.hints(records: Self.records, today: Fx.day("2026-11-03")).first)
    let payment = hint.scheduledPayment()
    #expect(payment.freq == .yearly && payment.day == 1 && payment.month == 12)
    #expect(payment.nextDate == Fx.day("2026-12-01") && payment.remindDaysBefore == 14)
    #expect(payment.amountE4 == Fx.rub(8_000) && payment.categoryId == Self.taxes)
    // Next year the same payment comes on 1 December 2027.
    let rule = RecurrenceRule(payment: payment)
    #expect(Recurrence.next(after: Fx.day("2026-12-01"), rule: rule) == Fx.day("2027-12-01"))
  }

  @Test func severalPaymentsOfOneNameAddUp() throws {
    let two = [
      TaxRecord(
        day: Fx.day("2025-11-20"), amount: Fx.rub(5_000), categoryId: Self.taxes, title: "Land"),
      TaxRecord(
        day: Fx.day("2025-12-01"), amount: Fx.rub(3_000), categoryId: Self.taxes, title: "Land tax"),
    ]
    let hint = try #require(PropertyTaxHints.hints(records: two, today: Fx.day("2026-11-03")).first)
    #expect(hint.lastAmount == Fx.rub(8_000) && hint.title == "Land")
    #expect(hint.lastDate == Fx.day("2025-12-01"))
  }
}

@Suite("The week budget")
struct WeekBudgetTests {
  typealias Fx = YearFx

  /// Thursday 22 October 2026; October ends on a Saturday.
  @Test func theFreeSumIsDividedByTheWeeksLeft() {
    let week = WeekBudget.compute(freeToMonthEnd: Fx.rub(18_800), today: Fx.day("2026-10-22"))
    #expect(week.weekStart == Fx.day("2026-10-19") && week.weekEnd == Fx.day("2026-10-25"))
    #expect(week.weeksLeft == 2)
    #expect(week.perWeek == Fx.rub(9_400))
    #expect(week.daysLeftInWeek == 4)
  }

  @Test func theLastPartialWeekCountsAsOne() {
    let week = WeekBudget.compute(freeToMonthEnd: Fx.rub(3_000), today: Fx.day("2026-10-28"))
    // Week of 26 October ends on the 31st (the month's end): the last week, alone.
    #expect(week.weeksLeft == 1 && week.perWeek == Fx.rub(3_000))
    #expect(week.weekEnd == Fx.day("2026-10-31"))
  }

  @Test func theWeekFollowsTheFirstDayOfTheWeek() {
    let sunday = WeekBudget.compute(
      freeToMonthEnd: Fx.rub(100), today: Fx.day("2026-10-22"), firstWeekday: 7)
    #expect(sunday.weekStart == Fx.day("2026-10-18"))
    #expect(sunday.weeksLeft == 2)
    // A month that ends right before a week begins: 28 Feb 2027 is a Sunday.
    let february = WeekBudget.compute(freeToMonthEnd: Fx.rub(100), today: Fx.day("2027-02-24"))
    #expect(february.weeksLeft == 1)
    // Early in a long month: 1 October 2026 (Thursday) has the weeks of the 5th, 12th, 19th, 26th.
    #expect(
      WeekBudget.compute(freeToMonthEnd: Fx.rub(100), today: Fx.day("2026-10-01")).weeksLeft == 5)
  }

  @Test func theDivisionRoundsAndOverspendingShows() {
    let rounded = WeekBudget.compute(freeToMonthEnd: AmountE4(raw: 10), today: Fx.day("2026-10-22"))
    #expect(rounded.perWeek.raw == 5)
    let over = WeekBudget.compute(freeToMonthEnd: Fx.rub(-3_000), today: Fx.day("2026-10-22"))
    #expect(over.isOverspent && over.perWeek == Fx.rub(-1_500))
  }

  @Test(arguments: 1...7)
  func everyWeekStartIsOnItsWeekday(_ first: Int) {
    var day = Fx.day("2026-10-01")
    for _ in 0..<60 {
      let start = WeekBudget.weekStart(of: day, firstWeekday: first)
      #expect(start.weekday == first)
      #expect(start <= day && start.days(to: day) < 7)
      day = day.adding(days: 1)
    }
  }
}

@Suite("The month buffer")
struct MonthBufferTests {
  typealias Fx = YearFx

  @Test func theBufferIsHeldBackAndSpentByMarks() throws {
    let settings = MonthBufferSettings(amount: Fx.rub(5_000), incomeAtSet: Fx.rub(100_000))
    let fresh = try #require(MonthBuffer.state(settings: settings, used: .zero))
    #expect(fresh.left == Fx.rub(5_000) && fresh.usedBp == 0)
    #expect(MonthBuffer.freeSum(Fx.rub(40_000), state: fresh) == Fx.rub(35_000))
    // A phone repair of 4 000 marked «from the buffer»: the money is gone, the buffer is down.
    let spent = try #require(MonthBuffer.state(settings: settings, used: Fx.rub(4_000)))
    #expect(spent.left == Fx.rub(1_000) && spent.usedBp == 8_000 && !spent.isOverrun)
    // The free sum after the repair: 40 000 − 4 000 of money, buffer 1 000 held: 35 000.
    #expect(MonthBuffer.freeSum(Fx.rub(36_000), state: spent) == Fx.rub(35_000))
    let over = try #require(MonthBuffer.state(settings: settings, used: Fx.rub(6_000)))
    #expect(over.left == .zero && over.isOverrun && over.usedBp == 12_000)
  }

  @Test func zeroMeansOff() {
    #expect(MonthBuffer.state(settings: MonthBufferSettings(), used: Fx.rub(1)) == nil)
    #expect(MonthBuffer.freeSum(Fx.rub(10), state: nil) == Fx.rub(10))
    #expect(!MonthBufferSettings(amountText: "-5", incomeText: nil).isOn)
    #expect(!MonthBufferSettings(amountText: "text", incomeText: nil).isOn)
  }

  @Test func theSettingsRoundTripThroughTheirTexts() {
    let settings = MonthBufferSettings(amount: Fx.rub(5_000), incomeAtSet: Fx.rub(100_000))
    let back = MonthBufferSettings(amountText: settings.amountText, incomeText: settings.incomeText)
    #expect(back == settings)
    #expect(MonthBufferSettings().amountText == nil)
    let marks: Set<UUID> = [Fx.id(2), Fx.id(1)]
    let text = MonthBufferSettings.marksText(marks)
    #expect(MonthBufferSettings.marks(from: text) == marks)
    #expect(MonthBufferSettings.marks(from: "junk\n\(Fx.id(3))") == [Fx.id(3)])
    #expect(MonthBufferSettings.marksText([]) == nil)
  }

  @Test func incomeUpByMoreThanTenPercentOffersABiggerBuffer() {
    let settings = MonthBufferSettings(amount: Fx.rub(5_000), incomeAtSet: Fx.rub(100_000))
    #expect(MonthBuffer.raiseOffer(settings: settings, income: Fx.rub(110_000)) == nil)
    #expect(MonthBuffer.raiseOffer(settings: settings, income: Fx.rub(90_000)) == nil)
    // 125 000: the buffer in proportion, 6 250 ₽ (already a multiple of 100 ₽ steps).
    #expect(MonthBuffer.raiseOffer(settings: settings, income: Fx.rub(125_000)) == Fx.rub(6_300))
    #expect(MonthBuffer.raiseOffer(settings: settings, income: Fx.rub(111_000)) == Fx.rub(5_600))
    // No income noted, or the buffer off: no offer.
    #expect(
      MonthBuffer.raiseOffer(
        settings: MonthBufferSettings(amount: Fx.rub(5_000)), income: Fx.rub(1_000_000)) == nil)
    #expect(MonthBuffer.raiseOffer(settings: MonthBufferSettings(), income: Fx.rub(1)) == nil)
  }

  @Test func answeringNotesTheIncomeEitherWay() {
    let settings = MonthBufferSettings(amount: Fx.rub(5_000), incomeAtSet: Fx.rub(100_000))
    let yes = MonthBuffer.answered(
      settings: settings, income: Fx.rub(125_000), newAmount: Fx.rub(6_300))
    #expect(yes.amount == Fx.rub(6_300) && yes.incomeAtSet == Fx.rub(125_000))
    let no = MonthBuffer.answered(settings: settings, income: Fx.rub(125_000), newAmount: nil)
    #expect(no.amount == Fx.rub(5_000) && no.incomeAtSet == Fx.rub(125_000))
    #expect(MonthBuffer.raiseOffer(settings: no, income: Fx.rub(125_000)) == nil)
  }
}
