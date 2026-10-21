import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CorePlanning

@Suite("The tax of self-employment")
struct NPDTaxTests {
  typealias B = B3Book

  /// «Заработок → Самозанятость → от физлиц (4 %) / от организаций (6 %)», the tax category and
  /// the category of returns.
  struct Setup {
    var book = B3Book()
    var individuals = UUID()
    var organizations = UUID()
    var taxCategory = UUID()
    var returns = UUID()

    init(deductionLeft: String? = nil, on day: DateOnly? = nil) {
      let earnings = book.category("Заработок", kind: .income)
      let selfEmployed = book.category("Самозанятость", kind: .income, parent: earnings)
      individuals = book.category(
        "от физлиц", kind: .income, parent: selfEmployed, tax: IncomeTax(rate: 4, npd: true))
      organizations = book.category(
        "от организаций", kind: .income, parent: selfEmployed, tax: IncomeTax(rate: 6, npd: true))
      let taxes = book.category("Налоги и сборы", kind: .expense)
      taxCategory = book.category("Налог самозанятого", kind: .expense, parent: taxes)
      returns = book.category("Возврат клиенту", kind: .expense)
      book.selfEmployment = SelfEmploymentSettings(
        enabled: true, deductionLeftE4: deductionLeft.map(B.rub), deductionLeftOn: day,
        taxCategoryId: taxCategory, returnCategoryId: returns)
    }

    func state(today: DateOnly, rates: DayRates = .empty) -> NPDState {
      NPDTax.state(
        ledger: book.ledger, tree: book.ledger.tree, settings: book.selfEmployment,
        dayRates: rates, today: today)
    }
  }

  @Test func theDeductionCutsFourToThreeAndSixToFour() {
    var setup = Setup(deductionLeft: "10000", on: B.day(9, 30))
    setup.book.operation(.income, "6000", on: B.day(10, 5), category: setup.individuals)
    setup.book.operation(.income, "50000", on: B.day(10, 12), category: setup.organizations)
    let state = setup.state(today: B.day(11, 2))
    let october = state.months.first { $0.month == MonthKey(year: 2026, month: 10) }
    #expect(october?.taxBeforeDeductionE4 == B.rub("3240"))
    #expect(october?.deductionUsedE4 == B.rub("1060"))
    #expect(october?.taxE4 == B.rub("2180"))
    #expect(october?.toPayE4 == B.rub("2180"))
    #expect(october?.due == B.day(11, 28))
    #expect(october?.state == .due)
    #expect(state.deductionLeftE4 == B.rub("8940"))
    #expect(state.nextDue?.month == MonthKey(year: 2026, month: 10))
    #expect(state.accruedUnpaidE4 == B.rub("2180"))
  }

  @Test func withoutAnAnswerAboutTheDeductionTheFullRate() {
    var setup = Setup()
    setup.book.operation(.income, "6000", on: B.day(10, 5), category: setup.individuals)
    setup.book.operation(.income, "50000", on: B.day(10, 12), category: setup.organizations)
    let october = setup.state(today: B.day(11, 2)).months.first
    #expect(october?.taxE4 == B.rub("3240"))
    #expect(october?.deductionUsedE4 == .zero)
  }

  @Test func aTaxBelowAHundredGoesOnToTheNextMonth() {
    var setup = Setup()
    setup.book.operation(.income, "2000", on: B.day(9, 5), category: setup.individuals)
    setup.book.operation(.income, "10000", on: B.day(10, 5), category: setup.individuals)
    let state = setup.state(today: B.day(11, 3))
    let september = state.months.first { $0.month.month == 9 }
    let october = state.months.first { $0.month.month == 10 }
    #expect(september?.taxE4 == B.rub("80"))
    #expect(september?.state == .carried)
    #expect(september?.toPayE4 == .zero)
    #expect(october?.carriedInE4 == B.rub("80"))
    #expect(october?.toPayE4 == B.rub("480"))
    #expect(state.accruedUnpaidE4 == B.rub("480"))
  }

