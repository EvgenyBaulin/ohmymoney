import AppCore
import XCTest

@testable import OhMyMoney

/// A year of a self-employed person: income from individuals and organisations, the
/// deduction running out, a tax below the 100-ruble minimum carried to the next month, a return
/// to a client after the month of the income, the tax paid with its month's key and without it,
/// income in dollars at the Bank of Russia rate of its day, the yearly limit, a simplified tax
/// paid by the quarter, December's tax due in January, and the settings read back from rows.
final class PlanningScenarioTestsSelfEmployment: XCTestCase {
  private typealias S = PlanningScenario

  private let taxes = CoreKit.Category(kind: .expense, name: "Налоги и сборы")
  private let returns = CoreKit.Category(kind: .expense, name: "Возврат клиенту")
  private let selfEmployed = CoreKit.Category(
    kind: .income, name: "Самозанятость", tax: IncomeTax(rate: 4, npd: true))
  private lazy var individuals = CoreKit.Category(
    parentId: selfEmployed.id, kind: .income, name: "от физлиц")
  private let organisations = CoreKit.Category(
    kind: .income, name: "от организаций", tax: IncomeTax(rate: 6, npd: true))
  private let simplified = CoreKit.Category(
    kind: .income, name: "УСН", tax: IncomeTax(rate: 6, npd: false))
  private let salary = CoreKit.Category(kind: .income, name: "Зарплата")

  private var tree: CategoryTree {
    CategoryTree([taxes, returns, selfEmployed, individuals, organisations, simplified, salary])
  }

  private func settings(
    deduction: AmountE4? = nil, since: String? = nil, overrides: NPDOverrides = .none,
    enabled: Bool = true
  ) -> SelfEmploymentSettings {
    SelfEmploymentSettings(
      enabled: enabled, deductionLeftE4: deduction, deductionLeftOn: since.map(S.day),
      taxCategoryId: taxes.id, returnCategoryId: returns.id, overrides: overrides)
  }

  private func state(
    _ entries: [TransactionEntry], today: String,
    settings: SelfEmploymentSettings? = nil, rates: DayRates = .empty
  ) -> NPDState {
    NPDTax.state(
      ledger: S.ledger(
        entries,
        categories: [
          taxes, returns, selfEmployed, individuals, organisations, simplified, salary,
        ]),
      tree: tree, settings: settings ?? self.settings(), dayRates: rates, today: S.day(today))
  }

  private func income(
    _ whole: Int64, _ day: String, _ category: CoreKit.Category? = nil
  )
    -> TransactionEntry
  {
    S.entry(.income, S.rub(whole), on: day, category: (category ?? individuals).id)
  }

  private func month(_ state: NPDState, _ iso: String) -> NPDMonth? {
    state.months.first { $0.month == MonthKey(iso: iso)! }
  }

  // MARK: Off and nothing

  func testSwitchedOffNothingIsCounted() {
    let result = state(
      [income(100_000, "2026-09-10")], today: "2026-10-14", settings: settings(enabled: false))
    XCTAssertTrue(result.months.isEmpty)
    XCTAssertEqual(result.accruedUnpaidE4, .zero)
    XCTAssertEqual(result.year.year, 2026)
  }

  func testASalaryWithoutATaxIsNotSelfEmployment() {
    let result = state([income(80_000, "2026-09-10", salary)], today: "2026-10-14")
    XCTAssertTrue(result.months.isEmpty)
    XCTAssertEqual(result.year.incomeRub, .zero)
  }

  // MARK: The tax of a month

  func testAnIncomeFromIndividualsOwesFourPercentByThe28thOfTheNextMonth() throws {
    let result = state([income(10_000, "2026-09-10")], today: "2026-10-14")
    let september = try XCTUnwrap(month(result, "2026-09"))
    XCTAssertEqual(september.taxE4, S.rub(400))
    XCTAssertEqual(september.toPayE4, S.rub(400))
    XCTAssertEqual(september.due, S.day("2026-10-28"))
    XCTAssertEqual(september.state, .due)
    XCTAssertEqual(result.nextDue?.month, MonthKey(iso: "2026-09"))
    XCTAssertEqual(result.accruedUnpaidE4, S.rub(400))
  }

