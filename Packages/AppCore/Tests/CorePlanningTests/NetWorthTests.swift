import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CorePlanning

/// Readable ids, days and amounts of the capital and cushion suites.
enum CapitalFx {
  static func id(_ number: Int) -> UUID {
    UUID(uuidString: String(format: "CA910000-0000-0000-0000-%012d", number)) ?? UUID()
  }

  static func day(_ iso: String) -> DateOnly {
    DateOnly(iso: iso) ?? DateOnly(year: 1970, month: 1, day: 1)
  }

  static func rub(_ text: String) -> AmountE4 { amountLiteral(text) }

  static func noon(_ iso: String) -> Date {
    CalendarContext.utc.startOfDay(day(iso)).addingTimeInterval(12 * 3600)
  }

  /// A count of accounts made at noon of `iso`, with its balances.
  static func count(
    _ number: Int, _ iso: String, _ balances: [(UUID, CurrencyCode, String)]
  ) -> (Reconciliation, [ReconciledBalance]) {
    let reconciliation = Reconciliation(
      id: id(5_000 + number), date: day(iso), reconciledAt: noon(iso), actualTotalRubE4: .zero,
      kind: .accounts)
    let rows = balances.enumerated().map { index, balance in
      ReconciledBalance(
        id: id(6_000 + number * 10 + index), reconciliationId: reconciliation.id,
        accountId: balance.0, currency: balance.1, actualE4: rub(balance.2))
    }
    return (reconciliation, rows)
  }

  /// One operation with one part, in rubles.
  static func operation(
    _ number: Int, _ iso: String, _ amount: String, kind: TransactionKind = .expense,
    category: UUID? = nil, method: UUID? = nil, debt: UUID? = nil, link: OperationLink? = nil,
    reimbursable: Bool = false
  ) -> TransactionEntry {
    let transactionId = id(100_000 + number)
    let when = noon(iso)
    return TransactionEntry(
      transaction: Transaction(
        id: transactionId, kind: kind, occurredAt: when, amountE4: rub(amount),
        paymentMethodId: method, debtId: debt, externalId: link?.externalId, createdAt: when,
        updatedAt: when),
      parts: [
        TransactionPart(
          id: id(200_000 + number), transactionId: transactionId, categoryId: category,
          quality: kind.hasQuality ? .neutral : nil,
          qualitySource: kind.hasQuality ? .category : nil, amountE4: rub(amount),
          reimbursable: reimbursable)
      ])
  }

  /// The capital of a dataset as the planning snapshot builds it.
  static func capital(
    _ dataset: Dataset, today: DateOnly, rates: [CurrencyCode: Decimal] = [:],
    dayRates: DayRates = .empty, months: Int? = NetWorth.defaultMonths
  ) -> CapitalSnapshot {
    let ledger = Ledger(dataset: dataset, calendar: .utc)
    let now = noon(today.iso)
    let accounts = AccountsSnapshot.build(
      dataset: dataset, now: now, calendar: .utc, rubPerUnit: rates, localeIdentifier: "en")
    return NetWorth.build(
      ledger: ledger, balances: accounts.balances, debtsJournal: dataset.planning.debtEntries,
      assets: dataset.assets, valuations: dataset.assetValuations, today: today, now: now,
      rubPerUnit: rates, dayRates: dayRates, months: months)
  }
}

@Suite("Net worth: the month ends and now")
struct NetWorthTests {
  typealias Fx = CapitalFx

  let today = Fx.day("2026-10-11")
  let main = Fx.id(1)
  let dollars = Fx.id(2)
  let savings = Fx.id(3)
  let broker = Fx.id(4)
  let old = Fx.id(5)
  let outGroup = Fx.id(20)

  func accounts() -> [PaymentMethod] {
    [
      PaymentMethod(id: main, name: "Main", isDefault: true),
      PaymentMethod(id: dollars, name: "Dollars", currency: .usd),
      PaymentMethod(
        id: savings, name: "Savings",
        interest: DepositTerms(rate: 10, period: .monthly), cushion: true),
      PaymentMethod(id: broker, name: "Broker", groupId: outGroup),
    ]
  }

