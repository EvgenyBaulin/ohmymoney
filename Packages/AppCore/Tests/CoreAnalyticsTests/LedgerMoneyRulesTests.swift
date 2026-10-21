import CoreAccounting
import CoreKit
import CorePlanning
import Foundation
import Testing

@testable import CoreAnalytics

/// A small book of accounts, operations, transfers and counts, written by hand for the rules of
/// money that the ledger and the balances have to agree on.
private struct MoneyBook {
  static let kzt = CurrencyCode("KZT")
  let groceries = id(10)
  let clothes = id(11)
  let goals = id(20)
  let trip = id(21)
  let salary = id(31)
  let surcharges = id(32)
  let card = PaymentMethod(id: id(1), name: "Card", currency: .rub, isDefault: true)
  let kaspi = PaymentMethod(id: id(2), name: "Kaspi", currency: kzt, groupId: id(90))
  let kazakhstan = AccountGroup(id: id(90), name: "Kazakhstan", inSummary: false)
  let anya = id(300)

  var entries: [TransactionEntry] = []
  var links: [ReimbursementLink] = []
  var transfers: [Transfer] = []
  var debts: [Debt] = []
  var events: [Event] = []
  var reconciliations: [Reconciliation] = []
  var counted: [ReconciledBalance] = []
  var goalsList: [Goal] = []

  var categories: [CoreKit.Category] {
    [
      CoreKit.Category(id: groceries, kind: .expense, name: "Groceries", quality: .neutral),
      CoreKit.Category(id: clothes, kind: .expense, name: "Clothes", quality: .neutral),
      CoreKit.Category(
        id: goals, kind: .expense, name: "Goals", quality: .good, systemRole: .goals),
      CoreKit.Category(id: trip, parentId: goals, kind: .expense, name: "Trip"),
      CoreKit.Category(id: salary, kind: .income, name: "Salary"),
      CoreKit.Category(
        id: surcharges, kind: .income, name: "Surcharges", systemRole: .surcharges),
    ]
  }

  static func at(_ iso: String, hour: Int = 12) -> Date {
    CalendarContext.utc.startOfDay(day(iso)).addingTimeInterval(TimeInterval(hour * 3600))
  }

  static func rub(_ whole: Int) -> AmountE4 { AmountE4(whole: Int64(whole)) }

  /// An operation of one part (`number * 10`), or of the parts given.
  @discardableResult
  mutating func operation(
    _ number: Int, _ kind: TransactionKind, _ iso: String, _ amount: AmountE4, hour: Int = 12,
    currency: CurrencyCode = .rub, rub: AmountE4? = nil, account: UUID? = id(1),
    leg: (CurrencyCode, AmountE4)? = nil, category: UUID? = nil, refunding: UUID? = nil,
    forOthers: ReimbursementStatus? = nil, debtId: UUID? = nil, creditDebtId: UUID? = nil,
    externalId: String? = nil, parts: [(AmountE4, UUID?)]? = nil
  ) -> TransactionEntry {
    let when = Self.at(iso, hour: hour)
    let rubles = rub ?? amount
    let pieces = parts ?? [(amount, kind == .reimbursement ? category : (category ?? groceries))]
    let amounts = pieces.map(\.0)
    let shares = rubles.allocated(proportionallyTo: amounts, outOf: AmountE4.sum(amounts))
    let transaction = Transaction(
      id: id(number), kind: kind, occurredAt: when, currency: currency,
      amountE4: AmountE4.sum(amounts),
      rate: currency == .rub ? nil : rubles.decimal / amount.decimal,
      amountRubE4: rubles, paymentMethodId: account, accountCurrency: leg?.0,
      accountAmountE4: leg?.1, debtId: debtId, creditDebtId: creditDebtId, externalId: externalId,
      createdAt: when, updatedAt: when)
    let entry = TransactionEntry(
      transaction: transaction,
      parts: pieces.enumerated().map { index, piece in
        TransactionPart(
          id: id(number * 10 + index), transactionId: id(number), categoryId: piece.1,
          amountE4: piece.0, amountRubE4: shares[index],
          forWhom: forOthers == nil ? .me : .friends, reimbursable: forOthers != nil,
          debtorPersonId: forOthers == nil ? nil : anya, reimbursementStatus: forOthers,
          refundOfPartId: refunding)
      })
    entries.append(entry)
    return entry
  }