  func testTheSubcategoryTakesTheRateOfItsParent() {
    XCTAssertEqual(tree.tax(of: individuals.id), IncomeTax(rate: 4, npd: true))
  }

  func testTheDayAfterTheDueDayTheMonthIsOverdue() throws {
    let result = state([income(10_000, "2026-09-10")], today: "2026-10-29")
    XCTAssertEqual(try XCTUnwrap(month(result, "2026-09")).state, .overdue)
  }

  func testOnTheDueDayItselfTheMonthIsStillDue() throws {
    let result = state([income(10_000, "2026-09-10")], today: "2026-10-28")
    XCTAssertEqual(try XCTUnwrap(month(result, "2026-09")).state, .due)
  }

  func testIncomeFromOrganisationsOwesSixPercent() throws {
    let result = state([income(10_000, "2026-09-10", organisations)], today: "2026-10-14")
    XCTAssertEqual(try XCTUnwrap(month(result, "2026-09")).taxE4, S.rub(600))
  }

  func testTheMonthUnderWayIsAccruing() throws {
    let result = state([income(10_000, "2026-10-01")], today: "2026-10-14")
    let october = try XCTUnwrap(month(result, "2026-10"))
    XCTAssertEqual(october.state, .accruing)
    XCTAssertEqual(october.toPayE4, S.rub(400))
    XCTAssertNil(result.nextDue)
    XCTAssertEqual(result.accruedUnpaidE4, S.rub(400))
  }

  func testDecembersTaxIsDueInJanuaryOfTheNextYear() throws {
    let result = state([income(10_000, "2026-12-31")], today: "2027-01-05")
    XCTAssertEqual(try XCTUnwrap(month(result, "2026-12")).due, S.day("2027-01-28"))
  }

  func testKopecksAreRoundedOnceForTheMonth() throws {
    // 3 × 33.33 ₽ = 99.99 ₽ at 4 % = 3.9996 → 4.00 ₽, not three times 1.33.
    let entries = (1...3).map { index in
      S.entry(.income, S.kop(3_333), on: "2026-10-0\(index)", category: individuals.id)
    }
    let result = state(entries, today: "2026-10-14")
    XCTAssertEqual(try XCTUnwrap(month(result, "2026-10")).taxE4, S.kop(400))
  }

  // MARK: Below the minimum

  func testATaxBelowAHundredRublesGoesOnToTheNextMonth() throws {
    let result = state(
      [income(2_000, "2026-09-10"), income(1_000, "2026-10-10")], today: "2026-11-14")
    let september = try XCTUnwrap(month(result, "2026-09"))
    XCTAssertEqual(september.state, .carried)
    XCTAssertEqual(september.toPayE4, .zero)
    let october = try XCTUnwrap(month(result, "2026-10"))
    XCTAssertEqual(october.carriedInE4, S.rub(80))
    XCTAssertEqual(october.toPayE4, S.rub(120))
    XCTAssertEqual(october.state, .due)
  }

  func testACarriedTaxWaitsInTheMonthUnderWayEvenWithoutIncome() throws {
    let result = state([income(2_000, "2026-09-10")], today: "2026-10-14")
    let october = try XCTUnwrap(month(result, "2026-10"))
    XCTAssertEqual(october.state, .accruing)
    XCTAssertEqual(october.carriedInE4, S.rub(80))
    XCTAssertEqual(result.accruedUnpaidE4, S.rub(80))
  }

  func testWithAZeroMinimumEvenASmallTaxIsDue() throws {
    let result = state(
      [income(1_000, "2026-09-10")], today: "2026-10-14",
      settings: settings(overrides: NPDOverrides(minimumTaxE4: .zero)))
    XCTAssertEqual(try XCTUnwrap(month(result, "2026-09")).state, .due)
  }