  @Test func thePointsAreTheEndsOfTheFullMonthsSinceTheFirstCountAndNow() {
    let (count, rows) = Fx.count(1, "2026-07-15", [(main, .rub, "1000")])
    let dataset = Dataset(
      paymentMethods: accounts(),
      planning: PlanningBook(reconciliations: [count], reconciledBalances: rows))
    let capital = Fx.capital(dataset, today: today)
    #expect(
      capital.points.map(\.day) == [
        Fx.day("2026-07-31"), Fx.day("2026-08-31"), Fx.day("2026-09-30"), today,
      ])
    #expect(capital.points.map(\.isNow) == [false, false, false, true])
    #expect(capital.points.last == capital.now)
    #expect(capital.now.accountsRub == Fx.rub("1000"))

    let one = Fx.capital(dataset, today: today, months: 1)
    #expect(one.points.map(\.day) == [Fx.day("2026-09-30"), today])
    let all = Fx.capital(dataset, today: today, months: nil)
    #expect(all.points.count == 4)

    // Nothing counted: «now» alone.
    let empty = Fx.capital(Dataset(paymentMethods: accounts()), today: today)
    #expect(empty.points.map(\.day) == [today])
  }

  /// A month end is the last instant of the day: an operation at noon of the last day is in
  /// it, one the next morning is not.
  @Test func aMonthEndHoldsEverythingOfItsLastDay() {
    let (count, rows) = Fx.count(1, "2026-08-01", [(main, .rub, "1000")])
    let dataset = Dataset(
      entries: [
        Fx.operation(1, "2026-08-31", "100", method: main),
        Fx.operation(2, "2026-09-01", "50", method: main),
      ],
      paymentMethods: accounts(),
      planning: PlanningBook(reconciliations: [count], reconciledBalances: rows))
    let capital = Fx.capital(dataset, today: today)
    #expect(capital.points.first { $0.day == Fx.day("2026-08-31") }?.accountsRub == Fx.rub("900"))
    #expect(capital.points.first { $0.day == Fx.day("2026-09-30") }?.accountsRub == Fx.rub("850"))
    #expect(capital.changeThisMonth == .zero)
  }

  @Test func theBlocksAreDepositsTheGroupLeftOutAndTheRest() {
    let (count, rows) = Fx.count(
      1, "2026-09-10",
      [
        (main, .rub, "1000"), (savings, .rub, "5000"), (broker, .rub, "7000"),
        (dollars, .usd, "10"),
      ]
    )
    let dataset = Dataset(
      paymentMethods: accounts(),
      planning: PlanningBook(reconciliations: [count], reconciledBalances: rows),
      accountGroups: [AccountGroup(id: outGroup, name: "Out", inSummary: false)])
    let capital = Fx.capital(dataset, today: today, rates: [.usd: 90])
    #expect(capital.now.accountsRub == Fx.rub("1900"))
    #expect(capital.now.depositsRub == Fx.rub("5000"))
    #expect(capital.now.outOfSummaryRub == Fx.rub("7000"))
    #expect(capital.now.cushionRub == Fx.rub("5000"))
    #expect(capital.now.haveRub == Fx.rub("13900"))
    let groups = capital.breakdown.have.map(\.group)
    #expect(groups == [.accounts, .accounts, .deposits, .outOfSummary])
    #expect(capital.breakdown.have.first?.name == "Main")
    #expect(capital.breakdown.have.last?.accountGroupId == outGroup)
  }

  @Test func aBalanceNotCountedIsListedNeverGuessed() {
    let (count, rows) = Fx.count(1, "2026-09-10", [(main, .rub, "1000")])
    let dataset = Dataset(
      entries: [Fx.operation(1, "2026-08-20", "10", method: savings)],
      paymentMethods: accounts(),
      planning: PlanningBook(reconciliations: [count], reconciledBalances: rows))
    let capital = Fx.capital(dataset, today: today)
    let savingsKey = BalanceKey(accountId: savings, currency: .rub)
    let dollarsKey = BalanceKey(accountId: dollars, currency: .usd)
    #expect(capital.now.unanchored.contains(savingsKey))
    #expect(capital.now.unanchored.contains(dollarsKey))
    #expect(capital.now.accountsRub == Fx.rub("1000"))
    // At the end of September money had moved on the savings account and it was never
    // counted; the dollar account had nothing yet.
    let september = capital.points.first { $0.day == Fx.day("2026-09-30") }
    #expect(september?.unanchored == [savingsKey])
    let line = capital.breakdown.have.first { $0.source == .account(savings) }
    #expect(line?.issue == .unanchored)
    #expect(line?.amountRub == nil)
  }

  @Test func anArchivedAccountKeepsItsHistory() {
    let (count, rows) = Fx.count(1, "2026-08-10", [(main, .rub, "0"), (old, .rub, "3000")])
    var list = accounts()
    list.append(PaymentMethod(id: old, name: "Old", archived: true))
    let dataset = Dataset(
      paymentMethods: list,
      planning: PlanningBook(reconciliations: [count], reconciledBalances: rows),
      transfers: [
        Transfer(
          occurredAt: Fx.noon("2026-09-05"), fromAccountId: old, fromCurrency: .rub,
          fromAmountE4: Fx.rub("3000"), toAccountId: main, toCurrency: .rub,
          toAmountE4: Fx.rub("3000"))
      ])
    let capital = Fx.capital(dataset, today: today)
    #expect(capital.points.first?.day == Fx.day("2026-08-31"))
    #expect(capital.points.first?.accountsRub == Fx.rub("3000"))
    #expect(capital.now.accountsRub == Fx.rub("3000"))
    // At zero, the archived account is not a row of the breakdown.
    #expect(!capital.breakdown.have.contains { $0.source == .account(old) })
  }

  @Test func aForeignBalanceTakesTheRateOfItsDay() {
    let (count, rows) = Fx.count(1, "2026-08-10", [(dollars, .usd, "100")])
    let dataset = Dataset(
      paymentMethods: accounts(),
      planning: PlanningBook(reconciliations: [count], reconciledBalances: rows))
    let rates = DayRates(series: [
      .usd: [
        DayRate(day: Fx.day("2026-08-20"), perUnit: 90),
        DayRate(day: Fx.day("2026-09-29"), perUnit: 95.5),
      ]
    ])
    let capital = Fx.capital(dataset, today: today, rates: [.usd: 100], dayRates: rates)
    #expect(capital.points.map(\.accountsRub) == [Fx.rub("9000"), Fx.rub("9550"), Fx.rub("10000")])
    #expect(capital.changeThisMonth == Fx.rub("450"))

    // Without a rate the money is in no figure, and its currency is said.
    let none = Fx.capital(dataset, today: today)
    #expect(none.now.accountsRub == .zero)
    #expect(none.now.withoutRate == [.usd])
    #expect(none.points.first?.withoutRate == [.usd])
    let line = none.breakdown.have.first { $0.source == .account(dollars) }
    #expect(line?.issue == .withoutRate)
    #expect(line?.amount == Fx.rub("100"))
    #expect(line?.amountRub == nil)
  }

  @Test func anAssetIsWorthItsLastValuationOnOrBeforeTheDay() {
    let car = Asset(id: Fx.id(30), name: "Car", kind: .vehicle)
    let flat = Asset(id: Fx.id(31), name: "Flat", kind: .realty, currency: .usd)
    let sold = Asset(id: Fx.id(32), name: "Bike", disposedOn: Fx.day("2026-09-15"))
    let fresh = Asset(id: Fx.id(33), name: "Laptop", kind: .equipment)
    let valuations = [
      AssetValuation(assetId: car.id, day: Fx.day("2026-07-01"), valueE4: Fx.rub("1000000")),
      AssetValuation(assetId: car.id, day: Fx.day("2026-09-01"), valueE4: Fx.rub("900000")),
      AssetValuation(assetId: car.id, day: Fx.day("2026-10-20"), valueE4: Fx.rub("1")),
      AssetValuation(assetId: flat.id, day: Fx.day("2026-08-15"), valueE4: Fx.rub("1000")),
      AssetValuation(assetId: sold.id, day: Fx.day("2026-07-01"), valueE4: Fx.rub("20000")),
    ]
    let (count, rows) = Fx.count(1, "2026-07-10", [(main, .rub, "0")])
    let dataset = Dataset(
      paymentMethods: accounts(),
      planning: PlanningBook(reconciliations: [count], reconciledBalances: rows),
      assets: [car, flat, sold, fresh], assetValuations: valuations)
    let rates = DayRates(series: [.usd: [DayRate(day: Fx.day("2026-08-01"), perUnit: 90)]])
    let capital = Fx.capital(dataset, today: today, rates: [.usd: 100], dayRates: rates)
    #expect(
      capital.points.map(\.assetsRub) == [
        Fx.rub("1020000"), Fx.rub("1110000"), Fx.rub("990000"), Fx.rub("1000000"),
      ])
    #expect(capital.now.unvalued == [fresh.id])
    #expect(capital.points.first?.unvalued == [])
    let names = capital.breakdown.have.filter { $0.group == .assets }.map(\.name)
    // By kind: vehicle, realty, equipment.
    #expect(names == ["Car", "Flat", "Laptop"])
    #expect(capital.breakdown.have.first { $0.name == "Laptop" }?.issue == .unvalued)
  }

  @Test func theDebtsCountByTheirJournalsDatedByTheDay() {
    let loan = Debt(id: Fx.id(40), direction: .iOwe, type: .loan, name: "Loan")
    let lent = Debt(id: Fx.id(41), direction: .owedToMe, type: .personal, name: "Anna")
    let closed = Debt(
      id: Fx.id(42), direction: .iOwe, type: .personal, name: "Closed", closed: true)
    let gone = Debt(
      id: Fx.id(43), direction: .iOwe, type: .personal, name: "Gone",
      deletedAt: Fx.noon("2026-09-01"))
    let dollarDebt = Debt(
      id: Fx.id(44), direction: .iOwe, type: .personal, name: "Bob", currency: .usd)
    let journal = [
      DebtEntry(
        debtId: loan.id, date: Fx.day("2026-07-05"), amountE4: Fx.rub("100000"), kind: .borrowed),
      DebtEntry(
        debtId: loan.id, date: Fx.day("2026-09-05"), amountE4: Fx.rub("-10000"), kind: .payment),
      DebtEntry(
        debtId: loan.id, date: Fx.day("2026-11-05"), amountE4: Fx.rub("-10000"), kind: .payment),
      DebtEntry(
        debtId: lent.id, date: Fx.day("2026-08-05"), amountE4: Fx.rub("3000"), kind: .borrowed),
      DebtEntry(
        debtId: closed.id, date: Fx.day("2026-07-05"), amountE4: Fx.rub("500"), kind: .borrowed),
      DebtEntry(
        debtId: closed.id, date: Fx.day("2026-08-20"), amountE4: Fx.rub("-400"), kind: .payment),
      DebtEntry(
        debtId: gone.id, date: Fx.day("2026-07-05"), amountE4: Fx.rub("777"), kind: .borrowed),
      DebtEntry(
        debtId: dollarDebt.id, date: Fx.day("2026-07-05"), amountE4: Fx.rub("10"), kind: .borrowed),
    ]
    let (count, rows) = Fx.count(1, "2026-07-10", [(main, .rub, "0")])
    let dataset = Dataset(
      paymentMethods: accounts(), debts: [loan, lent, closed, dollarDebt],
      planning: PlanningBook(
        reconciliations: [count], debtEntries: journal, reconciledBalances: rows),
      deletedDebts: [gone])
    let rates = DayRates(series: [.usd: [DayRate(day: Fx.day("2026-07-01"), perUnit: 90)]])
    let capital = Fx.capital(dataset, today: today, rates: [.usd: 100], dayRates: rates)
    // July: loan 100,000 + closed 500 + 900 ₽ of dollars; from August, after the last day of
    // its journal, the closed debt is nothing.
    #expect(
      capital.points.map(\.iOweRub) == [
        Fx.rub("101400"), Fx.rub("100900"), Fx.rub("90900"), Fx.rub("91000"),
      ])
    let july = capital.points.first?.day ?? today
    let closedInJuly = DebtBalanceAt.balance(
      of: closed, journal: journal, through: july, calendar: .utc)
    #expect(closedInJuly == Fx.rub("500"))
    #expect(
      capital.points.map(\.owedToMeRub) == [.zero, Fx.rub("3000"), Fx.rub("3000"), Fx.rub("3000")])
    #expect(capital.breakdown.owe.map(\.name) == ["Bob", "Loan"])
    #expect(capital.breakdown.have.last?.group == .owedToMe)
    // The money lent left the main account: −3,000 there, 3,000 owed to me.
    #expect(capital.now.accountsRub == Fx.rub("-3000"))
    #expect(capital.now.netRub == Fx.rub("-91000"))
  }

  /// A loan that accrues interest owes the interest its journal charged and the interest
  /// accrued since the last payment.
  @Test func aLoanWithInterestOwesItsInterestThroughTheDay() {
    let loan = Debt(
      id: Fx.id(50), direction: .iOwe, type: .loan, name: "Bank", interestRate: 12,
      monthlyPaymentE4: Fx.rub("10000"), paymentDay: 5, accruesInterest: true)
    let journal = [
      DebtEntry(
        debtId: loan.id, date: Fx.day("2026-07-05"), amountE4: Fx.rub("100000"), kind: .borrowed),
      DebtEntry(
        debtId: loan.id, date: Fx.day("2026-08-05"), amountE4: Fx.rub("-10000"), kind: .payment),
    ]
    let (count, rows) = Fx.count(1, "2026-07-10", [(main, .rub, "0")])
    let dataset = Dataset(
      paymentMethods: accounts(), debts: [loan],
      planning: PlanningBook(
        reconciliations: [count], debtEntries: journal, reconciledBalances: rows))
    let capital = Fx.capital(dataset, today: today)
    for point in capital.points {
      let owed = DebtBalanceAt.owed(of: loan, journal: journal, through: point.day, calendar: .utc)
      #expect(point.iOweRub == owed.balance + owed.accruedE4, "\(point.day)")
      #expect(owed.accruedE4.raw > 0, "\(point.day)")
    }
    // More than the 90,000 of the journal: the interest is owed too.
    #expect(capital.now.iOweRub > Fx.rub("90000"))
    let line = capital.breakdown.owe.first
    #expect(line?.interestRub.map { $0.raw > 0 } == true)
  }

  @Test func throughTodayTheBalanceIsTheOneOfTheDebtsScreen() {
    let loan = Debt(
      id: Fx.id(60), direction: .iOwe, type: .loan, name: "Bank", interestRate: 15,
      monthlyPaymentE4: Fx.rub("5000"), paymentDay: 10, accruesInterest: true)
    let journal = [
      DebtEntry(
        debtId: loan.id, date: Fx.day("2026-05-10"), amountE4: Fx.rub("50000"), kind: .borrowed),
      DebtEntry(
        debtId: loan.id, date: Fx.day("2026-06-10"), amountE4: Fx.rub("-5000"), kind: .payment),
      DebtEntry(
        debtId: loan.id, date: Fx.day("2026-07-10"), amountE4: Fx.rub("-5000"), kind: .payment),
      DebtEntry(
        debtId: loan.id, amountE4: Fx.rub("-1000"), kind: .payment,
        occurredAt: Fx.noon("2026-08-10")),
    ]
    let ledger = Ledger(
      dataset: Dataset(debts: [loan], planning: PlanningBook(debtEntries: journal)),
      calendar: .utc)
    let overview = DebtsOverview.build(
      ledger: ledger, book: ledger.dataset.planning, today: today, rubPerUnit: [:])
    let owed = DebtBalanceAt.owed(of: loan, journal: journal, through: today, calendar: .utc)
    #expect(overview.iOwe.first?.balance == owed.balance)
    #expect(overview.iOwe.first?.accruedInterestE4 == owed.accruedE4)
    // A line dated by its moment alone counts from its day: what is owed drops by the
    // payment, less the interest of one more day.
    func owedOn(_ iso: String) -> AmountE4 {
      let owed = DebtBalanceAt.owed(
        of: loan, journal: journal, through: Fx.day(iso), calendar: .utc)
      return owed.balance + owed.accruedE4
    }
    let drop = owedOn("2026-08-09") - owedOn("2026-08-10")
    #expect(drop > Fx.rub("900"))
    #expect(drop < Fx.rub("1000"))
  }

  /// Parts paid for somebody else wait in «Мне должны» of the Debts screen, not in the capital.
  @Test func aPartPaidForSomebodyElseIsNotOwedToMe() {
    let (count, rows) = Fx.count(1, "2026-09-01", [(main, .rub, "5000")])
    let dataset = Dataset(
      entries: [Fx.operation(1, "2026-09-10", "1000", method: main, reimbursable: true)],
      paymentMethods: accounts(),
      planning: PlanningBook(reconciliations: [count], reconciledBalances: rows))
    let capital = Fx.capital(dataset, today: today)
    #expect(capital.now.owedToMeRub == .zero)
    #expect(capital.now.accountsRub == Fx.rub("4000"))
  }

  @Test func aDepositShowsTheInterestItAccruedWithoutCountingIt() {
    let (count, rows) = Fx.count(1, "2026-09-01", [(savings, .rub, "1000000")])
    let dataset = Dataset(
      paymentMethods: accounts(),
      planning: PlanningBook(reconciliations: [count], reconciledBalances: rows))
    let capital = Fx.capital(dataset, today: today)
    #expect(capital.now.depositsRub == Fx.rub("1000000"))
    let line = capital.breakdown.have.first { $0.group == .deposits }
    #expect(line?.accruedNotCountedRub.map { $0.raw > 0 } == true)
  }
}
