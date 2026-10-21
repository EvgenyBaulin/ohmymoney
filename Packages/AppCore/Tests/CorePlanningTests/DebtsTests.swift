import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CorePlanning

/// The Debts section: the next payment, the payoff scenario, the load and the two
/// lists. Every number is worked out by hand in the comment next to it. The helpers are
/// members of the suite so they never collide with the fixtures of other suites.
@Suite("Debts: schedule, payoff, load and the two lists")
struct DebtsTests {

  // MARK: - Fixtures

  func id(_ number: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number)) ?? UUID()
  }

  func money(_ text: String) -> AmountE4 {
    amountLiteral(text)
  }

  func day(_ iso: String) -> DateOnly {
    DateOnly(iso: iso) ?? DateOnly(year: 1970, month: 1, day: 1)
  }

  func part(
    _ number: Int, _ amount: String, rub: String? = nil, reimbursable: Bool = false,
    debtor: UUID? = nil, status: ReimbursementStatus? = nil, note: String? = nil
  ) -> TransactionPart {
    TransactionPart(
      id: id(number), transactionId: id(0), amountE4: money(amount),
      amountRubE4: money(rub ?? amount), reimbursable: reimbursable, debtorPersonId: debtor,
      reimbursementStatus: status, note: note)
  }

  func operation(
    _ number: Int, _ kind: TransactionKind = .expense, on iso: String,
    currency: CurrencyCode = .rub, debt: UUID? = nil, note: String? = nil, deleted: Bool = false,
    parts: [TransactionPart]
  ) -> TransactionEntry {
    let when = CalendarContext.utc.startOfDay(day(iso)).addingTimeInterval(12 * 3600)
    var fixed = parts
    for index in fixed.indices { fixed[index].transactionId = id(number) }
    return TransactionEntry(
      transaction: Transaction(
        id: id(number), kind: kind, occurredAt: when, currency: currency,
        amountE4: AmountE4.sum(fixed.map(\.amountE4)),
        amountRubE4: AmountE4.sum(fixed.map(\.amountRubE4)), note: note, debtId: debt,
        createdAt: when, updatedAt: when, deletedAt: deleted ? when : nil),
      parts: fixed)
  }

  func line(
    _ debtId: UUID, _ kind: DebtEntryKind, _ amount: String, on iso: String? = nil,
    group: String? = nil, number: Int? = nil, transaction: Int? = nil
  ) -> DebtEntry {
    DebtRules.makeEntry(
      id: number.map(id) ?? UUID(), debtId: debtId, kind: kind, amountE4: money(amount),
      date: iso.map(day), groupName: group, transactionId: transaction.map(id))
  }

  func loan(
    _ number: Int, currency: CurrencyCode = .rub, monthly: String? = nil, day paymentDay: Int?,
    closed: Bool = false, name: String = "Loan"
  ) -> Debt {
    Debt(
      id: id(number), direction: .iOwe, type: .loan, name: name, currency: currency,
      monthlyPaymentE4: monthly.map(money), paymentDay: paymentDay, closed: closed)
  }

  // MARK: - Next payment

  @Test func theNextPaymentIsThisMonthsUntilItIsPaid() {
    let debt = loan(1, monthly: "7000", day: 15)
    #expect(
      DebtSchedule.nextPaymentDate(
        of: debt, today: day("2026-03-10"), paidThisMonth: false, calendar: .utc)
        == day("2026-03-15"))
    #expect(
      DebtSchedule.nextPaymentDate(
        of: debt, today: day("2026-03-10"), paidThisMonth: true, calendar: .utc)
        == day("2026-04-15"))
    // The day has passed and nothing was paid: the payment is overdue, not skipped.
    #expect(
      DebtSchedule.nextPaymentDate(
        of: debt, today: day("2026-03-20"), paidThisMonth: false, calendar: .utc)
        == day("2026-03-15"))
    // Paid in December: next January.
    #expect(
      DebtSchedule.nextPaymentDate(
        of: debt, today: day("2026-12-20"), paidThisMonth: true, calendar: .utc)
        == day("2027-01-15"))
  }

  @Test func thePaymentDayIsClippedToTheLengthOfTheMonth() {
    let debt = loan(1, monthly: "7000", day: 31)
    func next(_ iso: String, paid: Bool) -> DateOnly? {
      DebtSchedule.nextPaymentDate(of: debt, today: day(iso), paidThisMonth: paid, calendar: .utc)
    }
    #expect(next("2026-02-10", paid: false) == day("2026-02-28"))
    #expect(next("2026-01-31", paid: true) == day("2026-02-28"))
    #expect(next("2028-01-31", paid: true) == day("2028-02-29"))
    #expect(next("2026-08-31", paid: true) == day("2026-09-30"))
    #expect(next("2026-09-01", paid: false) == day("2026-09-30"))
    #expect(next("2026-07-01", paid: false) == day("2026-07-31"))
  }

  @Test func noPaymentDayOrAClosedDebtHasNoNextPayment() {
    #expect(
      DebtSchedule.nextPaymentDate(
        of: loan(1, monthly: "7000", day: nil), today: day("2026-03-10"), paidThisMonth: false,
        calendar: .utc) == nil)
    #expect(
      DebtSchedule.nextPaymentDate(
        of: loan(1, monthly: "7000", day: 15, closed: true), today: day("2026-03-10"),
        paidThisMonth: false, calendar: .utc) == nil)
  }

  @Test func aDebtIsPaidThisMonthByAnOperationOrByAPaymentInTheJournal() {
    let byOperation = loan(1, day: 15)
    let byJournal = loan(2, day: 15)
    let lastMonth = loan(3, day: 15)
    let offsetOnly = loan(4, day: 15)
    let ledger = Ledger(
      dataset: Dataset(
        entries: [
          operation(101, on: "2026-03-02", debt: byOperation.id, parts: [part(1011, "7000")]),
          operation(102, on: "2026-02-27", debt: lastMonth.id, parts: [part(1021, "7000")]),
        ],
        debts: [byOperation, byJournal, lastMonth, offsetOnly]),
      calendar: .utc)
    let journal = [
      line(byJournal.id, .payment, "7000", on: "2026-03-01"),
      line(lastMonth.id, .payment, "7000", on: "2026-02-27"),
      line(offsetOnly.id, .offset, "500", on: "2026-03-03"),
    ]
    let today = day("2026-03-10")
    func paid(_ debt: Debt) -> Bool {
      DebtSchedule.isPaid(debt, inMonthOf: today, ledger: ledger, journal: journal)
    }
    #expect(paid(byOperation))
    #expect(paid(byJournal))
    #expect(!paid(lastMonth))
    #expect(!paid(offsetOnly))
  }

  // MARK: - Payoff

  /// 1 000 at 12 % a year (r = 0.01) paying 500:
  /// month 1: interest 10, 1 000 + 10 − 500 = 510; month 2: 5.1, 510 + 5.1 − 500 = 15.1;
  /// month 3: 0.151, paid off. 3 months, 15.251 of interest.
  /// With 500 extra (1 000 a month): month 1: 10, 1 010 − 1 000 = 10; month 2: 0.1, paid off.
  /// 2 months, 10.1 of interest — one month and 5.151 sooner.
  @Test func anExtraPaymentClosesTheDebtSooner() {
    let scenario = DebtPayoff.scenario(
      balance: money("1000"), annualRatePercent: 12, monthlyPayment: money("500"),
      extra: money("500"))
    #expect(scenario.monthsWithout == 3)
    #expect(scenario.interestWithout == money("15.251"))
    #expect(scenario.monthsWith == 2)
    #expect(scenario.interestWith == money("10.1"))
    #expect(scenario.monthsSaved == 1)
    #expect(scenario.interestSaved == money("5.151"))
  }

  /// The extra the card's scenario tries is a tenth of the payment in the debt's own currency,
  /// the extra of Advice: the card took at least 100 of any currency, so
  /// a 50 USD payment was shown +100 USD a month — three times the payment, not a little more.
  @Test func theExtraTriedIsATenthOfThePaymentInItsCurrency() {
    #expect(DebtPayoff.suggestedExtra(for: money("50"), currency: .usd) == money("5"))
    #expect(DebtPayoff.suggestedExtra(for: money("15000"), currency: .rub) == money("1500"))
    #expect(DebtPayoff.suggestedExtra(for: money("400"), currency: .rub) == money("100"))
    #expect(
      DebtPayoff.suggestedExtra(for: money("15000"), currency: .rub)
        == AdviceRules.payoffExtra(money("15000"), currency: .rub))
  }

  /// 3 000 at 24 % (r = 0.02) paying 1 000:
  /// 1: 60 → 2 060; 2: 41.2 → 1 101.2; 3: 22.024 → 123.224; 4: 2.46448, rounded to stored
  /// units 2.4645, paid off. 4 months, 60 + 41.2 + 22.024 + 2.4645 = 125.6885.
  /// With 500 extra: 1: 60 → 1 560; 2: 31.2 → 91.2; 3: 1.824, paid off. 3 months, 93.024.
  @Test func interestIsRoundedToStoredUnitsEveryMonth() {
    let scenario = DebtPayoff.scenario(
      balance: money("3000"), annualRatePercent: 24, monthlyPayment: money("1000"),
      extra: money("500"))
    #expect(scenario.monthsWithout == 4)
    #expect(scenario.interestWithout == money("125.6885"))
    #expect(scenario.monthsWith == 3)
    #expect(scenario.interestWith == money("93.024"))
    #expect(scenario.monthsSaved == 1)
  }

  /// 12.5 % never divides evenly: r = 0.0104166…, so the first month of 1 000 is 10.41666…
  /// → 10.4167, leaving 10.4167 after a payment of 1 000; the second month is 0.10850…
  /// → 0.1085. 2 months, 10.5252.
  @Test func aRateThatDoesNotDivideEvenly() {
    let scenario = DebtPayoff.scenario(
      balance: money("1000"), annualRatePercent: Decimal(string: "12.5"),
      monthlyPayment: money("1000"), extra: .zero)
    #expect(scenario.monthsWithout == 2)
    #expect(scenario.interestWithout == money("10.5252"))
    #expect(scenario.monthsWith == 2)
    #expect(scenario.monthsSaved == 0)
  }

  /// Without interest it is ⌈balance ÷ payment⌉: ⌈1 000 ÷ 300⌉ = 4, ⌈1 000 ÷ 500⌉ = 2.
  @Test func withoutARateItIsTheBalanceOverThePayment() {
    for rate in [nil, Decimal(0)] {
      let scenario = DebtPayoff.scenario(
        balance: money("1000"), annualRatePercent: rate, monthlyPayment: money("300"),
        extra: money("200"))
      #expect(scenario.monthsWithout == 4)
      #expect(scenario.monthsWith == 2)
      #expect(scenario.monthsSaved == 2)
      #expect(scenario.interestWithout == .zero)
      #expect(scenario.interestWith == .zero)
    }
    let exact = DebtPayoff.scenario(
      balance: money("900"), annualRatePercent: nil, monthlyPayment: money("300"), extra: .zero)
    #expect(exact.monthsWithout == 3)
  }

  /// 1 000 at 12 %: the first month's interest is 10, so a payment of 10 never gets anywhere.
  /// With 90 extra, 100 a month: 1.01ⁿ · (1 000 − 10 000) + 10 000 ≤ 0 from 1.01ⁿ ≥ 1.111…,
  /// n ≥ 10.59 — 11 months.
  @Test func aPaymentThatDoesNotCoverTheInterestNeverPaysTheDebtOff() {
    let scenario = DebtPayoff.scenario(
      balance: money("1000"), annualRatePercent: 12, monthlyPayment: money("10"),
      extra: money("90"))
    #expect(scenario.monthsWithout == nil)
    #expect(scenario.interestWithout == .zero)
    #expect(scenario.monthsWith == 11)
    #expect(scenario.monthsSaved == nil)
    #expect(scenario.interestSaved == nil)

    let nothing = DebtPayoff.scenario(
      balance: money("1000"), annualRatePercent: 12, monthlyPayment: .zero, extra: .zero)
    #expect(nothing.monthsWithout == nil)
    #expect(nothing.monthsWith == nil)
  }

  /// 100 000 at 12 % paying 1 001: 1 of principal the first month, growing 1 % a month —
  /// 1.01ⁿ ≥ 1 001 takes 694 months, past the fifty-year horizon. Paying 2 000: 1.01ⁿ ≥ 2,
  /// n ≥ 69.66 — 70 months.
  @Test func beyondFiftyYearsIsNever() {
    let scenario = DebtPayoff.scenario(
      balance: money("100000"), annualRatePercent: 12, monthlyPayment: money("1001"),
      extra: money("999"))
    #expect(scenario.monthsWithout == nil)
    #expect(scenario.monthsWith == 70)
    let flat = DebtPayoff.scenario(
      balance: money("100000"), annualRatePercent: nil, monthlyPayment: money("100"),
      extra: .zero)
    #expect(flat.monthsWithout == nil)
    #expect(DebtPayoff.horizonMonths == 600)
  }

  @Test func aSettledDebtTakesNoMonths() {
    for balance in [AmountE4.zero, money("-50")] {
      let scenario = DebtPayoff.scenario(
        balance: balance, annualRatePercent: 12, monthlyPayment: money("100"), extra: .zero)
      #expect(scenario.monthsWithout == 0)
      #expect(scenario.monthsWith == 0)
      #expect(scenario.monthsSaved == 0)
    }
  }

  @Test(arguments: ["12.5", "12,5", "12.5%", " 12,5 % "])
  func aRateCanBeTypedWithEitherSeparator(_ text: String) {
    #expect(DebtPayoff.parseRate(text) == Decimal(string: "12.5"))
  }

  @Test func notARate() {
    #expect(DebtPayoff.parseRate("0") == 0)
    for text in ["", "%", "-3", "twelve", "12.5.1", "12%%"] {
      #expect(DebtPayoff.parseRate(text) == nil, "\(text)")
    }
  }

  // MARK: - Load

  /// Open debts I owe: 7 000 ₽ + 100 $ × 95 = 9 500 ₽ + 2 000 ₽ in instalments = 18 500 ₽.
  /// Left out: the closed loan, the debt owed to me, the euro loan without a rate (listed),
  /// the loan without a monthly payment (listed).
  var loadDebts: [Debt] {
    [
      loan(1, monthly: "7000", day: 25),
      loan(2, currency: .usd, monthly: "100", day: 28),
      Debt(
        id: id(3), direction: .iOwe, type: .installment, name: "Laptop",
        monthlyPaymentE4: money("2000"), paymentDay: 5, paymentsAreExpenses: false,
        origin: .purchase),
      loan(4, monthly: "3000", day: 3, closed: true),
      Debt(
        id: id(5), direction: .owedToMe, type: .personal, name: "Friend",
        monthlyPaymentE4: money("1000")),
      loan(6, currency: .eur, monthly: "50", day: 10),
      loan(7, day: nil),
    ]
  }

  @Test func theLoadIsThePaymentsOverTheIncome() {
    let ledger = Ledger(dataset: Dataset(debts: loadDebts), calendar: .utc)
    let load = DebtLoad.load(
      debts: loadDebts, ledger: ledger, today: day("2026-09-15"), income: money("100000"),
      rubPerUnit: [.usd: 95])
    #expect(load.monthlyPaymentsRub == money("18500"))
    #expect(load.incomeRub == money("100000"))
    #expect(load.incomeSource == .given)
    // 18 500 ÷ 100 000 = 18.5 %.
    #expect(load.loadBp == 1_850)
    #expect(load.withoutRate == [id(6)])
    #expect(load.withoutPayment == [id(7)])
    #expect(load.status == .ready)

    // 18 500 ÷ 30 000 = 0.61666… → 6 166.7 bp → 6 167.
    let heavy = DebtLoad.load(
      debts: loadDebts, ledger: ledger, today: day("2026-09-15"), income: money("30000"),
      rubPerUnit: [.usd: 95])
    #expect(heavy.loadBp == 6_167)
  }

  @Test func withoutIncomeThereIsNoLoad() {
    let ledger = Ledger(dataset: Dataset(debts: loadDebts), calendar: .utc)
    for income in [nil, AmountE4.zero] {
      let load = DebtLoad.load(
        debts: loadDebts, ledger: ledger, today: day("2026-09-15"), income: income,
        rubPerUnit: [.usd: 95])
      #expect(load.loadBp == nil)
      #expect(load.status == .notEnoughData(reasonKey: DebtLoad.noIncomeKey))
      #expect(load.monthlyPaymentsRub == money("18500"))
    }
  }

  /// No estimate: the load takes `IncomeEstimate` from the history, which begins on 1 June —
  /// the median of June, July and August: 50 000, 80 000 (the salary for July arrives on 2 August), 60 000 — 60 000;
  /// 18 500 ÷ 60 000 = 3 083.3 bp → 3 083. The salary entered ahead for 20 September has not
  /// come yet and stays out.
  @Test func withoutAnEstimateTheLoadTakesTheIncomeOfTheLastMonths() {
    var entries = [
      operation(201, .income, on: "2026-06-01", parts: [part(2011, "50000")]),
      operation(202, .income, on: "2026-07-05", parts: [part(2021, "20000")]),
      operation(203, .income, on: "2026-08-02", parts: [part(2031, "60000")]),
      operation(204, .income, on: "2026-08-20", parts: [part(2041, "60000")]),
      operation(205, .income, on: "2026-09-20", parts: [part(2051, "999999")]),
    ]
    entries[2].transaction.periodMonth = MonthKey(year: 2026, month: 7)
    let ledger = Ledger(dataset: Dataset(entries: entries, debts: loadDebts), calendar: .utc)
    let load = DebtLoad.load(
      debts: loadDebts, ledger: ledger, today: day("2026-09-15"), income: nil,
      rubPerUnit: [.usd: 95])
    #expect(load.incomeRub == money("60000"))
    #expect(load.incomeSource == .history)
    #expect(load.loadBp == 3_083)
    #expect(load.status == .ready)

    // Nothing complete yet: the income of a month that has only begun is no estimate.
    let fresh = Ledger(
      dataset: Dataset(
        entries: [operation(206, .income, on: "2026-09-05", parts: [part(2061, "40000")])],
        debts: loadDebts),
      calendar: .utc)
    let unknown = DebtLoad.load(
      debts: loadDebts, ledger: fresh, today: day("2026-09-15"), income: nil,
      rubPerUnit: [.usd: 95])
    #expect(unknown.incomeSource == .none)
    #expect(unknown.loadBp == nil)
    #expect(unknown.status == .notEnoughData(reasonKey: DebtLoad.noIncomeKey))
  }

  // MARK: - The two lists

  struct Section {
    let anna: UUID
    let boris: UUID
    let bank: Debt
    let dollar: Debt
    let euro: Debt
    let annaDebt: Debt
    let borisDebt: Debt
    let old: Debt
    let ledger: Ledger
    let book: PlanningBook
  }

  /// Three debts I owe (rubles, dollars, euros), two owed to me, one closed, and purchases
  /// with parts paid for others. The bank loan took its second sum on 1 August and was paid on
  /// 25 August and 5 September (the operation and its journal line); the dollar and euro loans
  /// began on 1 September.
  func section() -> Section {
    let anna = id(40)
    let boris = id(41)
    let bank = Debt(
      id: id(1), direction: .iOwe, type: .loan, name: "Bank loan", monthlyPaymentE4: money("7000"),
      paymentDay: 25, loansSubcategoryId: id(4))
    let dollar = Debt(
      id: id(2), direction: .iOwe, type: .loan, name: "Dollar loan", currency: .usd,
      monthlyPaymentE4: money("100"), paymentDay: 28)
    let euro = Debt(
      id: id(3), direction: .iOwe, type: .loan, name: "Euro loan", currency: .eur,
      monthlyPaymentE4: money("50"), paymentDay: 10)
    let annaDebt = Debt(
      id: id(5), direction: .owedToMe, type: .personal, name: "Anna", personId: anna)
    let borisDebt = Debt(
      id: id(6), direction: .owedToMe, type: .personal, name: "Boris", personId: boris,
      currency: .usd)
    let old = Debt(
      id: id(7), direction: .iOwe, type: .loan, name: "Old loan", monthlyPaymentE4: money("3000"),
      paymentDay: 3, closed: true)

    let journal = [
      line(bank.id, .borrowed, "100000", group: "Renovation", number: 901),
      line(bank.id, .borrowed, "20000", on: "2026-08-01", group: "Car", number: 902),
      line(bank.id, .payment, "7000", on: "2026-08-25", group: "Renovation", number: 903),
      line(bank.id, .payment, "7000", on: "2026-09-05", number: 904, transaction: 101),
      line(dollar.id, .borrowed, "1000", on: "2026-09-01", number: 911),
      line(euro.id, .borrowed, "500", on: "2026-09-01", number: 921),
      line(annaDebt.id, .borrowed, "5000", on: "2026-06-01", number: 931),
      line(annaDebt.id, .payment, "2000", on: "2026-07-01", number: 932),
      line(borisDebt.id, .borrowed, "20", on: "2026-08-01", number: 941),
      line(old.id, .borrowed, "3000", on: "2025-01-01", number: 951),
      line(old.id, .payment, "3000", on: "2025-12-01", number: 952),
    ]
    let entries = [
      // This month's payment of the bank loan.
      operation(101, on: "2026-09-05", debt: bank.id, parts: [part(1011, "7000")]),
      // A cinema: 1 200 of it for Anna, still expected.
      operation(
        102, on: "2026-08-14", note: "Cinema",
        parts: [
          part(1021, "1200", reimbursable: true, debtor: anna, status: .expected),
          part(1022, "1200"),
        ]),
      // 10 $ for Boris at 95: owed as 950 ₽.
      operation(
        103, on: "2026-07-20", currency: .usd,
        parts: [part(1031, "10", rub: "950", reimbursable: true, debtor: boris, note: "Book")]),
      // Returned and written off: no longer owed.
      operation(
        104, on: "2026-07-01",
        parts: [
          part(1041, "400", reimbursable: true, debtor: anna, status: .returned),
          part(1042, "100", reimbursable: true, debtor: anna, status: .writtenOff),
        ]),
      // Nobody named.
      operation(
        105, on: "2026-09-01",
        parts: [part(1051, "300", reimbursable: true, status: .expected)]),
      // Deleted: gone.
      operation(
        106, on: "2026-09-02", deleted: true,
        parts: [part(1061, "5000", reimbursable: true, debtor: anna, status: .expected)]),
    ]
    let book = PlanningBook(debtEntries: journal)
    let ledger = Ledger(
      dataset: Dataset(
        entries: entries, debts: [old, borisDebt, bank, annaDebt, euro, dollar], planning: book),
      calendar: .utc)
    return Section(
      anna: anna, boris: boris, bank: bank, dollar: dollar, euro: euro, annaDebt: annaDebt,
      borisDebt: borisDebt, old: old, ledger: ledger, book: book)
  }

  @Test func theDebtsIOweWithTheirJournals() throws {
    let fixture = section()
    let overview = DebtsOverview.build(
      ledger: fixture.ledger, book: fixture.book, today: day("2026-09-15"),
      rubPerUnit: [.usd: 95])

    // Nearest payment first: the euro loan is overdue since the 10th, the dollar loan is due
    // on the 28th, the bank loan's two payments closed 25 August and 25 September — next due
    // on 25 October.
    #expect(overview.iOwe.map(\.id) == [fixture.euro.id, fixture.dollar.id, fixture.bank.id])
    #expect(
      overview.iOwe.map(\.nextPayment) == [day("2026-09-10"), day("2026-09-28"), day("2026-10-25")])
    #expect(overview.iOwe.map(\.paidThisMonth) == [false, false, true])

    // 100 000 + 20 000 − 7 000 − 7 000 = 106 000.
    let bank = try #require(overview.iOwe.last)
    #expect(bank.balance == money("106000"))
    #expect(bank.balanceRub == money("106000"))
    // Renovation: 100 000 − 7 000; Car: 20 000; no group: −7 000.
    #expect(bank.groups.map(\.groupName) == ["Renovation", "Car", nil])
    #expect(bank.groups.map(\.totalE4) == [money("93000"), money("20000"), money("-7000")])
    #expect(bank.groups.map(\.count) == [2, 1, 1])
    // Newest first, the undated opening line last.
    #expect(bank.entries.map(\.id) == [id(904), id(903), id(902), id(901)])

    // 1 000 $ × 95 = 95 000 ₽; the euros have no rate.
    #expect(overview.iOwe[1].balance == money("1000"))
    #expect(overview.iOwe[1].balanceRub == money("95000"))
    #expect(overview.iOwe[0].balance == money("500"))
    #expect(overview.iOwe[0].balanceRub == nil)

    // 106 000 + 95 000, the euro loan left out and named.
    #expect(overview.totalIOweRub == money("201000"))
    // 7 000 + 100 × 95; the closed loan and the euros stay out.
    #expect(overview.monthlyPaymentsRub == money("16500"))
    #expect(overview.withoutRate == [fixture.euro.id])

    #expect(overview.closed.map(\.id) == [fixture.old.id])
    #expect(overview.closed.first?.balance == .zero)
    #expect(overview.closed.first?.nextPayment == nil)
  }

  /// A part of 1 500 that got 700 back is owed as the 800 left of it; a part covered in full by
  /// money back that did not close it is owed nothing and leaves the list.
  @Test func owedToMeListsWhatIsLeftOfEachPart() throws {
    let anna = id(40)
    let entries = [
      operation(
        201, on: "2026-09-01",
        parts: [part(2011, "1500", reimbursable: true, debtor: anna, status: .expected)]),
      operation(
        202, on: "2026-09-02",
        parts: [part(2021, "300", reimbursable: true, debtor: anna, status: .expected)]),
      operation(203, .reimbursement, on: "2026-09-10", parts: [part(2031, "1000")]),
    ]
    let links = [
      ReimbursementLink(reimbursementTxId: id(203), partId: id(2011), amountE4: money("700")),
      ReimbursementLink(reimbursementTxId: id(203), partId: id(2021), amountE4: money("300")),
    ]
    let ledger = Ledger(dataset: Dataset(entries: entries, links: links), calendar: .utc)
    let overview = DebtsOverview.build(
      ledger: ledger, book: PlanningBook(), today: day("2026-09-15"), rubPerUnit: [:])
    let group = try #require(overview.owedToMe.first)
    #expect(group.parts.map(\.partId) == [id(2011)])
    #expect(group.parts.map(\.amountRub) == [money("800")])
    #expect(group.parts.map(\.returnedRub) == [money("700")])
    #expect(overview.totalOwedToMeRub == money("800"))
  }

  @Test func owedToMeMergesPersonalDebtsAndPartsByPerson() throws {
    let fixture = section()
    let overview = DebtsOverview.build(
      ledger: fixture.ledger, book: fixture.book, today: day("2026-09-15"),
      rubPerUnit: [.usd: 95])

    // Anna: 5 000 − 2 000 = 3 000 of debt + 1 200 of the cinema = 4 200.
    // Boris: 20 $ × 95 = 1 900 + the 950 ₽ book = 2 850. Nobody: 300. Largest first, nobody last.
    #expect(overview.owedToMe.map(\.personId) == [fixture.anna, fixture.boris, nil])
    #expect(overview.owedToMe.map(\.totalRub) == [money("4200"), money("2850"), money("300")])
    #expect(overview.totalOwedToMeRub == money("7350"))

    let anna = overview.owedToMe[0]
    #expect(anna.debts.map(\.id) == [fixture.annaDebt.id])
    #expect(anna.debts.first?.balance == money("3000"))
    #expect(anna.parts.map(\.partId) == [id(1021)])
    #expect(anna.parts.first?.note == "Cinema")
    #expect(anna.parts.first?.day == day("2026-08-14"))
    #expect(anna.parts.first?.transactionId == id(102))
    #expect(anna.parts.first?.personId == fixture.anna)
    // The debt started on 1 June, before the cinema.
    #expect(anna.oldest == day("2026-06-01"))

    let boris = overview.owedToMe[1]
    #expect(boris.parts.map(\.amountRub) == [money("950")])
    #expect(boris.parts.first?.note == "Book")
    #expect(boris.debts.first?.balanceRub == money("1900"))
    #expect(boris.oldest == day("2026-07-20"))

    let nobody = overview.owedToMe[2]
    #expect(nobody.debts.isEmpty)
    #expect(nobody.parts.map(\.partId) == [id(1051)])
    #expect(nobody.oldest == day("2026-09-01"))

    // The parts are exactly what the Overview counts as owed to me.
    let summary = OverviewSummary(ledger: fixture.ledger, today: day("2026-09-15"))
    let parts = overview.owedToMe.flatMap(\.parts)
    #expect(AmountE4.sum(parts.map(\.amountRub)) == summary.owedToMe)
    #expect(parts.count == summary.owedCount)
  }

  @Test func withoutRatesForeignDebtsAreNamedNotGuessed() {
    let fixture = section()
    let overview = DebtsOverview.build(
      ledger: fixture.ledger, book: fixture.book, today: day("2026-09-15"), rubPerUnit: [:])
    // Only the bank loan converts: 106 000; the payments are the bank loan's 7 000.
    #expect(overview.totalIOweRub == money("106000"))
    #expect(overview.monthlyPaymentsRub == money("7000"))
    // Boris' 20 $ stay out; his 950 ₽ part — already rubles — stays in.
    #expect(overview.owedToMe.map(\.totalRub) == [money("4200"), money("950"), money("300")])
    #expect(overview.totalOwedToMeRub == money("5450"))
    #expect(
      Set(overview.withoutRate) == [fixture.dollar.id, fixture.euro.id, fixture.borisDebt.id])
    #expect(overview.withoutRate == overview.withoutRate.sorted { $0.uuidString < $1.uuidString })
  }

  /// «I owe» lists every open debt, one paid down to zero included: a credit card at zero, a
  /// debt waiting for its first line, a loan paid off from the entry line — hidden, none of
  /// them would be anywhere, neither its card nor «Close».
  @Test func anOpenDebtAtZeroStaysInItsList() {
    let card = loan(11, day: nil, name: "Card")
    let book = PlanningBook(debtEntries: [
      line(card.id, .adjustment, "5000", on: "2026-08-01"),
      line(card.id, .payment, "5000", on: "2026-09-01"),
    ])
    let overview = DebtsOverview.build(
      ledger: Ledger(dataset: Dataset(debts: [card], planning: book), calendar: .utc), book: book,
      today: day("2026-09-15"), rubPerUnit: [:])
    #expect(overview.iOwe.map(\.id) == [card.id])
    #expect(overview.iOwe.map(\.balance) == [.zero])
    #expect(overview.closed.isEmpty)
  }

  /// Rubles that do not fit into stored units are not made up either: the conversion stood in
  /// Int64.max for them — a figure nobody owes, which the next balance added to the total
  /// would overflow — instead of leaving the debt out as it does without a
  /// rate.
  @Test func rublesThatDoNotFitAreNotGuessed() {
    let huge = AmountE4(raw: .max / 10)
    #expect(DebtRubles.convert(huge, from: .usd, rubPerUnit: [.usd: 90]) == nil)
    #expect(DebtRubles.convert(-huge, from: .usd, rubPerUnit: [.usd: 90]) == nil)
    #expect(
      DebtRubles.convert(money("100"), from: .usd, rubPerUnit: [.usd: 90]) == money("9000"))
  }

  @Test func aPersonWithOnlyADebtOrOnlyPartsGetsAGroupOfTheirOwn() {
    let onlyDebt = Debt(
      id: id(8), direction: .owedToMe, type: .personal, name: "Vera", personId: id(42))
    let book = PlanningBook(debtEntries: [line(onlyDebt.id, .borrowed, "700", on: "2026-05-05")])
    let ledger = Ledger(
      dataset: Dataset(
        entries: [
          operation(
            301, on: "2026-09-03",
            parts: [part(3011, "250", reimbursable: true, debtor: id(43), status: .expected)])
        ],
        debts: [onlyDebt], planning: book),
      calendar: .utc)
    let overview = DebtsOverview.build(
      ledger: ledger, book: book, today: day("2026-09-15"), rubPerUnit: [:])
    #expect(overview.owedToMe.map(\.personId) == [id(42), id(43)])
    #expect(overview.owedToMe.map(\.totalRub) == [money("700"), money("250")])
    #expect(overview.owedToMe[0].parts.isEmpty)
    #expect(overview.owedToMe[1].debts.isEmpty)
    #expect(overview.iOwe.isEmpty)
    #expect(overview.totalIOweRub == .zero)
  }
}