  func testADueDayOf31InFebruaryIsItsLastDay() throws {
    let custom = settings(overrides: NPDOverrides(dueDay: 31))
    let common = state([income(10_000, "2027-01-10")], today: "2027-02-01", settings: custom)
    XCTAssertEqual(try XCTUnwrap(month(common, "2027-01")).due, S.day("2027-02-28"))
    let leap = state([income(10_000, "2028-01-10")], today: "2028-02-01", settings: custom)
    XCTAssertEqual(try XCTUnwrap(month(leap, "2028-01")).due, S.day("2028-02-29"))
  }

  // MARK: The deduction

  func testTheDeductionTakesAPointOffIndividuals() throws {
    let result = state(
      [income(10_000, "2026-09-10")], today: "2026-10-14",
      settings: settings(deduction: S.rub(10_000)))
    let september = try XCTUnwrap(month(result, "2026-09"))
    XCTAssertEqual(september.taxBeforeDeductionE4, S.rub(400))
    XCTAssertEqual(september.deductionUsedE4, S.rub(100))
    XCTAssertEqual(september.taxE4, S.rub(300))
    XCTAssertEqual(result.deductionLeftE4, S.rub(9_900))
  }

  func testTheDeductionTakesTwoPointsOffOrganisations() throws {
    let result = state(
      [income(10_000, "2026-09-10", organisations)], today: "2026-10-14",
      settings: settings(deduction: S.rub(10_000)))
    XCTAssertEqual(try XCTUnwrap(month(result, "2026-09")).taxE4, S.rub(400))
  }

  func testIncomeBeforeTheDayTheOwnerToldTheDeductionHasNone() throws {
    let result = state(
      [income(10_000, "2026-09-10")], today: "2026-10-14",
      settings: settings(deduction: S.rub(10_000), since: "2026-09-10"))
    XCTAssertEqual(try XCTUnwrap(month(result, "2026-09")).taxE4, S.rub(400))
    XCTAssertEqual(result.deductionLeftE4, S.rub(10_000))
  }

  func testTheLastRublesOfTheDeductionAreUsedAndNoMore() throws {
    let result = state(
      [income(10_000, "2026-09-10")], today: "2026-10-14",
      settings: settings(deduction: S.rub(30)))
    XCTAssertEqual(try XCTUnwrap(month(result, "2026-09")).taxE4, S.rub(370))
    XCTAssertEqual(result.deductionLeftE4, .zero)
  }

  func testWithoutTheOwnersAnswerNoDeductionIsCounted() throws {
    let result = state([income(10_000, "2026-09-10")], today: "2026-10-14")
    XCTAssertNil(result.deductionLeftE4)
    XCTAssertEqual(try XCTUnwrap(month(result, "2026-09")).deductionUsedE4, .zero)
  }

  // MARK: Returns to a client

  func testAReturnTakesItsRublesOffTheMonthItIsMadeIn() throws {
    let result = state(
      [
        income(10_000, "2026-10-01"),
        S.entry(.expense, S.rub(3_000), on: "2026-10-05", category: returns.id),
      ], today: "2026-10-14")
    let october = try XCTUnwrap(month(result, "2026-10"))
    XCTAssertEqual(october.returnsRub, S.rub(3_000))
    XCTAssertEqual(october.baseRub, S.rub(7_000))
    XCTAssertEqual(october.taxE4, S.rub(280))
  }

  func testAReturnLargerThanTheMonthGoesOnToTheNext() throws {
    let result = state(
      [
        income(10_000, "2026-10-01"),
        S.entry(.expense, S.rub(15_000), on: "2026-10-05", category: returns.id),
        income(10_000, "2026-11-01"),
      ], today: "2026-12-14")
    XCTAssertEqual(try XCTUnwrap(month(result, "2026-10")).baseRub, .zero)
    XCTAssertEqual(try XCTUnwrap(month(result, "2026-11")).baseRub, S.rub(5_000))
    XCTAssertEqual(try XCTUnwrap(month(result, "2026-11")).taxE4, S.rub(200))
  }

