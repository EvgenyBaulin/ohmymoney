import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CorePlanning

/// An education loan through the planning: every screen reads its dues from the one state, so
/// the grace dues — the interest of the money drawn — and the main payment from the switch reach
/// the 7-day card, the overdue rows, the free sum, the plan of the account, the form of a
/// payment, the debt load and the advice without a rule of their own.
///
/// 100 000 was drawn on 1 August 2026, at 3.65 % — 10 a day —, paid on the 25th; the main
/// schedule starts on 25 November over 12 months. The grace dues: 25 August — 24 days, 240 —,
/// 25 September — 310 —, 25 October — 300. Today is 19 September.
@Suite("An education loan through the planning")
struct EducationLoanPlanningTests {
  typealias Fx = CashFx

  static let loanId = Fx.id(381)
  static let rate = Decimal(string: "3.65") ?? 0
  static let main = InterestMath.annuity(principal: Fx.money("100000"), percent: rate, months: 12)

  static let loan = Debt(
    id: loanId, direction: .iOwe, type: .loan, name: "Education", interestRate: rate,
    paymentDay: 25, paymentsAreExpenses: false, origin: .purchase,
    grace: DebtGrace(mainFrom: Fx.day("2026-11-25"), payment: .interest), repayMonths: 12)

  static let tranche = DebtEntry(
    id: Fx.id(382), debtId: loanId, date: Fx.day("2026-08-01"), amountE4: Fx.money("100000"),
    kind: .adjustment, tranche: true)

  static func paid(_ iso: String, _ amount: String, _ number: Int) -> DebtEntry {
    DebtEntry(
      id: Fx.id(383 + number), debtId: loanId, date: Fx.day(iso), amountE4: Fx.money("-" + amount),
      kind: .payment)
  }

  func fixture(_ payments: [DebtEntry] = []) -> CashFx {
    var fx = Fx()
    fx.count([(Fx.main, .rub, "500000")], at: Fx.at("2026-09-10", 14))
    fx.debts = [Self.loan]
    fx.debtEntries = [Self.tranche] + payments
    return fx
  }

  // MARK: The grace period

  @Test func theOverdueGraceDueAsksForItsInterest() {
    let overdue = fixture().snapshot().overdue
    #expect(overdue.map(\.due) == [Fx.day("2026-08-25")])
    #expect(overdue.map(\.amount) == [Fx.money("240")])
  }

  @Test func theSevenDayCardShowsTheNextGraceDue() {
    let fx = fixture([Self.paid("2026-08-25", "240", 1)])
    let snapshot = fx.snapshot()
    #expect(snapshot.overdue.isEmpty)
    let debt = snapshot.upcoming.first { $0.kind == .debt }
    #expect(debt?.due == Fx.day("2026-09-25"))
    #expect(debt?.amount == Fx.money("310"))
  }

  /// The free sum takes each grace due at its own sum, and the main payment once it starts.
  @Test func theFreeSumTakesTheDuesAtTheirSums() {
    let fx = fixture([Self.paid("2026-08-25", "240", 1)])
    #expect(fx.plan(until: "2026-09-30").debts == Fx.money("310"))
    #expect(fx.plan(until: "2026-10-31").debts == Fx.money("610"))
    #expect(fx.plan(until: "2026-12-31").debts == Fx.money("610") + Self.main + Self.main)
    // Unpaid, the overdue due of August is money still to leave.
    let unpaid = fixture().plan(until: "2026-09-30")
    #expect(unpaid.debts == Fx.money("550"))
    #expect(unpaid.overdue == Fx.money("240"))
  }

  @Test func thePlanOfTheAccountTakesTheGraceDueOfTheMonth() {
    let fx = fixture([Self.paid("2026-08-25", "240", 1)])
    let ledger = fx.ledger
    let plan = AccountMonthPlan.build(
      ledger: ledger,
      planning: PlanningSnapshot.build(
        ledger: ledger, today: Fx.today, now: Fx.now, rubPerUnit: fx.rubPerUnit))
    let main = plan.sections.flatMap(\.keys).first {
      $0.key == BalanceKey(accountId: Fx.main, currency: .rub)
    }
    #expect(main?.debts == Fx.money("310"))
  }

