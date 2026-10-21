import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CorePlanning

/// The sentence over the blocks of Planning and the ribbon of the next 14 days: no number of
/// their own — the free sum's and the calendar's.
@Suite("The sentence and the ribbon of Planning")
struct PlanningSummaryTests {
  typealias Fx = CashFx

  /// Main counted 100,000 ₽. Through 30 September: the internet of the 25th, the gym of the 20th
  /// on the card and the loan of the 25th — three payments of 1,000 + 2,000 + 10,000 ₽. The
  /// sentence says what the grey line of the free sum says, through its D.
  @Test func theSentenceIsTheFreeSumsGreyLineAndItsPayments() throws {
    var fx = Fx()
    fx.count([(Fx.main, .rub, "100000")], at: Fx.at("2026-09-10", 14))
    fx.scheduled = [
      Fx.payment(3, "Internet", "1000", day: 25, next: "2026-09-25"),
      Fx.payment(4, "Gym", "2000", day: 20, next: "2026-09-20", account: Fx.card),
    ]
    let loan = Debt(
      id: Fx.id(301), direction: .iOwe, type: .loan, name: "Loan",
      monthlyPaymentE4: Fx.money("10000"), paymentDay: 25)
    fx.debts = [loan]
    fx.debtEntries = [
      DebtEntry(
        debtId: loan.id, date: Fx.day("2026-09-01"), amountE4: Fx.money("50000"),
        kind: .adjustment)
    ]
    let ledger = fx.ledger
    let free = fx.snapshot().freeMoney(until: nil, ledger: ledger)
    let summary = try #require(PlanningSummary(free))
    #expect(summary.until == Fx.day("2026-09-30"))
    #expect(summary.until == free.until)
    #expect(summary.left == free.grey)
    #expect(summary.dueCount == 3)
    #expect(summary.duesAmount == Fx.money("13000"))
    let lines = free.lines.filter {
      $0.key == FreeMoney.Key.scheduled || $0.key == FreeMoney.Key.debts
    }
    #expect(summary.duesAmount == AmountE4.sum(lines.map(\.amount)))

    // Another D: the sentence follows the block's day.
    let october = fx.snapshot().freeMoney(until: Fx.day("2026-10-31"), ledger: ledger)
    let later = try #require(PlanningSummary(october))
    #expect(later.until == Fx.day("2026-10-31"))
    #expect(later.left == october.grey)
    #expect(later.dueCount == 6)
    #expect(later.duesAmount == Fx.money("26000"))
  }

  /// Nothing counted: there is no money to start from, and no sentence.
  @Test func noSentenceBeforeTheFirstCount() {
    var fx = Fx()
    fx.scheduled = [Fx.payment(3, "Internet", "1000", day: 25, next: "2026-09-25")]
    let free = fx.snapshot().freeMoney(until: nil, ledger: fx.ledger)
    #expect(PlanningSummary(free) == nil)
  }

  /// A payment on the account of a group out of the summary is in no line of the free sum, and
  /// so in no count of the sentence either.
  @Test func aPaymentOutOfTheSummaryIsNotCounted() throws {
    var fx = Fx()
    fx.count([(Fx.main, .rub, "100000")], at: Fx.at("2026-09-10", 14))
    fx.scheduled = [
      Fx.payment(3, "Internet", "1000", day: 25, next: "2026-09-25"),
      Fx.payment(
        5, "Kaspi", "5000", day: 26, next: "2026-09-26", currency: Fx.tenge,
        account: Fx.freedom),
    ]
    let summary = try #require(
      PlanningSummary(fx.snapshot().freeMoney(until: nil, ledger: fx.ledger)))
    #expect(summary.dueCount == 1)
    #expect(summary.duesAmount == Fx.money("1000"))
  }

  // MARK: - The ribbon

  /// Today is 19 September: the ribbon runs through 2 October. The rent of the 25th and of
  /// 25 October, the salary of 1 October: what is on the ribbon is what the calendar plans for
  /// those days, and its sums are theirs.
  @Test func theRibbonSumsArePaymentsAndIncomesOfFourteenDays() throws {
    var fx = Fx()
    fx.scheduled = [
      Fx.payment(3, "Rent", "30000", day: 25, next: "2026-09-25"),
      Fx.payment(4, "Netflix", "10", day: 1, next: "2026-10-01", currency: .usd),
      Fx.payment(6, "Gym", "2000", day: 20, next: "2026-09-20"),
    ]
    fx.expected = [
      ExpectedIncome(
        name: "Salary", kind: .recurring, totalE4: Fx.money("100000"), freq: .monthly, day: 1)
    ]
    let ledger = fx.ledger
    let range = PlanningRibbon.range(today: Fx.today)
    #expect(range.start == Fx.day("2026-09-19"))
    #expect(range.end == Fx.day("2026-10-02"))
    let plans = CalendarPlans.collect(
      ledger: ledger, book: ledger.dataset.planning, today: Fx.today, through: range.end,
      rubPerUnit: fx.rubPerUnit)
    let ribbon = PlanningRibbon.build(plans: plans, today: Fx.today, rubPerUnit: fx.rubPerUnit)
    #expect(ribbon.days.count == 14)
    #expect(ribbon.days.first?.day == Fx.today)
    #expect(ribbon.days.last?.day == range.end)

    let payments = plans.filter { $0.kind == .payment }
    let incomes = plans.filter { $0.kind == .income }
    #expect(ribbon.days.flatMap(\.payments) == payments)
    #expect(ribbon.days.flatMap(\.incomes) == incomes)
    // 30,000 + 2,000 + 10 $ × 90 = 32,900 ₽ of payments; 100,000 ₽ of salary on 1 October.
    #expect(ribbon.paymentsRub == Fx.money("32900"))
    #expect(ribbon.incomesRub == Fx.money("100000"))
    #expect(ribbon.withoutRate.isEmpty)
    let rentDay = try #require(ribbon.days.first { $0.day == Fx.day("2026-09-25") })
    #expect(rentDay.payments.map(\.name) == ["Rent"])
    let first = try #require(ribbon.days.first { $0.day == Fx.day("2026-10-01") })
    #expect(first.incomes.map(\.name) == ["Salary"])
    #expect(first.payments.map(\.name) == ["Netflix"])
    #expect(!ribbon.isEmpty)
  }

  /// A plan past the 14 days is not on the ribbon; a currency without a rate is listed, not
  /// guessed.
  @Test func outsideTheDaysAndWithoutARate() {
    let euro = CurrencyCode("EUR")
    let inside = CalendarPlan(
      kind: .payment, sourceId: Fx.id(1), day: Fx.day("2026-09-20"), name: "Paris",
      amount: Fx.money("50"), currency: euro)
    let outside = CalendarPlan(
      kind: .payment, sourceId: Fx.id(2), day: Fx.day("2026-10-03"), name: "Late",
      amount: Fx.money("100"), currency: .rub)
    let ribbon = PlanningRibbon.build(
      plans: [inside, outside], today: Fx.today, rubPerUnit: [:])
    #expect(ribbon.days.flatMap(\.payments) == [inside])
    #expect(ribbon.paymentsRub == .zero)
    #expect(ribbon.withoutRate == [euro])
    #expect(PlanningRibbon.build(plans: [], today: Fx.today, rubPerUnit: [:]).isEmpty)
  }
}