  func testAReturnComesOffIndividualsBeforeOrganisations() throws {
    let result = state(
      [
        income(5_000, "2026-10-01"),
        income(10_000, "2026-10-02", organisations),
        S.entry(.expense, S.rub(5_000), on: "2026-10-05", category: returns.id),
      ], today: "2026-10-14")
    // Only the organisations' 10,000 ₽ at 6 % is left.
    XCTAssertEqual(try XCTUnwrap(month(result, "2026-10")).taxE4, S.rub(600))
  }

  // MARK: Paying

  func testAPaymentWithTheMonthsKeyPaysThatMonth() throws {
    let result = state(
      [
        income(10_000, "2026-09-10"),
        S.entry(
          .expense, S.rub(400), on: "2026-10-20", category: taxes.id,
          externalId: NPDTax.paymentKey(month: MonthKey(iso: "2026-09")!)),
      ], today: "2026-10-29")
    let september = try XCTUnwrap(month(result, "2026-09"))
    XCTAssertEqual(september.state, .paid)
    XCTAssertNil(september.fnsGapE4)
    XCTAssertEqual(result.accruedUnpaidE4, .zero)
    XCTAssertNil(result.nextDue)
  }

  func testWhatTheTaxOfficeChargedLessIsTheGap() throws {
    let result = state(
      [
        income(10_000, "2026-09-10"),
        S.entry(.expense, S.rub(390), on: "2026-10-20", category: taxes.id),
      ], today: "2026-10-29")
    XCTAssertEqual(try XCTUnwrap(month(result, "2026-09")).fnsGapE4, S.rub(-10))
  }

  func testAPaymentWithoutAKeyPaysTheEarliestMonthOverAndUnpaid() throws {
    let result = state(
      [
        income(10_000, "2026-08-10"), income(10_000, "2026-09-10"),
        S.entry(.expense, S.rub(400), on: "2026-10-01", category: taxes.id),
      ], today: "2026-10-14")
    XCTAssertEqual(try XCTUnwrap(month(result, "2026-08")).state, .paid)
    XCTAssertNotEqual(try XCTUnwrap(month(result, "2026-09")).state, .paid)
  }

  func testAPaymentInsideTheMonthDoesNotPayThatMonth() throws {
    let result = state(
      [
        income(10_000, "2026-10-01"),
        S.entry(.expense, S.rub(400), on: "2026-10-05", category: taxes.id),
      ], today: "2026-10-14")
    XCTAssertEqual(try XCTUnwrap(month(result, "2026-10")).state, .accruing)
  }

  func testAKeyOfAMonthWithoutIncomePaysNothing() throws {
    let result = state(
      [
        income(10_000, "2026-09-10"),
        S.entry(
          .expense, S.rub(400), on: "2026-10-20", category: taxes.id,
          externalId: "npd:2026-05"),
      ], today: "2026-10-29")
    XCTAssertEqual(try XCTUnwrap(month(result, "2026-09")).state, .overdue)
  }

  func testKeysThatDoNotReadPayNoMonth() {
    XCTAssertEqual(NPDTax.paidMonth("npd:2026-09"), MonthKey(iso: "2026-09"))
    XCTAssertNil(NPDTax.paidMonth("npd:2026-9"))
    XCTAssertNil(NPDTax.paidMonth("npd:26-09"))
    XCTAssertNil(NPDTax.paidMonth("tax:2026-Q1"))
    XCTAssertNil(NPDTax.paidMonth(nil))
    XCTAssertEqual(NPDTax.paidQuarter("tax:2026-Q4")?.quarter, 4)
    XCTAssertNil(NPDTax.paidQuarter("tax:2026-Q5"))
    XCTAssertNil(NPDTax.paidQuarter("tax:26-Q1"))
    XCTAssertNil(NPDTax.paidQuarter("tax:2026-4"))
    XCTAssertEqual(NPDTax.paymentKey(year: 2026, quarter: 3), "tax:2026-Q3")
  }