  /// The form of a payment starts with the grace due and may close it below its sum — a percent
  /// of that due short is the due.
  @Test func thePaymentFormKnowsTheGraceDue() throws {
    let line = try #require(
      fixture([Self.paid("2026-08-25", "240", 1)]).snapshot().debts.iOwe.first)
    #expect(DebtTerms.amountToPay(line.debt, dues: line.dues) == Fx.money("310"))
    #expect(DebtTerms.offersClosing(line.debt, paying: Fx.money("100"), dues: line.dues))
    #expect(!DebtTerms.offersClosing(line.debt, paying: Fx.money("307"), dues: line.dues))
    #expect(line.schedule?.phase == .grace)
    #expect(line.schedule?.current == Fx.money("310"))
    #expect(line.schedule?.mainAmount == Self.main)
    #expect(line.schedule?.drawnE4 == Fx.money("100000"))
    #expect(DebtLoad.payment(of: line.debt, dues: line.dues) == Fx.money("310"))
    #expect(AdviceRules.debtPayoffs(fixture().snapshot().debts).isEmpty, "no payoff in grace")
  }

  /// «Уже списано до сверки» of a grace due pays its own sum.
  @Test func aDueSettledByACountPaysItsOwnSum() throws {
    let line = try #require(fixture().snapshot().debts.iOwe.first)
    let due = Fx.day("2026-08-25")
    let entry = DebtRules.settledByCount(
      debt: line.debt, due: due, balance: line.balance, owed: line.dues.owed(due))
    #expect(entry?.amountE4 == Fx.money("-240"))
    #expect(entry?.closesTerm == true)
  }

  // MARK: Across the switch

  /// Every grace due paid: on 1 December the main due of 25 November is owed at the main
  /// payment, and the next ones too.
  @Test func theMainPaymentFromTheSwitch() throws {
    let fx = fixture([
      Self.paid("2026-08-25", "240", 1), Self.paid("2026-09-25", "310", 2),
      Self.paid("2026-10-25", "300", 3),
    ])
    let today = Fx.day("2026-12-01")
    let snapshot = fx.snapshot(today: today, now: Fx.at("2026-12-01", 12))
    #expect(snapshot.overdue.map(\.due) == [Fx.day("2026-11-25")])
    #expect(snapshot.overdue.map(\.amount) == [Self.main])
    let line = try #require(snapshot.debts.iOwe.first)
    #expect(line.schedule?.phase == .main)
    #expect(DebtTerms.amountToPay(line.debt, dues: line.dues) == Self.main)
    let due = Fx.day("2026-11-25")
    #expect(
      DebtRules.settledByCount(
        debt: line.debt, due: due, balance: line.balance, owed: line.dues.owed(due))?.amountE4
        == -Self.main)
    #expect(DebtLoad.payment(of: line.debt, dues: line.dues) == Self.main)
    #expect(AdviceRules.debtPayoffs(snapshot.debts).count == 1, "the payoff advice is back")
  }

  /// An overdue grace due keeps its grace sum after the switch.
  @Test func anOverdueGraceDueKeepsItsSumAfterTheSwitch() {
    let fx = fixture([Self.paid("2026-08-25", "240", 1), Self.paid("2026-09-25", "310", 2)])
    let snapshot = fx.snapshot(today: Fx.day("2026-12-01"), now: Fx.at("2026-12-01", 12))
    #expect(snapshot.overdue.map(\.due) == [Fx.day("2026-10-25")])
    #expect(snapshot.overdue.map(\.amount) == [Fx.money("300")])
    let line = snapshot.debts.iOwe.first
    #expect(line?.dues.owed(through: Fx.day("2026-11-30")) == Fx.money("300") + Self.main)
  }
}