  @Test func aForeignIncomeCountsAtTheRateOfItsDay() {
    var setup = Setup()
    // Written at 90, the Bank of Russia said 95 that day.
    setup.book.operation(
      .income, "500", on: B.day(10, 7), category: setup.individuals, currency: .usd,
      rub: "45000")
    let rates = DayRates(series: [.usd: [DayRate(day: B.day(10, 7), perUnit: 95)]])
    let october = setup.state(today: B.day(10, 20), rates: rates).months.first
    #expect(october?.incomeRub == B.rub("47500"))
    #expect(october?.taxE4 == B.rub("1900"))
    #expect(october?.state == .accruing)
  }

  @Test func aReturnInALaterMonthLowersTheBaseOfThatMonth() {
    var setup = Setup()
    setup.book.operation(.income, "20000", on: B.day(9, 5), category: setup.individuals)
    setup.book.operation(.income, "30000", on: B.day(10, 5), category: setup.individuals)
    setup.book.operation(.expense, "10000", on: B.day(10, 9), category: setup.returns)
    let state = setup.state(today: B.day(10, 20))
    let september = state.months.first { $0.month.month == 9 }
    let october = state.months.first { $0.month.month == 10 }
    #expect(september?.taxE4 == B.rub("800"))
    #expect(october?.returnsRub == B.rub("10000"))
    #expect(october?.baseRub == B.rub("20000"))
    #expect(october?.taxE4 == B.rub("800"))
  }

  @Test func aPaymentWithAKeyClosesItsMonthAndTellsTheGap() {
    var setup = Setup(deductionLeft: "10000", on: B.day(9, 30))
    setup.book.operation(.income, "6000", on: B.day(10, 5), category: setup.individuals)
    setup.book.operation(.income, "50000", on: B.day(10, 12), category: setup.organizations)
    setup.book.operation(
      .expense, "2178", on: B.day(11, 20), category: setup.taxCategory,
      externalId: NPDTax.paymentKey(month: MonthKey(year: 2026, month: 10)))
    let state = setup.state(today: B.day(11, 22))
    let october = state.months.first { $0.month.month == 10 }
    #expect(october?.state == .paid)
    #expect(october?.paidE4 == B.rub("2178"))
    #expect(october?.fnsGapE4 == B.rub("-2"))
    #expect(state.nextDue == nil)
  }

  @Test func aPaymentWithoutAKeyPaysTheEarliestMonth() {
    var setup = Setup()
    setup.book.operation(.income, "10000", on: B.day(8, 5), category: setup.individuals)
    setup.book.operation(.income, "10000", on: B.day(9, 5), category: setup.individuals)
    setup.book.operation(.expense, "400", on: B.day(10, 1), category: setup.taxCategory)
    let state = setup.state(today: B.day(10, 2))
    #expect(state.months.first { $0.month.month == 8 }?.state == .paid)
    #expect(state.months.first { $0.month.month == 9 }?.state == .due)
    #expect(state.months.first { $0.month.month == 8 }?.state != .overdue)
  }

  @Test func overdueAfterTheDueDay() {
    var setup = Setup()
    setup.book.operation(.income, "10000", on: B.day(8, 5), category: setup.individuals)
    let state = setup.state(today: B.day(9, 29))
    #expect(state.months.first?.state == .overdue)
  }

  @Test func theYearAgainstItsLimit() {
    var setup = Setup()
    setup.book.operation(.income, "2150000", on: B.day(3, 5), category: setup.organizations)
    let state = setup.state(today: B.day(10, 1))
    #expect(state.year.leftRub == B.rub("250000"))
    #expect(state.year.shareBp == 8958)
    #expect(!state.year.exceeded)
    setup.book.operation(.income, "300000", on: B.day(9, 5), category: setup.organizations)
    let over = setup.state(today: B.day(10, 1))
    #expect(over.year.exceeded)
    #expect(over.year.leftRub == .zero)
  }

  @Test func offCountsNothing() {
    var setup = Setup()
    setup.book.selfEmployment.enabled = false
    setup.book.operation(.income, "10000", on: B.day(10, 5), category: setup.individuals)
    #expect(setup.state(today: B.day(10, 9)) == .empty(today: B.day(10, 9)))
  }