  mutating func count(_ number: Int, _ iso: String, hour: Int = 9, _ rows: [(BalanceKey, AmountE4)])
  {
    let when = Self.at(iso, hour: hour)
    reconciliations.append(
      Reconciliation(
        id: id(number), date: day(iso), reconciledAt: when, actualTotalRubE4: .zero,
        kind: .accounts))
    for (index, row) in rows.enumerated() {
      counted.append(
        ReconciledBalance(
          id: id(number * 100 + index), reconciliationId: id(number),
          accountId: row.0.accountId, currency: row.0.currency, actualE4: row.1))
    }
  }

  var dataset: Dataset {
    Dataset(
      entries: entries, links: links, categories: categories, events: events,
      paymentMethods: [card, kaspi], debts: debts, goals: goalsList,
      planning: PlanningBook(reconciliations: reconciliations, reconciledBalances: counted),
      transfers: transfers, accountGroups: [kazakhstan])
  }

  var ledger: Ledger { Ledger(dataset: dataset, calendar: .utc) }

  func balances(now iso: String, hour: Int = 23) -> AccountBalances {
    AccountBalances.build(
      entries: entries, transfers: transfers, debtEntries: [],
      debts: Dictionary(uniqueKeysWithValues: debts.map { ($0.id, $0) }),
      reconciliations: reconciliations, balances: counted, accounts: [card, kaspi],
      tree: CategoryTree(categories), now: Self.at(iso, hour: hour), calendar: .utc)
  }

  func snapshot(now iso: String, rates: [CurrencyCode: Decimal]) -> AccountsSnapshot {
    AccountsSnapshot.build(
      dataset: dataset, now: Self.at(iso, hour: 23), calendar: .utc, rubPerUnit: rates,
      localeIdentifier: "en_US")
  }

  var cardRub: BalanceKey { BalanceKey(accountId: card.id, currency: .rub) }
  var kaspiKzt: BalanceKey { BalanceKey(accountId: kaspi.id, currency: Self.kzt) }
}

private func month(_ iso: String) -> DayRange {
  let first = day(iso + "-01")
  return DayRange(first, first.adding(months: 1).adding(days: -1))
}

private let rub = MoneyBook.rub

/// A refund taken back from a purchase counts in the purchase's day and month, while the money
/// comes onto the account at the refund's own moment.
@Suite("A refund: the month of the purchase, the moment of the money")
struct RefundMonthAndMomentTests {
  /// 10 000 bought on 28 March, 4 000 of it back on 3 April: March spent 6 000 and April
  /// nothing, while the card holds 40 000 until the moment of the refund and 44 000 after it.
  @Test func aRefundNextMonthCheapensThePurchasesMonthAndMovesTheCardOnItsOwnDay() {
    var book = MoneyBook()
    book.count(90, "2026-03-01", [(book.cardRub, rub(50_000))])
    let coat = book.operation(1, .expense, "2026-03-28", rub(10_000), category: book.clothes)
    book.operation(
      2, .refund, "2026-04-03", rub(4000), hour: 15, category: book.clothes,
      refunding: coat.parts[0].id)
    let ledger = book.ledger
    #expect(ledger.expenses(in: month("2026-03")) == rub(6000))
    #expect(ledger.expenses(in: month("2026-04")) == .zero)
    #expect(ledger.row(ofPart: coat.parts[0].id)?.month == MonthKey(year: 2026, month: 3))
    #expect(ledger.row(ofPart: id(20))?.day == day("2026-04-03"))

    let balances = book.balances(now: "2026-04-30")
    #expect(balances.balance(book.cardRub, at: MoneyBook.at("2026-03-31", hour: 23)) == rub(40_000))
    #expect(balances.balance(book.cardRub, at: MoneyBook.at("2026-04-03", hour: 14)) == rub(40_000))
    #expect(balances.balance(book.cardRub, at: MoneyBook.at("2026-04-03", hour: 15)) == rub(44_000))
    #expect(balances[book.cardRub]?.amountE4 == rub(44_000))
  }