  // MARK: Dollars

  func testADollarIncomeCountsAtTheRateOfItsDay() throws {
    let rates = DayRates(series: [.usd: [DayRate(day: S.day("2026-09-10"), perUnit: 95)]])
    let dollars = S.entry(
      .income, S.rub(100), on: "2026-09-10", category: individuals.id, currency: .usd,
      rubles: S.rub(9_000))
    let result = state([dollars], today: "2026-10-14", rates: rates)
    XCTAssertEqual(try XCTUnwrap(month(result, "2026-09")).baseRub, S.rub(9_500))
    XCTAssertEqual(try XCTUnwrap(month(result, "2026-09")).taxE4, S.rub(380))
  }

  func testADollarIncomeWithoutARateCountsAtItsOwnRubles() throws {
    let dollars = S.entry(
      .income, S.rub(100), on: "2026-09-10", category: individuals.id, currency: .usd,
      rubles: S.rub(9_000))
    let result = state([dollars], today: "2026-10-14")
    XCTAssertEqual(try XCTUnwrap(month(result, "2026-09")).baseRub, S.rub(9_000))
  }

  // MARK: The year

  func testTheYearOverTheLimitIsExceeded() {
    let result = state([income(2_500_000, "2026-02-10")], today: "2026-10-14")
    XCTAssertTrue(result.year.exceeded)
    XCTAssertEqual(result.year.leftRub, .zero)
    XCTAssertEqual(result.year.shareBp, 10_416)
  }

  func testLastYearsIncomeIsNotThisYearsLimit() {
    let result = state([income(1_000_000, "2025-12-20")], today: "2026-01-10")
    XCTAssertEqual(result.year.year, 2026)
    XCTAssertEqual(result.year.incomeRub, .zero)
    XCTAssertEqual(result.year.leftRub, NPDReference.law.yearLimitE4)
  }

  func testAYearLimitTheOwnerCorrected() {
    let result = state(
      [income(500_000, "2026-03-10")], today: "2026-10-14",
      settings: settings(overrides: NPDOverrides(yearLimitE4: S.rub(1_000_000))))
    XCTAssertEqual(result.year.shareBp, 5_000)
    XCTAssertEqual(result.year.leftRub, S.rub(500_000))
  }

  // MARK: The simplified tax by the quarter

  func testASimplifiedTaxIsPaidByTheQuarter() throws {
    let result = state(
      [income(100_000, "2026-07-10", simplified), income(50_000, "2026-08-10", simplified)],
      today: "2026-10-14")
    XCTAssertTrue(result.months.isEmpty)
    let third = try XCTUnwrap(result.quarters.first)
    XCTAssertEqual(third.quarter, 3)
    XCTAssertEqual(third.baseRub, S.rub(150_000))
    XCTAssertEqual(third.toPayE4, S.rub(9_000))
    XCTAssertEqual(third.due, S.day("2026-10-28"))
    XCTAssertEqual(third.state, .due)
    XCTAssertEqual(result.accruedUnpaidE4, S.rub(9_000))
  }

  func testTheQuarterKeyPaysItsQuarter() throws {
    let result = state(
      [
        income(100_000, "2026-07-10", simplified),
        S.entry(
          .expense, S.rub(6_000), on: "2026-10-20", category: taxes.id,
          externalId: NPDTax.paymentKey(year: 2026, quarter: 3)),
      ], today: "2026-10-29")
    XCTAssertEqual(try XCTUnwrap(result.quarters.first).state, .paid)
    XCTAssertEqual(result.accruedUnpaidE4, .zero)
  }

  func testTheFourthQuarterIsDueInJanuary() {
    XCTAssertEqual(NPDTax.dueDay(ofQuarter: 4, year: 2026), S.day("2027-01-28"))
    XCTAssertEqual(TaxQuarter(of: MonthKey(iso: "2026-12")!).quarter, 4)
    XCTAssertEqual(TaxQuarter(of: MonthKey(iso: "2026-01")!).firstMonth, MonthKey(iso: "2026-01"))
  }