  @Test func anotherRateHasNeitherTheDeductionNorTheMinimum() {
    var setup = Setup(deductionLeft: "10000", on: B.day(1, 1))
    let usn = setup.book.category(
      "УСН", kind: .income, tax: IncomeTax(rate: 6, npd: false))
    setup.book.operation(.income, "1000", on: B.day(9, 5), category: usn)
    let state = setup.state(today: B.day(10, 2))
    // Not a month of the tax on professional income: the quarter's.
    #expect(state.months.isEmpty)
    #expect(state.nextDue == nil)
    let third = state.quarters.first
    #expect(third?.quarter == 3)
    #expect(third?.toPayE4 == B.rub("60"))
    #expect(third?.state == .due)
    #expect(third?.due == B.day(10, 28))
    #expect(state.year.incomeRub == .zero)
    #expect(state.accruedUnpaidE4 == B.rub("60"))
  }

  /// УСН 6 %: the income of the three months of a quarter, taxed once, due on the 28th of the
  /// month after it; the tax on professional income stays monthly beside it.
  @Test func anotherRateIsPaidByTheQuarter() {
    var setup = Setup()
    let usn = setup.book.category("УСН", kind: .income, tax: IncomeTax(rate: 6, npd: false))
    setup.book.operation(.income, "100000", on: B.day(7, 10), category: usn)
    setup.book.operation(.income, "50000.55", on: B.day(8, 10), category: usn)
    setup.book.operation(.income, "20000", on: B.day(9, 10), category: usn)
    setup.book.operation(.income, "10000", on: B.day(9, 12), category: setup.individuals)
    setup.book.operation(.income, "30000", on: B.day(10, 3), category: usn)
    let state = setup.state(today: B.day(10, 5))

    // The tax on professional income alone in its month.
    let september = state.months.first { $0.month.month == 9 }
    #expect(september?.toPayE4 == B.rub("400"))
    #expect(september?.taxE4 == B.rub("400"))
    #expect(september?.due == B.day(10, 28))
    #expect(state.months.allSatisfy { $0.month.month >= 9 })

    let third = state.quarters.first { $0.quarter == 3 }
    // 170,000.55 × 6 % = 10,200.033 → 10,200.03, one rounding.
    #expect(third?.baseRub == B.rub("170000.55"))
    #expect(third?.toPayE4 == B.rub("10200.03"))
    #expect(third?.due == B.day(10, 28))
    #expect(third?.state == .due)
    #expect(third?.firstMonth == MonthKey(year: 2026, month: 7))
    let fourth = state.quarters.first { $0.quarter == 4 }
    #expect(fourth?.toPayE4 == B.rub("1800"))
    #expect(fourth?.state == .accruing)
    #expect(fourth?.due == DateOnly(year: 2027, month: 1, day: 28))
    #expect(state.accruedUnpaidE4 == B.rub("400") + B.rub("10200.03") + B.rub("1800"))

    let late = setup.state(today: B.day(10, 29))
    #expect(late.quarters.first { $0.quarter == 3 }?.state == .overdue)
  }

  /// «Заплатить…» of a quarter: `tax:<year>-Q<n>` pays it whatever it comes to; a payment in the
  /// tax category without a key pays the earliest month or quarter over by its due day.
  @Test func aPaymentClosesTheQuarter() {
    var setup = Setup()
    let usn = setup.book.category("УСН", kind: .income, tax: IncomeTax(rate: 6, npd: false))
    setup.book.operation(.income, "100000", on: B.day(7, 10), category: usn)
    setup.book.operation(.income, "10000", on: B.day(9, 12), category: setup.individuals)
    setup.book.operation(
      .expense, "6001", on: B.day(10, 20), category: setup.taxCategory,
      externalId: NPDTax.paymentKey(year: 2026, quarter: 3))
    let state = setup.state(today: B.day(10, 21))
    let third = state.quarters.first { $0.quarter == 3 }
    #expect(third?.state == .paid)
    #expect(third?.fnsGapE4 == B.rub("1"))
    #expect(state.months.first { $0.month.month == 9 }?.state == .due)
    #expect(state.accruedUnpaidE4 == B.rub("400"))

    // Without a key: the September tax is due on 28 October, the quarter too — the month
    // goes first on a tie, then the quarter.
    var plain = Setup()
    let usn2 = plain.book.category("УСН", kind: .income, tax: IncomeTax(rate: 6, npd: false))
    plain.book.operation(.income, "100000", on: B.day(7, 10), category: usn2)
    plain.book.operation(.income, "10000", on: B.day(9, 12), category: plain.individuals)
    plain.book.operation(.expense, "400", on: B.day(10, 20), category: plain.taxCategory)
    plain.book.operation(.expense, "6000", on: B.day(10, 21), category: plain.taxCategory)
    let paid = plain.state(today: B.day(10, 22))
    #expect(paid.months.first { $0.month.month == 9 }?.state == .paid)
    #expect(paid.quarters.first { $0.quarter == 3 }?.state == .paid)
    #expect(paid.accruedUnpaidE4 == .zero)
  }