  /// Two partial refunds in two later months both come off the purchase's month; each later
  /// month shows nothing of them, and the category of the purchase shrinks in its own month.
  @Test func partialRefundsInLaterMonthsAllComeOffThePurchasesMonth() {
    var book = MoneyBook()
    let shoes = book.operation(1, .expense, "2026-03-10", rub(3000), category: book.clothes)
    book.operation(
      2, .refund, "2026-04-02", rub(1000), category: book.clothes, refunding: shoes.parts[0].id)
    book.operation(
      3, .refund, "2026-05-20", rub(500), category: book.clothes, refunding: shoes.parts[0].id)
    let ledger = book.ledger
    #expect(ledger.expenses(in: month("2026-03")) == rub(1500))
    #expect(ledger.expenses(in: month("2026-04")) == .zero)
    #expect(ledger.expenses(in: month("2026-05")) == .zero)
    let march = CategoryBreakdown(
      ledger: ledger, period: .month(MonthKey(year: 2026, month: 3)), kind: .expense)
    #expect(march.nodes.first { $0.key == .category(book.clothes) }?.amount == rub(1500))
  }

  /// Deleting the refund gives the purchase's month its money back, and takes the refund's money
  /// off the card again.
  @Test func deletingTheRefundUndoesBothItsFoldAndItsMoney() {
    var book = MoneyBook()
    book.count(90, "2026-03-01", [(book.cardRub, rub(20_000))])
    let lamp = book.operation(1, .expense, "2026-03-05", rub(2000))
    book.operation(2, .refund, "2026-03-20", rub(2000), refunding: lamp.parts[0].id)
    #expect(book.ledger.expenses(in: month("2026-03")) == .zero)
    #expect(book.balances(now: "2026-03-31")[book.cardRub]?.amountE4 == rub(20_000))
    book.entries[1].transaction.deletedAt = MoneyBook.at("2026-03-21")
    #expect(book.ledger.expenses(in: month("2026-03")) == rub(2000))
    #expect(book.balances(now: "2026-03-31")[book.cardRub]?.amountE4 == rub(18_000))
  }

  /// A refund of one part of a split purchase takes back from that part's category only.
  @Test func aRefundOfOnePartOfASplitCheapensOnlyThatPart() {
    var book = MoneyBook()
    let basket = book.operation(
      1, .expense, "2026-03-05", rub(5000),
      parts: [(rub(3000), book.groceries), (rub(2000), book.clothes)])
    book.operation(
      2, .refund, "2026-03-25", rub(2000), category: book.clothes, refunding: basket.parts[1].id)
    let march = CategoryBreakdown(
      ledger: book.ledger, period: .month(MonthKey(year: 2026, month: 3)), kind: .expense)
    #expect(march.nodes.first { $0.key == .category(book.groceries) }?.amount == rub(3000))
    #expect(march.nodes.first { $0.key == .category(book.clothes) }?.amount ?? .zero == .zero)
  }

