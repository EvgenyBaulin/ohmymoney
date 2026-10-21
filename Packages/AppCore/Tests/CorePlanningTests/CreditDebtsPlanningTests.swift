import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CorePlanning

/// The debts of this version in the planning: what hangs in instalments, the payoff ladder, the
/// true cost of a loan, the debt load and its history, the reminders and the review of old debts.
@Suite("Credit: instalments, ladder, cost, load, reminders, review")
struct CreditDebtsPlanningTests {
  func id(_ number: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number)) ?? UUID()
  }

  func money(_ text: String) -> AmountE4 { amountLiteral(text) }

  func day(_ iso: String) -> DateOnly { DateOnly(iso: iso)! }

  func operation(
    _ number: Int, _ kind: TransactionKind, _ iso: String, _ amount: String, category: UUID?
  ) -> TransactionEntry {
    let when = CalendarContext.utc.noon(of: day(iso))
    let transactionId = id(number)
    return TransactionEntry(
      transaction: Transaction(
        id: transactionId, kind: kind, occurredAt: when, amountE4: money(amount), createdAt: when,
        updatedAt: when),
      parts: [
        TransactionPart(
          id: id(number + 100_000), transactionId: transactionId, categoryId: category,
          quality: kind.hasQuality ? .neutral : nil,
          qualitySource: kind.hasQuality ? .category : nil, amountE4: money(amount))
      ])
  }

  var categories: [CoreKit.Category] {
    [
      CoreKit.Category(id: id(1), kind: .expense, name: "Food", quality: .neutral),
      CoreKit.Category(id: id(2), kind: .income, name: "Earnings"),
    ]
  }

  // MARK: - What hangs in instalments

  @Test func instalmentsAddUpInRublesAndListTheSoonestDues() {
    let rub = Debt(
      id: id(10), direction: .iOwe, type: .installment, name: "Vacuum",
      paymentsAreExpenses: false, origin: .purchase,
      steps: DebtSteps(everyDays: 14, firstDue: day("2026-10-12")), parts: 4, termsReviewed: true)
    let usd = Debt(
      id: id(11), direction: .iOwe, type: .installment, name: "Laptop", currency: .usd,
      monthlyPaymentE4: money("100"), paymentDay: 20, paymentsAreExpenses: false,
      origin: .purchase, parts: 6, termsReviewed: true)
    let loan = Debt(
      id: id(12), direction: .iOwe, type: .loan, name: "Bank", monthlyPaymentE4: money("5000"),
      paymentDay: 1)
    var rubState = DebtDueState(
      debtId: id(10), firstDue: day("2026-10-12"), paidCount: 1, owes: true, paymentDay: 12,
      balanceE4: money("9000"),
      instalments: DebtInstalments(steps: [
        .init(fromIndex: 0, amountE4: money("3000")), .init(fromIndex: 4, amountE4: .zero),
      ]))
    rubState.steps = DebtSteps(everyDays: 14, firstDue: day("2026-10-12"))
    let usdState = DebtDueState(
      debtId: id(11), firstDue: day("2026-10-20"), paidCount: 0, owes: true, paymentDay: 20,
      balanceE4: money("600"), monthlyE4: money("100"))
    let summary = InstalmentsSummary.build(
      debts: [rub, usd, loan], states: [id(10): rubState, id(11): usdState],
      journalBalances: [id(10): money("9000"), id(11): money("600"), id(12): money("50000")],
      rubPerUnit: [:], today: day("2026-10-14"))
    #expect(summary.count == 2)
    #expect(summary.totalRub == money("9000"))
    #expect(summary.withoutRate == [id(11)])
    #expect(summary.next.count == 5)
    #expect(summary.next.first?.due == day("2026-10-20"))
    #expect(
      summary.next[1]
        == UpcomingInstalment(
          debtId: id(10), due: day("2026-10-26"), currency: .rub, amountE4: money("3000")))
    #expect(summary.next.map(\.due) == summary.next.map(\.due).sorted())

    let withRate = InstalmentsSummary.build(
      debts: [rub, usd], states: [id(10): rubState, id(11): usdState],
      journalBalances: [id(10): money("9000"), id(11): money("600")],
      rubPerUnit: [.usd: 90], today: day("2026-10-14"))
    #expect(withRate.totalRub == money("63000"))
    #expect(withRate.withoutRate.isEmpty)
  }

  // MARK: - Ladder

  func ladderDebts() -> [LadderDebt] {
    [
      LadderDebt(
        id: id(20), source: .debt(id(20)), name: "Loan", balanceRub: money("300000"),
        ratePercent: 19, minimumRub: money("10000")),
      LadderDebt(
        id: id(21), source: .creditCard(id(21)), name: "Card", balanceRub: money("50000"),
        ratePercent: Decimal(string: "29.9")!, minimumRub: money("2500")),
      LadderDebt(
        id: id(22), source: .debt(id(22)), name: "Instalments", balanceRub: money("12000"),
        ratePercent: 0, minimumRub: money("3000")),
    ]
  }

  @Test func theLadderOrdersAndPaysOff() {
    let comparison = DebtLadder.compare(
      ladderDebts(), extraRub: money("10000"), start: MonthKey(year: 2026, month: 11))
    #expect(comparison.avalanche.order == [id(21), id(20), id(22)])
    #expect(comparison.snowball.order == [id(21), id(20), id(22)])
    let avalanche = comparison.avalanche
    #expect(avalanche.months != nil)
    #expect(avalanche.freeFrom != nil)
    #expect(avalanche.payoff.count == 3)
    #expect(avalanche.firstMonths.count == min(24, avalanche.months ?? 0))
    // Every month pays the minimums and the money above, the last month what is left.
    let budget = money("10000") + money("2500") + money("3000") + money("10000")
    for month in avalanche.firstMonths.dropLast() { #expect(month.paidRub == budget) }
    #expect(comparison.interestSavedRub == .zero)
    #expect(comparison.monthsSaved == 0)

    // The snowball takes the smaller balance first when rates do not decide.
    let other = [
      LadderDebt(
        id: id(30), source: .debt(id(30)), name: "Big", balanceRub: money("100000"),
        ratePercent: 30, minimumRub: money("3000")),
      LadderDebt(
        id: id(31), source: .debt(id(31)), name: "Small", balanceRub: money("20000"),
        ratePercent: 10, minimumRub: money("1000")),
    ]
    let both = DebtLadder.compare(
      other, extraRub: money("5000"), start: MonthKey(year: 2026, month: 1))
    #expect(both.avalanche.order == [id(30), id(31)])
    #expect(both.snowball.order == [id(31), id(30)])
    #expect((both.interestSavedRub ?? .zero) > .zero)
  }

  /// On random sets the avalanche never pays more interest than the snowball.
  @Test func theAvalancheNeverPaysMoreInterest() {
    var generator = SystemRandomNumberGenerator()
    for _ in 0..<60 {
      let count = Int.random(in: 1...4, using: &generator)
      let debts = (0..<count).map { index in
        LadderDebt(
          id: id(100 + index), source: .debt(id(100 + index)), name: "D\(index)",
          balanceRub: AmountE4(raw: Int64.random(in: 10_000...500_000, using: &generator) * 10_000),
          ratePercent: Decimal(Int.random(in: 0...40, using: &generator)),
          minimumRub: AmountE4(raw: Int64.random(in: 500...20_000, using: &generator) * 10_000))
      }
      let comparison = DebtLadder.compare(
        debts, extraRub: money("5000"), start: MonthKey(year: 2026, month: 1))
      if comparison.avalanche.months != nil, comparison.snowball.months != nil {
        #expect(comparison.avalanche.interestRub <= comparison.snowball.interestRub)
      }
    }
  }

  @Test func nothingPaidNeverEnds() {
    let stuck = [
      LadderDebt(
        id: id(40), source: .debt(id(40)), name: "Person", balanceRub: money("1000"),
        ratePercent: 0, minimumRub: .zero)
    ]
    let plan = DebtLadder.plan(
      stuck, extraRub: .zero, method: .avalanche, start: MonthKey(year: 2026, month: 1))
    #expect(plan.months == nil)
    #expect(
      DebtLadder.plan(
        stuck, extraRub: money("600"), method: .snowball,
        start: MonthKey(year: 2026, month: 1)
      ).months == 2)
  }

  /// Three full months leave 12,300, 9,800 and 15,000: «в среднем остаётся» 12,000.
  @Test func theSuggestedExtraIsTheMedianDownToAThousand() {
    let entries = [
      operation(1, .income, "2026-07-05", "50000", category: id(2)),
      operation(2, .expense, "2026-07-10", "37700", category: id(1)),
      operation(3, .income, "2026-08-05", "50000", category: id(2)),
      operation(4, .expense, "2026-08-10", "40200", category: id(1)),
      operation(5, .income, "2026-09-05", "50000", category: id(2)),
      operation(6, .expense, "2026-09-10", "35000", category: id(1)),
    ]
    let ledger = Ledger(
      dataset: Dataset(entries: entries, categories: categories), calendar: .utc)
    #expect(DebtLadder.suggestedExtra(ledger: ledger, today: day("2026-10-14")) == money("12000"))
    #expect(DebtLadder.suggestedExtra(ledger: ledger, today: day("2026-09-14")) == nil)
  }

  // MARK: - The true cost of a loan

  /// 500,000 at 19.9 % over 36 months: 18,556.33 a month; insurance 45,000 and a fee 3,000 paid
  /// apart: overpay 216,027.61 (the last due is what is left), the real rate 27.425 %; a
  /// contract of 25 % disagrees.
  @Test func theTrueCostOfALoan() {
    let payment = InterestMath.annuity(
      principal: money("500000"), percent: Decimal(string: "19.9")!, months: 36)
    #expect(payment == money("18556.33"))
    let start = day("2026-10-01")
    let schedule = DebtAmortization.schedule(
      principal: money("500000"), percent: Decimal(string: "19.9")!, payment: payment,
      firstDue: day("2026-11-01"), paymentDay: 1)
    #expect(schedule.count == 36)
    var debt = Debt(
      id: id(50), direction: .iOwe, type: .loan, name: "Bank",
      interestRate: Decimal(string: "19.9")!, monthlyPaymentE4: payment, paymentDay: 1)
    debt.psk = 25
    let costs = [
      DebtCost(debtId: id(50), kind: .insurance, amountE4: money("45000"), day: start),
      DebtCost(debtId: id(50), kind: .fee, amountE4: money("3000"), day: start),
    ]
    let report = DebtCostReport.report(
      debt: debt, borrowedE4: money("500000"), costs: costs, schedule: schedule, paidE4: .zero,
      firstDay: start)
    // 35 dues of 18,556.33 and the last of what is left, 18,556.06: 216,027.61 — 36 equal
    // payments would make it 216,027.88.
    #expect(schedule.last?.paymentE4 == money("18556.06"))
    #expect(report.overpayE4 == money("216027.61"))
    #expect(report.costsOnceE4 == money("48000"))
    #expect(report.effectiveRate == Decimal(string: "27.425"))
    #expect(report.disagreesWithContract)

    // Insurance inside the loan: the debt is 545,000 and the money received the same 500,000.
    let inLoan = [
      DebtCost(debtId: id(50), kind: .insurance, amountE4: money("45000"), day: start, inLoan: true)
    ]
    let bigger = DebtAmortization.schedule(
      principal: money("545000"), percent: Decimal(string: "19.9")!,
      payment: InterestMath.annuity(
        principal: money("545000"), percent: Decimal(string: "19.9")!, months: 36),
      firstDue: day("2026-11-01"), paymentDay: 1)
    let held = DebtCostReport.report(
      debt: debt, borrowedE4: money("545000"), costs: inLoan, schedule: bigger, paidE4: .zero,
      firstDay: start)
    #expect(held.overpayE4 == held.paymentsE4 - money("500000"))
    #expect(DebtCostReport.effectiveRate(received: money("1000"), payments: []) == nil)
  }

  // MARK: - Load

  /// Dues 38,000 in the month and a card in debt 20,000 (5 % of it, 1,000) against 100,000 of
  /// earnings: 39 %.
  @Test func theLoadOfAMonth() {
    let loan = Debt(
      id: id(60), direction: .iOwe, type: .loan, name: "Bank", monthlyPaymentE4: money("38000"),
      paymentDay: 5)
    let state = DebtDueState(
      debtId: id(60), firstDue: day("2026-09-05"), paidCount: 1, owes: true, paymentDay: 5,
      balanceE4: money("500000"), monthlyE4: money("38000"))
    let load = DebtLoad.month(
      MonthKey(year: 2026, month: 10), debts: [loan], states: [id(60): state],
      creditDebtRub: money("20000"), earningsMedianRub: money("100000"), rubPerUnit: [:])
    #expect(load.loadBp == 3_900)
    #expect(load.monthlyPaymentsRub == money("39000"))
    let none = DebtLoad.month(
      MonthKey(year: 2026, month: 10), debts: [loan], states: [id(60): state],
      creditDebtRub: .zero, earningsMedianRub: nil, rubPerUnit: [:])
    #expect(none.loadBp == nil)
    #expect(none.status == .notEnoughData(reasonKey: DebtLoad.noIncomeKey))
    #expect(DebtLoad.highBp == 5_000 && DebtLoad.veryHighBp == 8_000)
  }

  /// Twelve months, the current one last; past months count what was paid in them; without
  /// earnings every month says «not enough data».
  @Test func theHistoryOfTheLoad() {
    var entries: [TransactionEntry] = []
    for (index, month) in ["03", "04", "05", "06", "07", "08", "09"].enumerated() {
      entries.append(operation(200 + index, .income, "2026-\(month)-05", "100000", category: id(2)))
    }
    let ledger = Ledger(dataset: Dataset(entries: entries, categories: categories), calendar: .utc)
    let loan = Debt(
      id: id(61), direction: .iOwe, type: .loan, name: "Bank", monthlyPaymentE4: money("20000"),
      paymentDay: 5)
    let journal = [
      DebtEntry(
        debtId: id(61), date: day("2026-08-01"), amountE4: money("200000"), kind: .borrowed),
      DebtEntry(debtId: id(61), date: day("2026-09-05"), amountE4: money("-20000"), kind: .payment),
    ]
    let history = DebtLoad.history(
      months: 12, ledger: ledger, debts: [loan], journal: journal, accounts: .empty,
      rubPerUnit: [:], today: day("2026-10-14"), earnings: { $0 == id(2) })
    #expect(history.count == 12)
    #expect(history.last?.month == MonthKey(year: 2026, month: 10))
    let september = history.first { $0.month == MonthKey(year: 2026, month: 9) }
    #expect(september?.load.monthlyPaymentsRub == money("20000"))
    #expect(september?.load.loadBp == 2_000)
    #expect(history.last?.load.loadBp == 2_000)
    let without = DebtLoad.history(
      months: 12, ledger: ledger, debts: [loan], journal: journal, accounts: .empty,
      rubPerUnit: [:], today: day("2026-10-14"), earnings: { _ in false })
    #expect(without.allSatisfy { $0.load.loadBp == nil })
  }

  // MARK: - Reminders

  @Test func theApplicationForAnEarlyRepayment() {
    var loan = Debt(
      id: id(70), direction: .iOwe, type: .loan, name: "Bank", monthlyPaymentE4: money("5000"),
      paymentDay: 15)
    loan.plannedPrepay = PlannedPrepay(day: day("2026-10-15"), amountE4: money("100000"))
    loan.prepayNoticeDays = 3
    func shown(_ iso: String, _ debt: Debt) -> Bool {
      !DebtReminders.list(
        debts: [debt], costs: [], cards: [:], today: day(iso), dismissed: [],
        creditHistoryEnabled: false, creditHistoryDone: nil
      ).isEmpty
    }
    #expect(!shown("2026-10-11", loan))
    #expect(shown("2026-10-12", loan))
    #expect(shown("2026-10-15", loan))
    #expect(!shown("2026-10-16", loan))
    loan.prepayNoticeDays = nil
    #expect(!shown("2026-10-13", loan))
    #expect(shown("2026-10-14", loan))
    let reminder = DebtReminders.list(
      debts: [loan], costs: [], cards: [:], today: day("2026-10-14"), dismissed: [],
      creditHistoryEnabled: false, creditHistoryDone: nil)
    #expect(
      reminder == [
        .prepayNotice(
          debtId: id(70), fileBy: day("2026-10-14"), prepayOn: day("2026-10-15"),
          amountE4: money("100000"))
      ])
    #expect(
      DebtReminders.list(
        debts: [loan], costs: [], cards: [:], today: day("2026-10-14"),
        dismissed: [reminder[0].id], creditHistoryEnabled: false, creditHistoryDone: nil
      ).isEmpty)
  }

  @Test func pledgesInsuranceCreditHistoryAndCards() {
    var pledge = Debt(id: id(80), direction: .owedToMe, type: .personal, name: "Flat")
    pledge.pledge = true
    pledge.returnBy = day("2026-11-01")
    let loan = Debt(id: id(81), direction: .iOwe, type: .loan, name: "Bank")
    let insurance = DebtCost(
      id: id(82), debtId: id(81), kind: .insurance, amountE4: money("45000"), day: day("2026-10-01")
    )
    func list(
      _ iso: String, history: Bool = false, done: HalfYear? = nil,
      cards: [UUID: CreditCardNow] = [:]
    ) -> [DebtReminder] {
      DebtReminders.list(
        debts: [pledge, loan], costs: [insurance], cards: cards, today: day(iso), dismissed: [],
        creditHistoryEnabled: history, creditHistoryDone: done)
    }
    #expect(!list("2026-10-24").contains { if case .pledgeDue = $0 { true } else { false } })
    #expect(
      list("2026-10-25").contains(
        .pledgeDue(debtId: id(80), returnBy: day("2026-11-01"), overdue: false)))
    #expect(
      list("2026-11-02").contains(
        .pledgeDue(debtId: id(80), returnBy: day("2026-11-01"), overdue: true)))
    let cooling = DebtReminder.insuranceCooling(
      costId: id(82), debtId: id(81), until: day("2026-10-31"))
    #expect(list("2026-10-31").contains(cooling))
    #expect(!list("2026-11-01").contains(cooling))

    #expect(
      list("2027-02-01", history: true).contains(
        .creditHistory(half: HalfYear(year: 2027, second: false))))
    #expect(
      !list("2027-01-31", history: true).contains {
        if case .creditHistory = $0 { true } else { false }
      })
    #expect(
      !list("2027-03-01", history: true, done: HalfYear(year: 2027, second: false))
        .contains { if case .creditHistory = $0 { true } else { false } })
    #expect(
      list("2027-08-02", history: true, done: HalfYear(year: 2027, second: false))
        .contains(.creditHistory(half: HalfYear(year: 2027, second: true))))
    #expect(!list("2027-08-02").contains { if case .creditHistory = $0 { true } else { false } })

    let card = CreditCardNow(
      debtE4: money("30000"), toPayNoInterestE4: money("30000"), minimumE4: money("2400"),
      payBy: day("2026-11-30"))
    #expect(
      !list("2026-11-24", cards: [id(90): card]).contains {
        if case .cardPayBy = $0 { true } else { false }
      })
    #expect(
      list("2026-11-25", cards: [id(90): card]).contains(
        .cardPayBy(
          accountId: id(90), due: day("2026-11-30"), fullE4: money("30000"),
          minimumE4: money("2400"))))
  }

  // MARK: - Review

  @Test func oldDebtsAreAskedOnceByKind() {
    let loan = Debt(
      id: id(91), direction: .iOwe, type: .loan, name: "Bank", interestRate: 12,
      monthlyPaymentE4: money("5000"), paymentDay: 5)
    let purchase = Debt(
      id: id(92), direction: .iOwe, type: .installment, name: "Phone", paymentsAreExpenses: false,
      origin: .purchase)
    let card = Debt(id: id(93), direction: .iOwe, type: .creditCard, name: "Card")
    let friend = Debt(id: id(94), direction: .iOwe, type: .personal, name: "Anna")
    let owed = Debt(id: id(95), direction: .owedToMe, type: .personal, name: "Boris")
    var seen = loan
    seen.id = id(96)
    seen.termsReviewed = true
    var shut = loan
    shut.id = id(97)
    shut.closed = true
    let items = DebtReview.toReview(debts: [card, purchase, friend, owed, seen, shut, loan])
    #expect(items.map(\.debtId) == [id(91), id(92), id(93)])
    #expect(items[0].fields == [.costs, .psk, .prepayAnyDay, .prepayNotice, .ladder])
    #expect(items[1].fields == [.instalmentPlan])
    #expect(items[2].fields == [.keepOnlyAccount])
  }

  /// A pledge is money owed back to me: in the capital as «Мне должны», not as spending.
  @Test func aPledgeCountsAsOwedToMeInTheCapital() {
    typealias Fx = CapitalFx
    var pledge = Debt(id: Fx.id(141), direction: .owedToMe, type: .personal, name: "Flat")
    pledge.pledge = true
    pledge.returnBy = Fx.day("2027-02-01")
    let journal = [
      DebtEntry(
        debtId: pledge.id, date: Fx.day("2026-09-05"), amountE4: Fx.rub("30000"), kind: .borrowed)
    ]
    let main = PaymentMethod(id: Fx.id(1), name: "Main", isDefault: true)
    let (count, rows) = Fx.count(1, "2026-09-01", [(main.id, .rub, "50000")])
    let dataset = Dataset(
      paymentMethods: [main], debts: [pledge],
      planning: PlanningBook(
        reconciliations: [count], debtEntries: journal, reconciledBalances: rows))
    let capital = Fx.capital(dataset, today: Fx.day("2026-10-11"))
    #expect(capital.now.owedToMeRub == Fx.rub("30000"))
    #expect(capital.now.accountsRub == Fx.rub("20000"))
    #expect(capital.now.netRub == Fx.rub("50000"))
  }
}