  @Test func theTaxOfOneIncome() {
    var setup = Setup()
    let income = setup.book.operation(
      .income, "6000", on: B.day(10, 5), category: setup.individuals)
    let entry = setup.book.entries.first { $0.id == income }!
    let tax = NPDTax.tax(
      of: entry, tree: setup.book.ledger.tree, settings: setup.book.selfEmployment,
      dayRates: .empty, deductionLeft: nil)
    #expect(tax?.taxE4 == B.rub("240"))
    #expect(tax?.rate == 4)
    let cut = NPDTax.tax(
      of: entry, tree: setup.book.ledger.tree, settings: setup.book.selfEmployment,
      dayRates: .empty, deductionLeft: B.rub("10000"))
    #expect(cut?.taxE4 == B.rub("180"))
    #expect(cut?.rate == 3)
  }

  @Test func theBlock() {
    var setup = Setup()
    setup.book.operation(.income, "10000", on: B.day(9, 5), category: setup.individuals)
    setup.book.operation(.income, "5000", on: B.day(10, 5), category: setup.individuals)
    let block = SelfEmploymentBlock.build(
      npd: setup.state(today: B.day(10, 9)), today: B.day(10, 9))
    #expect(block?.monthIncomeRub == B.rub("5000"))
    #expect(block?.taxToPayE4 == B.rub("400"))
    #expect(block?.due == B.day(10, 28))
    #expect(SelfEmploymentBlock.build(npd: nil, today: B.day(10, 9)) == nil)
  }

  @Test func theKeyOfAQuarter() {
    #expect(NPDTax.paymentKey(year: 2026, quarter: 3) == "tax:2026-Q3")
    let read = NPDTax.paidQuarter("tax:2026-Q3")
    #expect(read?.year == 2026 && read?.quarter == 3)
    #expect(NPDTax.paidQuarter("tax:2026-Q5") == nil)
    #expect(NPDTax.paidQuarter("npd:2026-10") == nil)
    #expect(NPDTax.paidMonth("tax:2026-Q3") == nil)
    #expect(TaxQuarter(of: MonthKey(year: 2026, month: 12)).quarter == 4)
    #expect(NPDTax.dueDay(ofQuarter: 4, year: 2026) == DateOnly(year: 2027, month: 1, day: 28))
  }

  @Test func theKeyOfAPayment() {
    #expect(NPDTax.paymentKey(month: MonthKey(year: 2026, month: 10)) == "npd:2026-10")
    #expect(NPDTax.paidMonth("npd:2026-10") == MonthKey(year: 2026, month: 10))
    #expect(NPDTax.paidMonth("npd:2026") == nil)
    #expect(NPDTax.paidMonth("sched:x") == nil)
  }

  @Test func theTaxCategoryTakesNoLimit() {
    let setup = Setup()
    let tree = setup.book.ledger.tree
    let parent = setup.book.categories.first { $0.name == "Налоги и сборы" }!.id
    #expect(LimitRules.offersLimit(on: parent, tree: tree))
    #expect(
      !LimitRules.offersLimit(on: setup.taxCategory, tree: tree, taxCategoryId: setup.taxCategory))
    var book = setup.book
    let sub = book.category("ФНС", kind: .expense, parent: setup.taxCategory)
    #expect(
      !LimitRules.offersLimit(on: sub, tree: book.ledger.tree, taxCategoryId: setup.taxCategory))
    #expect(LimitRules.offersLimit(on: sub, tree: book.ledger.tree))
  }
}