  func testTheQuarterUnderWayIsAccruing() throws {
    let result = state([income(100_000, "2026-10-02", simplified)], today: "2026-10-14")
    XCTAssertEqual(try XCTUnwrap(result.quarters.first).state, .accruing)
  }

  // MARK: The tax of one income

  func testTheTaxOfOneIncomeShowsTheRateAfterTheDeduction() throws {
    let entry = income(10_000, "2026-10-10")
    let covered = try XCTUnwrap(
      NPDTax.tax(
        of: entry, tree: tree, settings: settings(), dayRates: .empty,
        deductionLeft: S.rub(1_000)))
    XCTAssertEqual(covered.taxE4, S.rub(300))
    XCTAssertEqual(covered.rate, 3)
    let partly = try XCTUnwrap(
      NPDTax.tax(
        of: entry, tree: tree, settings: settings(), dayRates: .empty, deductionLeft: S.rub(40)))
    XCTAssertEqual(partly.taxE4, S.rub(360))
    XCTAssertEqual(partly.rate, 4)
  }

  func testAnExpenseOrASalaryHasNoTax() {
    XCTAssertNil(
      NPDTax.tax(
        of: income(1_000, "2026-10-10", salary), tree: tree, settings: settings(),
        dayRates: .empty, deductionLeft: nil))
    XCTAssertNil(
      NPDTax.tax(
        of: S.entry(.expense, S.rub(1_000), on: "2026-10-10", category: individuals.id),
        tree: tree, settings: settings(), dayRates: .empty, deductionLeft: nil))
    XCTAssertNil(
      NPDTax.tax(
        of: income(1_000, "2026-10-10"), tree: tree, settings: settings(enabled: false),
        dayRates: .empty, deductionLeft: nil))
  }

  // MARK: Settings rows

  func testTheSettingsReadBackFromTheirRows() {
    let written = SelfEmploymentSettings(
      enabled: true, offered: true, deductionLeftE4: S.kop(456_789),
      deductionLeftOn: S.day("2028-02-29"), taxAccountId: UUID(), taxCategoryId: taxes.id,
      returnCategoryId: returns.id,
      overrides: NPDOverrides(
        individualsRate: Decimal(string: "3.5"), dueDay: 25, minimumTaxE4: S.rub(50),
        remindDaysBefore: 0))
    let rows = written.storedValues.compactMapValues { $0 }
    XCTAssertEqual(SelfEmploymentSettings(storedValues: rows), written)
  }

  func testDamagedRowsKeepTheirDefaults() {
    let read = SelfEmploymentSettings(storedValues: [
      SelfEmploymentSettings.enabledKey: "true",
      SelfEmploymentSettings.deductionLeftKey: "-5",
      SelfEmploymentSettings.deductionLeftOnKey: "2027-02-29",
      SelfEmploymentSettings.dueDayKey: "40",
      SelfEmploymentSettings.yearLimitKey: "0",
      SelfEmploymentSettings.remindDaysKey: "abc",
      SelfEmploymentSettings.taxCategoryKey: "not-a-uuid",
    ])
    XCTAssertTrue(read.enabled)
    XCTAssertNil(read.deductionLeftE4)
    XCTAssertNil(read.deductionLeftOn)
    XCTAssertEqual(read.overrides, .none)
    XCTAssertNil(read.taxCategoryId)
    XCTAssertEqual(read.reference, NPDReference.law)
  }

  func testSwitchedOffSettingsDeleteTheirKeys() {
    let rows = SelfEmploymentSettings.standard.storedValues
    XCTAssertEqual(Set(rows.keys), Set(SelfEmploymentSettings.storageKeys))
    XCTAssertTrue(rows.values.allSatisfy { $0 == nil })
  }
}