  /// A dollar purchase on a ruble card is refunded at the purchase's rate: the whole refund takes
  /// the purchase to zero exactly, while the card receives what the bank credited on the day of
  /// the refund — the rate moved, and the card shows it.
  @Test func aForeignRefundZeroesThePurchaseWhileTheCardGetsWhatTheBankCredited() {
    var book = MoneyBook()
    book.count(90, "2026-03-01", [(book.cardRub, rub(20_000))])
    let jacket = book.operation(
      1, .expense, "2026-03-05", rub(100), currency: .usd, rub: rub(9150), leg: (.rub, rub(9150)))
    book.operation(
      2, .refund, "2026-03-25", rub(100), currency: .usd, rub: rub(9150), leg: (.rub, rub(9400)),
      refunding: jacket.parts[0].id)
    #expect(book.ledger.expenses(in: month("2026-03")) == .zero)
    #expect(book.ledger.row(ofPart: jacket.parts[0].id)?.refundedRubE4 == rub(9150))
    #expect(book.balances(now: "2026-03-31")[book.cardRub]?.amountE4 == rub(20_250))
  }
}

/// Income never has a place, an event, «на кого», a person or «за другого»: whatever an older
/// income stored of them stays in the database and is ignored everywhere.
@Suite("Income read without what income cannot have")
struct IncomeMaskTests {
  private func book() -> MoneyBook {
    var book = MoneyBook()
    book.events = [
      Event(id: id(400), name: "Trip", startDate: day("2026-03-01"), endDate: day("2026-03-31"))
    ]
    var salary = book.operation(1, .income, "2026-03-05", rub(90_000), category: book.salary)
    salary.transaction.placeId = id(500)
    salary.transaction.creditDebtId = id(700)
    salary.parts[0].eventId = id(400)
    salary.parts[0].forWhom = .partner
    salary.parts[0].forPersonId = book.anya
    salary.parts[0].reimbursable = true
    salary.parts[0].reimbursementStatus = .expected
    salary.parts[0].debtorPersonId = book.anya
    book.entries[0] = salary
    var dinner = book.operation(2, .expense, "2026-03-06", rub(1200))
    dinner.transaction.placeId = id(500)
    dinner.parts[0].eventId = id(400)
    book.entries[1] = dinner
    return book
  }

  /// The place, the event and the people of an income are not in their sections; the income is
  /// still income, and still money on the card.
  @Test func anOldIncomeKeepsItsMoneyAndLosesItsCuts() {
    let book = book()
    let ledger = book.ledger
    let period = Period.month(MonthKey(year: 2026, month: 3))
    #expect(ledger.income(in: period) == rub(90_000))
    let places = PlacesReport(ledger: ledger, period: period)
    #expect(places.places.map(\.placeId) == [id(500)])
    #expect(places.places.first?.mySpending == rub(1200))
    #expect(places.places.first?.purchases == 1)
    let events = EventsReport(ledger: ledger, period: period)
    #expect(events.events.first?.total == rub(1200))
    let forWhom = ForWhomReport(ledger: ledger, period: period)
    #expect(forWhom.values.map(\.key) == [.forWhom(.me)])
    // Anya of the income is no one's line, and the dinner that names nobody is my own spending,
    // which has no line among the people either.
    #expect(forWhom.people.map(\.key) == [])
    let overview = OverviewSummary(ledger: ledger, today: day("2026-03-31"))
    #expect(overview.owedToMe == .zero)
    #expect(overview.owedCount == 0)
    #expect(OthersReport(ledger: ledger, period: period).totals.paid == .zero)
    let row = ledger.row(ofPart: id(10))
    #expect(row?.placeId == nil && row?.eventId == nil && row?.forWhom == .me)
    #expect(row?.forPersonId == nil && row?.debtorPersonId == nil && row?.reimbursable == false)
    #expect(row?.creditDebtId == nil)
    #expect(book.balances(now: "2026-03-31")[book.cardRub]?.movedSinceAnchor == rub(88_800))
    // The stored operation is not touched.
    #expect(ledger.entry(id(1))?.transaction.placeId == id(500))
    #expect(ledger.entry(id(1))?.parts.first?.forWhom == .partner)
  }
}

/// A group of accounts left out of the summary keeps its money out of «Всего», while what was
/// spent from it still counts everywhere.
@Suite("A group left out of the summary")
struct ExcludedGroupMoneyTests {
  let rates: [CurrencyCode: Decimal] = [MoneyBook.kzt: Decimal(string: "0.2") ?? 0]

  /// 5 000 tenge spent from Kaspi — 1 000 rubles — are 1 000 rubles of spending in the Overview,
  /// and change the Kazakhstan total, not «Всего».
  @Test func spendingFromAnExcludedAccountCountsButItsMoneyStaysApart() {
    var book = MoneyBook()
    book.count(90, "2026-03-01", [(book.cardRub, rub(50_000)), (book.kaspiKzt, rub(100_000))])
    book.operation(
      1, .expense, "2026-03-05", rub(5000), currency: MoneyBook.kzt, rub: rub(1000), account: id(2))
    let overview = OverviewSummary(ledger: book.ledger, today: day("2026-03-10"))
    #expect(overview.expenses.current == rub(1000))
    let snapshot = book.snapshot(now: "2026-03-10", rates: rates)
    #expect(snapshot.inSummaryTotalRub == rub(50_000))
    #expect(snapshot.excluded.first?.totalRub == rub(19_000))
    #expect(snapshot.line(of: id(2))?.keys.first?.balance == rub(95_000))
    #expect(!snapshot.isInSummary(id(2)))
    #expect(snapshot.isInSummary(id(1)))
  }

  /// Money sent from the card to Kaspi leaves «Всего» and joins the Kazakhstan total; it is
  /// neither income nor spending.
  @Test func aTransferIntoTheExcludedGroupLeavesTheSummary() {
    var book = MoneyBook()
    book.count(90, "2026-03-01", [(book.cardRub, rub(50_000)), (book.kaspiKzt, rub(100_000))])
    book.transfers.append(
      Transfer(
        id: id(70), occurredAt: MoneyBook.at("2026-03-05"), fromAccountId: id(1),
        fromCurrency: .rub, fromAmountE4: rub(10_000), toAccountId: id(2),
        toCurrency: MoneyBook.kzt, toAmountE4: rub(50_000)))
    let snapshot = book.snapshot(now: "2026-03-10", rates: rates)
    #expect(snapshot.inSummaryTotalRub == rub(40_000))
    #expect(snapshot.excluded.first?.totalRub == rub(30_000))
    let ledger = book.ledger
    #expect(ledger.expenses(in: month("2026-03")) == .zero)
    #expect(ledger.income(in: .month(MonthKey(year: 2026, month: 3))) == .zero)
  }
}

/// A part paid for somebody else is not my spending, but its money left the card; money back
/// brings money onto the card and closes what it covers; what is written off becomes spending
/// without moving any money.
@Suite("Paid for somebody else, from the purchase to the write-off")
struct PaidForOthersMoneyTests {
  @Test func eachStepMovesTheFiguresItShould() {
    var book = MoneyBook()
    book.count(90, "2026-03-01", [(book.cardRub, rub(10_000))])
    // 3 000 at the restaurant, 1 000 of it for Anya.
    let dinner = book.operation(
      1, .expense, "2026-03-05", rub(3000),
      parts: [(rub(2000), book.groceries), (rub(1000), book.groceries)])
    book.entries[0].parts[1].reimbursable = true
    book.entries[0].parts[1].reimbursementStatus = .expected
    book.entries[0].parts[1].debtorPersonId = book.anya
    let anyasPart = dinner.parts[1].id
    var overview = OverviewSummary(ledger: book.ledger, today: day("2026-03-31"))
    #expect(overview.expenses.current == rub(2000))
    #expect(overview.owedToMe == rub(1000))
    #expect(book.balances(now: "2026-03-31")[book.cardRub]?.amountE4 == rub(7000))

    // 400 back from Anya: the part keeps waiting with 600.
    var moneyBack = book.operation(2, .reimbursement, "2026-03-10", rub(400), category: nil)
    moneyBack.parts[0].forPersonId = book.anya
    book.entries[1] = moneyBack
    book.links.append(
      ReimbursementLink(reimbursementTxId: id(2), partId: anyasPart, amountE4: rub(400)))
    overview = OverviewSummary(ledger: book.ledger, today: day("2026-03-31"))
    #expect(overview.expenses.current == rub(2000))
    #expect(overview.owedToMe == rub(600))
    #expect(book.ledger.income(in: .month(MonthKey(year: 2026, month: 3))) == .zero)
    #expect(book.balances(now: "2026-03-31")[book.cardRub]?.amountE4 == rub(7400))
    let others = OthersReport(ledger: book.ledger, period: .month(MonthKey(year: 2026, month: 3)))
    #expect(others.totals.paid == rub(1000))
    #expect(others.totals.returned == rub(400))
    #expect(others.totals.waiting == rub(600))
    #expect(others.totals.shortfall == .zero)

    // «Списать остаток»: 600 become my spending, and no money moves.
    book.entries[0].parts[1].reimbursementStatus = .returned
    book.operation(
      3, .expense, "2026-03-20", rub(600),
      externalId: MoneyBack.writeOffKey(part: anyasPart, operation: id(3)))
    overview = OverviewSummary(ledger: book.ledger, today: day("2026-03-31"))
    #expect(overview.expenses.current == rub(2600))
    #expect(overview.owedToMe == .zero)
    #expect(book.balances(now: "2026-03-31")[book.cardRub]?.amountE4 == rub(7400))
    let closed = OthersReport(ledger: book.ledger, period: .month(MonthKey(year: 2026, month: 3)))
    #expect(closed.totals.waiting == .zero)
    #expect(closed.totals.writtenOff == rub(600))
    #expect(closed.totals.returned == rub(400))
  }

  /// Money back over what is owed: the surplus is income in «Доплаты» and is inside the money
  /// that came onto the card — the card moves by the money back once, not twice.
  @Test func theSurplusIsIncomeButNoSecondMoney() {
    var book = MoneyBook()
    book.count(90, "2026-03-01", [(book.cardRub, rub(10_000))])
    let taxi = book.operation(1, .expense, "2026-03-05", rub(1000), forOthers: .returned)
    book.operation(2, .reimbursement, "2026-03-10", rub(1300), category: nil)
    book.links.append(
      ReimbursementLink(reimbursementTxId: id(2), partId: taxi.parts[0].id, amountE4: rub(1000)))
    book.operation(
      3, .income, "2026-03-10", rub(300), category: book.surcharges,
      externalId: ReimbursementCompanions.surplusKey(of: id(2)))
    let ledger = book.ledger
    let march = Period.month(MonthKey(year: 2026, month: 3))
    #expect(ledger.income(in: march) == rub(300))
    #expect(ledger.expenses(in: month("2026-03")) == .zero)
    #expect(OthersReport(ledger: ledger, period: march).surplus == rub(300))
    #expect(book.balances(now: "2026-03-31")[book.cardRub]?.amountE4 == rub(10_300))
  }
}

/// A purchase on credit is spending once, at the purchase, and moves no money; its payments move
/// money and are no spending. A debt that existed before is the other way round.
@Suite("Purchases on credit")
struct CreditPurchaseMoneyTests {
  @Test func aPurchaseInInstalmentsIsSpentOnceAndPaidFromTheCard() {
    var book = MoneyBook()
    let laptop = Debt(
      id: id(201), direction: .iOwe, type: .installment, name: "Laptop",
      paymentsAreExpenses: false, origin: .purchase)
    book.debts = [laptop]
    book.count(90, "2026-03-01", [(book.cardRub, rub(50_000))])
    book.operation(1, .expense, "2026-03-05", rub(30_000), creditDebtId: laptop.id)
    book.operation(2, .expense, "2026-04-05", rub(10_000), debtId: laptop.id)
    book.operation(3, .expense, "2026-05-05", rub(10_000), debtId: laptop.id)
    let ledger = book.ledger
    #expect(ledger.expenses(in: month("2026-03")) == rub(30_000))
    #expect(ledger.expenses(in: month("2026-04")) == .zero)
    #expect(ledger.expenses(in: month("2026-05")) == .zero)
    let balances = book.balances(now: "2026-05-31")
    #expect(balances.balance(book.cardRub, at: MoneyBook.at("2026-03-31")) == rub(50_000))
    #expect(balances[book.cardRub]?.amountE4 == rub(30_000))
  }

  @Test func aPurchasePutOnAnOldLoanIsSpentByItsPayments() {
    var book = MoneyBook()
    let card = Debt(id: id(202), direction: .iOwe, type: .creditCard, name: "Credit card")
    book.debts = [card]
    book.count(90, "2026-03-01", [(book.cardRub, rub(50_000))])
    book.operation(1, .expense, "2026-03-05", rub(30_000), creditDebtId: card.id)
    book.operation(2, .expense, "2026-04-05", rub(10_000), debtId: card.id)
    let ledger = book.ledger
    #expect(ledger.expenses(in: month("2026-03")) == .zero)
    #expect(ledger.expenses(in: month("2026-04")) == rub(10_000))
    #expect(book.balances(now: "2026-04-30")[book.cardRub]?.amountE4 == rub(40_000))
  }
}

/// Money put into a goal is «хороший» spending of its month and stays on the accounts; a goal in
/// dollars counts a ruble contribution at the rate of its own day.
@Suite("Money for goals")
struct GoalMoneyTests {
  @Test func aContributionIsSpendingButNoMoneyLeaves() {
    var book = MoneyBook()
    book.count(90, "2026-03-01", [(book.cardRub, rub(50_000))])
    book.operation(1, .expense, "2026-03-05", rub(10_000), category: book.trip)
    let ledger = book.ledger
    #expect(ledger.expenses(in: month("2026-03")) == rub(10_000))
    #expect(ledger.row(ofPart: id(10))?.quality == .good)
    #expect(ledger.row(ofPart: id(10))?.isGoalContribution == true)
    #expect(book.balances(now: "2026-03-31")[book.cardRub]?.amountE4 == rub(50_000))
  }

  /// 9 000 ₽ on a day of 90 ₽ per dollar and 9 500 ₽ on a day of 95 are 200 dollars; 50 dollars
  /// put in in dollars count as they are; 1 900 ₽ taken back on a day of 95 take 20 dollars off.
  @Test func aDollarGoalCountsEachContributionAtItsOwnDaysRate() {
    var book = MoneyBook()
    let goal = Goal(
      id: id(600), name: "Bike", targetE4: rub(1000), monthlyPlanE4: rub(300),
      subcategoryId: book.trip, currency: .usd)
    book.goalsList = [goal]
    book.operation(1, .expense, "2026-03-05", rub(9000), category: book.trip)
    book.operation(2, .expense, "2026-03-20", rub(9500), category: book.trip)
    book.operation(
      3, .expense, "2026-03-22", rub(50), currency: .usd, rub: rub(4700), category: book.trip)
    book.operation(4, .refund, "2026-03-25", rub(1900), category: book.trip)
    let rates = DayRates(series: [
      .usd: [
        DayRate(day: day("2026-03-01"), perUnit: 90),
        DayRate(day: day("2026-03-15"), perUnit: 95),
      ]
    ])
    let ledger = book.ledger
    let counted = ledger.rows.compactMap { GoalMath.contribution(of: $0, to: goal, rates: rates) }
    #expect(AmountE4.sum(counted) == rub(230))
    let left = GoalMath.planLeft(
      goals: [goal], rows: ledger.rows, month: MonthKey(year: 2026, month: 3), rates: rates)
    #expect(left[goal.id] == rub(70))
    let april = GoalMath.planLeft(
      goals: [goal], rows: ledger.rows, month: MonthKey(year: 2026, month: 4), rates: rates)
    #expect(april[goal.id] == rub(300))
  }
}
