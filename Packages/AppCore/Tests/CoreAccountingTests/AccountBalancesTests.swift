import CoreKit
import Foundation
import Testing

@testable import CoreAccounting

/// The money on each account and currency: the latest count plus what moved after it.
@Suite("Balances of the accounts")
struct AccountBalancesTests {
  let categories = StartingCategories()
  let calendar = CalendarContext.utc
  let kzt = CurrencyCode("KZT")

  /// The main card holds rubles, the cash holds rubles and dollars, the tenge card tenge.
  var card: PaymentMethod {
    PaymentMethod(id: id(1), name: "Card", currency: .rub, isDefault: true)
  }
  var cash: PaymentMethod {
    PaymentMethod(id: id(2), name: "Cash", kind: .cash, currency: .rub, otherCurrencies: [.usd])
  }
  var tenge: PaymentMethod { PaymentMethod(id: id(3), name: "Tenge", currency: kzt) }

  func key(_ account: UUID, _ currency: CurrencyCode = .rub) -> BalanceKey {
    BalanceKey(accountId: account, currency: currency)
  }

  func at(_ iso: String, hour: Int = 12) -> Date {
    moment(iso).addingTimeInterval(TimeInterval(hour * 3600))
  }

  /// One operation of one part, as the app stores it; its part is `id(number * 10)`.
  ///
  /// `debtId` puts it on a debt; `forOthers` makes the part one paid for somebody else, in that
  /// status; `refunding` makes it take money back from that part of a purchase.
  func operation(
    _ number: Int, _ amount: Int, _ kind: TransactionKind = .expense, on iso: String,
    hour: Int = 12, currency: CurrencyCode = .rub, account: UUID? = id(1),
    leg: (CurrencyCode, Int)? = nil, externalId: String? = nil, creditDebtId: UUID? = nil,
    debtId: UUID? = nil, category: UUID? = nil, forOthers: ReimbursementStatus? = nil,
    refunding purchasePart: UUID? = nil, deleted: Bool = false
  ) -> TransactionEntry {
    let when = at(iso, hour: hour)
    let transaction = Transaction(
      id: id(number), kind: kind, occurredAt: when, currency: currency,
      amountE4: money(amount), paymentMethodId: account, accountCurrency: leg?.0,
      accountAmountE4: leg.map { money($0.1) }, debtId: debtId, creditDebtId: creditDebtId,
      externalId: externalId, deletedAt: deleted ? when : nil)
    return TransactionEntry(
      transaction: transaction,
      parts: [
        TransactionPart(
          id: id(number * 10), transactionId: id(number), categoryId: category,
          amountE4: money(amount), reimbursable: forOthers != nil,
          debtorPersonId: forOthers.map { _ in id(300) }, reimbursementStatus: forOthers,
          refundOfPartId: purchasePart)
      ])
  }

  /// A count of every key given, at `iso` `hour`.
  func count(
    _ number: Int, on iso: String, hour: Int = 10, kind: ReconciliationKind = .accounts,
    _ counts: [(BalanceKey, Int)]
  ) -> (Reconciliation, [ReconciledBalance]) {
    let when = at(iso, hour: hour)
    let reconciliation = Reconciliation(
      id: id(number), date: day(iso), reconciledAt: when, actualTotalRubE4: .zero, kind: kind)
    let balances = counts.enumerated().map { index, count in
      ReconciledBalance(
        id: id(number * 100 + index), reconciliationId: id(number),
        accountId: count.0.accountId, currency: count.0.currency, actualE4: money(count.1))
    }
    return (reconciliation, balances)
  }

  func build(
    _ entries: [TransactionEntry], transfers: [Transfer] = [], journal: [DebtEntry] = [],
    debts: [Debt] = [], counts: [(Reconciliation, [ReconciledBalance])] = [],
    accounts: [PaymentMethod]? = nil, now: String = "2026-03-31"
  ) -> AccountBalances {
    AccountBalances.build(
      entries: entries, transfers: transfers, debtEntries: journal,
      debts: Dictionary(uniqueKeysWithValues: debts.map { ($0.id, $0) }),
      reconciliations: counts.map(\.0), balances: counts.flatMap(\.1),
      accounts: accounts ?? [card, cash, tenge], tree: categories.tree, now: at(now, hour: 23),
      calendar: calendar)
  }

  // MARK: The count and what moved after it

  @Test func aBalanceIsTheLatestCountPlusWhatMovedAfterIt() {
    let balances = build(
      [
        operation(1, 300, on: "2026-03-01"),
        operation(2, 700, on: "2026-03-05", hour: 9),
        operation(3, 5000, .income, on: "2026-03-05", hour: 11),
        operation(4, 200, on: "2026-03-06"),
      ],
      counts: [count(90, on: "2026-03-05", [(key(id(1)), 10_000)])])
    let card = balances[key(id(1))]
    #expect(card?.anchor?.actualE4 == money(10_000))
    #expect(card?.movements.map(\.source) == [.operation(id(3)), .operation(id(4))])
    #expect(card?.movedSinceAnchor == money(4800))
    #expect(card?.amountE4 == money(14_800))
  }

  @Test func aKeyNeverCountedHasNoBalanceButKeepsItsMovements() {
    let balances = build([operation(1, 300, on: "2026-03-01")])
    let card = balances[key(id(1))]
    #expect(card?.amountE4 == nil)
    #expect(card?.movedSinceAnchor == money(-300))
    #expect(balances.hasHistory(key(id(1))))
    #expect(!balances.hasHistory(key(id(2), .usd)))
  }

  @Test func aMovementAfterNowWaitsForItsMoment() {
    let balances = build(
      [operation(1, 300, on: "2026-04-02")],
      counts: [count(90, on: "2026-03-01", [(key(id(1)), 1000)])])
    #expect(balances[key(id(1))]?.amountE4 == money(1000))
    #expect(balances.balance(key(id(1)), at: at("2026-04-03")) == money(700))
  }

  @Test func aTotalOfTheTimeBeforeAccountsAnchorsNothing() {
    let total = Reconciliation(
      id: id(90), date: day("2026-03-01"), reconciledAt: at("2026-03-01"),
      actualTotalRubE4: money(50_000), kind: .total)
    let balances = build([operation(1, 300, on: "2026-03-02")], counts: [(total, [])])
    #expect(balances[key(id(1))]?.anchor == nil)
    #expect(balances.latestAnchor(key(id(1))) == nil)
  }

  @Test func theLatestCountIsTheLastInTheOrderOfTheBook() {
    let balances = build(
      [operation(1, 100, on: "2026-03-10")],
      counts: [
        count(90, on: "2026-03-01", kind: .opening, [(key(id(1)), 1000)]),
        count(91, on: "2026-03-08", [(key(id(1)), 2000)]),
      ])
    #expect(balances.latestAnchor(key(id(1)))?.balance.id == id(9100))
    #expect(balances[key(id(1))]?.amountE4 == money(1900))
    // As of a moment between the two counts, the earlier one is the anchor.
    #expect(balances.balance(key(id(1)), at: at("2026-03-05")) == money(1000))
    #expect(balances.balance(key(id(1)), at: at("2026-02-01")) == nil)
  }

  // MARK: What moves money

  @Test func aDeletedOperationMovesNothing() {
    let balances = build([operation(1, 300, on: "2026-03-02", deleted: true)])
    #expect(balances[key(id(1))]?.movements.isEmpty == true)
  }

  @Test(arguments: [
    "reimb:\(id(5).uuidString.lowercased()):surplus",
    "reimb:\(id(5).uuidString.lowercased()):shortfall:\(id(6).uuidString.lowercased())",
    "reconcile:\(id(7).uuidString.lowercased())",
    "reconcile:\(id(7).uuidString.lowercased()):\(id(8).uuidString.lowercased())",
    "writeoff:\(id(6).uuidString.lowercased()):\(id(9).uuidString.lowercased())",
  ])
  func aLineOfTheBooksMovesNothing(_ externalId: String) {
    let balances = build([operation(1, 300, on: "2026-03-02", externalId: externalId)])
    #expect(balances[key(id(1))]?.movements.isEmpty == true)
  }

  @Test func aFeeAndAPaidDueAreRealMoney() {
    let fee = operation(
      1, 50, on: "2026-03-02", externalId: "transfer:\(id(5).uuidString.lowercased()):fee")
    let due = operation(
      2, 300, on: "2026-03-02",
      externalId: "sched:\(id(6).uuidString.lowercased()):2026-03-02")
    #expect(build([fee, due])[key(id(1))]?.movedSinceAnchor == money(-350))
  }

  @Test func aPurchaseOnCreditMovesNothingButIncomeMarkedSoStillDoes() {
    let credit = operation(1, 30_000, on: "2026-03-02", creditDebtId: id(200))
    // Income could be put on credit before income lost that field: it is income all the same.
    let income = operation(2, 1000, .income, on: "2026-03-02", creditDebtId: id(200))
    let balances = build([credit, income])
    #expect(balances[key(id(1))]?.movements.map(\.source) == [.operation(id(2))])
    #expect(balances[key(id(1))]?.movedSinceAnchor == money(1000))
  }

  @Test func moneyPutIntoAGoalStaysOnTheAccount() {
    let contribution = operation(1, 1000, on: "2026-03-02", category: categories.goalsTrip)
    let takenOut = operation(2, 400, .refund, on: "2026-03-03", category: categories.goalsTrip)
    #expect(build([contribution, takenOut])[key(id(1))]?.movements.isEmpty == true)
  }

  @Test func aPurchasePartOfWhichGoesToAGoalMovesOnlyTheRest() {
    let transaction = Transaction(
      id: id(1), kind: .expense, occurredAt: at("2026-03-02"), currency: .usd,
      amountE4: money(100), paymentMethodId: id(1), accountCurrency: .rub,
      accountAmountE4: money(9000))
    let mixed = TransactionEntry(
      transaction: transaction,
      parts: [
        TransactionPart(
          transactionId: id(1), categoryId: categories.groceries, amountE4: money(70)),
        TransactionPart(
          transactionId: id(1), categoryId: categories.goalsTrip, amountE4: money(30)),
      ])
    // 70 of the 100 dollars are the purchase: 70 % of the 9 000 rubles charged.
    #expect(build([mixed])[key(id(1))]?.movedSinceAnchor == money(-6300))
  }

  @Test func eachKindMovesItsWay() {
    let balances = build([
      operation(1, 300, on: "2026-03-02"),
      operation(2, 1000, .income, on: "2026-03-02"),
      operation(3, 50, .refund, on: "2026-03-02"),
      operation(4, 20, .reimbursement, on: "2026-03-02"),
    ])
    #expect(balances[key(id(1))]?.movements.map(\.amountE4) == [-300, 1000, 50, 20].map(money))
  }

  /// A payment on a debt is money out of the pocket whether the debt counts its payments as
  /// spending or not: that switch decides what the reports call it, not where the money went.
  @Test func aDebtPaymentMovesMoneyWhetherOrNotItIsSpending() {
    let bought = Debt(
      id: id(200), direction: .iOwe, type: .installment, name: "Laptop",
      paymentsAreExpenses: false, origin: .purchase)
    let bank = Debt(id: id(201), direction: .iOwe, type: .loan, name: "Bank")
    #expect(!DebtRules.paymentIsExpense(on: bought))
    #expect(DebtRules.paymentIsExpense(on: bank))
    let balances = build(
      [
        operation(1, 3000, on: "2026-03-02", debtId: bought.id),
        operation(2, 5000, on: "2026-03-03", debtId: bank.id),
      ],
      debts: [bought, bank])
    #expect(balances[key(id(1))]?.movements.map(\.amountE4) == [-3000, -5000].map(money))
  }

  /// Money lent out on a debt owed to me leaves the account; money the person pays back on it
  /// comes in.
  @Test func moneyLentGoesOutAndMoneyPaidBackOnTheDebtComesIn() {
    let friend = Debt(id: id(202), direction: .owedToMe, type: .personal, name: "To a friend")
    let balances = build(
      [
        operation(1, 2000, on: "2026-03-02", account: id(2), debtId: friend.id),
        operation(2, 700, .reimbursement, on: "2026-03-09", account: id(2), debtId: friend.id),
      ],
      debts: [friend])
    #expect(balances[key(id(2))]?.movements.map(\.amountE4) == [-2000, 700].map(money))
    #expect(balances[key(id(2))]?.movedSinceAnchor == money(-1300))
  }

  /// A part paid for somebody else is not my spending, but the money left my account all the
  /// same, in full, whatever became of it later.
  @Test(arguments: ReimbursementStatus.allCases)
  func aPartPaidForSomebodyElseMovesInFull(_ status: ReimbursementStatus) {
    let dinner = operation(1, 1500, on: "2026-03-02", forOthers: status)
    #expect(build([dinner])[key(id(1))]?.movedSinceAnchor == money(-1500))
  }

  /// A refund of a purchase moves its own account at its own moment by what it put there — at
  /// the rate of its own day —, never on the day of the purchase or by the purchase's figure.
  @Test func aRefundMovesTheAccountAtItsOwnMomentByItsOwnCharge() {
    let purchase = operation(
      1, 50, on: "2026-03-10", currency: .usd, account: id(1), leg: (.rub, 4500))
    let refund = operation(
      2, 50, .refund, on: "2026-04-05", currency: .usd, account: id(1), leg: (.rub, 4750),
      refunding: id(10))
    let balances = build(
      [purchase, refund], counts: [count(90, on: "2026-03-01", [(key(id(1)), 10_000)])],
      now: "2026-04-30")
    let card = key(id(1))
    #expect(balances[card]?.movements.map(\.source) == [.operation(id(1)), .operation(id(2))])
    #expect(balances[card]?.movements.map(\.at) == [at("2026-03-10"), at("2026-04-05")])
    #expect(balances[card]?.movements.map(\.amountE4) == [-4500, 4750].map(money))
    #expect(balances[key(id(1), .usd)] == nil)
    // The purchase's day ends without the refund, and so does the refund's day until its moment.
    #expect(balances.balance(card, at: at("2026-03-10", hour: 23)) == money(5500))
    #expect(balances.balance(card, at: at("2026-03-20")) == money(5500))
    #expect(balances.balance(card, at: at("2026-04-05", hour: 11)) == money(5500))
    #expect(balances.balance(card, at: at("2026-04-05")) == money(10_250))
    #expect(balances[card]?.amountE4 == money(10_250))
  }

  @Test func whatMovedOnTheAccountIsItsChargeWhenThereIsOne() {
    let dinner = operation(
      1, 50, on: "2026-03-02", currency: .usd, account: id(1), leg: (.rub, 4700))
    let balances = build([dinner])
    #expect(balances[key(id(1))]?.movedSinceAnchor == money(-4700))
    #expect(balances[key(id(1), .usd)] == nil)
  }

  /// No charge stored — a row of the time before accounts: it moves its own currency, on a key
  /// the account does not hold, and nothing is guessed.
  @Test func anOperationWithNoChargeMovesItsOwnCurrency() {
    let balances = build([operation(1, 50, on: "2026-03-02", currency: .usd)])
    #expect(balances[key(id(1), .usd)]?.movedSinceAnchor == money(-50))
    #expect(balances.keys.contains(key(id(1), .usd)))
  }

  @Test func anOperationWithNoAccountMovesTheMainOne() {
    let balances = build([operation(1, 300, on: "2026-03-02", account: nil)])
    #expect(balances[key(id(1))]?.movedSinceAnchor == money(-300))
    #expect(balances.unassignedOperations == 0)
  }

  @Test func withNoMainAccountAnOperationWithNoAccountIsCountedApart() {
    var loose = card
    loose.isDefault = false
    let balances = build(
      [operation(1, 300, on: "2026-03-02", account: nil)], accounts: [loose, cash])
    #expect(balances.unassignedOperations == 1)
    #expect(balances[key(id(1))]?.movements.isEmpty == true)
  }

  @Test func theKeysAreEveryLiveAccountInEachCurrencyAndEverythingThatMoved() {
    var archived = tenge
    archived.archived = true
    let balances = build(
      [operation(1, 5000, on: "2026-03-02", currency: kzt, account: id(3), leg: nil)],
      accounts: [card, cash, archived])
    #expect(balances.keys.contains(key(id(1))))
    #expect(balances.keys.contains(key(id(2))))
    #expect(balances.keys.contains(key(id(2), .usd)))
    #expect(balances.keys.contains(key(id(3), kzt)))
    #expect(balances.keys == balances.keys.sorted())
  }

  // MARK: Transfers

  @Test func aTransferMovesOneKeyDownAndAnotherUp() {
    let exchange = Transfer(
      id: id(70), occurredAt: at("2026-03-02"), fromAccountId: id(1), fromCurrency: .rub,
      fromAmountE4: money(10_000), toAccountId: id(3), toCurrency: kzt,
      toAmountE4: money(55_000))
    let balances = build([], transfers: [exchange])
    #expect(balances[key(id(1))]?.movedSinceAnchor == money(-10_000))
    #expect(balances[key(id(3), kzt)]?.movedSinceAnchor == money(55_000))
    #expect(balances[key(id(3), kzt)]?.movements.first?.source == .transferIn(id(70)))
  }

  // MARK: Debt journals

  func line(
    _ number: Int, debt: UUID, amount: Int, date: String? = nil, moment: Date? = nil,
    account: UUID? = nil, leg: (CurrencyCode, Int)? = nil, kind: DebtEntryKind = .borrowed,
    transaction: UUID? = nil
  ) -> DebtEntry {
    DebtEntry(
      id: id(number), debtId: debt, date: date.map(day), amountE4: money(amount), kind: kind,
      transactionId: transaction, paymentMethodId: account, occurredAt: moment,
      accountCurrency: leg?.0, accountAmountE4: leg.map { money($0.1) })
  }

  @Test func moneyBorrowedComesInAndMoneyLentGoesOut() {
    let owe = Debt(id: id(200), direction: .iOwe, type: .personal, name: "From a friend")
    let lent = Debt(id: id(201), direction: .owedToMe, type: .personal, name: "To a friend")
    let balances = build(
      [],
      journal: [
        line(1, debt: owe.id, amount: 5000, moment: at("2026-03-02")),
        line(2, debt: lent.id, amount: 2000, moment: at("2026-03-03"), account: id(2)),
      ],
      debts: [owe, lent])
    #expect(balances[key(id(1))]?.movedSinceAnchor == money(5000))
    #expect(balances[key(id(2))]?.movedSinceAnchor == money(-2000))
    #expect(balances[key(id(1))]?.movements.first?.source == .journal(id(1)))
  }

  @Test func aLineInACurrencyTheAccountDoesNotHoldMovesItsCharge() {
    let owe = Debt(
      id: id(200), direction: .iOwe, type: .personal, name: "From a friend", currency: .usd)
    let balances = build(
      [],
      journal: [line(1, debt: owe.id, amount: 100, moment: at("2026-03-02"), leg: (.rub, 9500))],
      debts: [owe])
    #expect(balances[key(id(1))]?.movedSinceAnchor == money(9500))
  }

  @Test func onlyMoneyBorrowedThroughTheJournalAloneMoves() {
    let owe = Debt(id: id(200), direction: .iOwe, type: .personal, name: "From a friend")
    let bought = Debt(
      id: id(201), direction: .iOwe, type: .installment, name: "Laptop", origin: .purchase)
    let balances = build(
      [],
      journal: [
        line(1, debt: owe.id, amount: 5000, moment: at("2026-03-02"), transaction: id(9)),
        line(2, debt: owe.id, amount: 5000, moment: at("2026-03-02"), kind: .adjustment),
        line(3, debt: bought.id, amount: 30_000, moment: at("2026-03-02")),
      ],
      debts: [owe, bought])
    #expect(balances[key(id(1))]?.movements.isEmpty == true)
  }

  /// A purchase put on a debt I already had writes an opening line of the same debt, day and
  /// amount: that line is the purchase, not money borrowed — one line per purchase.
  @Test func theOpeningLineOfAPurchaseOnCreditIsNoMoney() {
    let card = Debt(id: id(200), direction: .iOwe, type: .creditCard, name: "Credit card")
    let purchase = operation(1, 3000, on: "2026-03-02", creditDebtId: card.id)
    let balances = build(
      [purchase],
      journal: [
        line(1, debt: card.id, amount: 3000, date: "2026-03-02"),
        line(2, debt: card.id, amount: 3000, date: "2026-03-02"),
      ],
      debts: [card])
    #expect(balances[key(id(1))]?.movements.map(\.source) == [.journal(id(2))])
  }

  @Test func aLineOfTheDayOfTheCountIsLeftOutAndCounted() {
    let owe = Debt(id: id(200), direction: .iOwe, type: .personal, name: "From a friend")
    let balances = build(
      [],
      journal: [
        line(1, debt: owe.id, amount: 100, date: "2026-03-05"),
        line(2, debt: owe.id, amount: 200, date: "2026-03-06"),
        line(3, debt: owe.id, amount: 400, date: "2026-03-04"),
        line(4, debt: owe.id, amount: 800),
      ],
      debts: [owe], counts: [count(90, on: "2026-03-05", [(key(id(1)), 1000)])])
    let card = balances[key(id(1))]
    #expect(card?.amountE4 == money(1200))
    #expect(card?.journalLinesOnAnchorDay == 1)
    #expect(card?.undatedJournalLines == 1)
  }

  @Test func theExtractedRuleLeavesOtherLinesAlone() {
    let owe = Debt(id: id(200), direction: .iOwe, type: .personal, name: "From a friend")
    var openings: [CreditOpening: Int] = [:]
    let payment = line(1, debt: owe.id, amount: -300, date: "2026-03-02", kind: .payment)
    #expect(
      AccountBalances.journalMovement(
        of: payment, debt: owe, mainId: id(1), openings: &openings, calendar: calendar) == nil)
    let noMain = line(2, debt: owe.id, amount: 300, date: "2026-03-02")
    #expect(
      AccountBalances.journalMovement(
        of: noMain, debt: owe, mainId: nil, openings: &openings, calendar: calendar) == nil)
  }

  // MARK: Every count of a key, and what moved between two moments

  /// Every count of a key, in the order of the book — an opening, a count, a later count listed
  /// before an earlier one —, with its moment; a total of the time before accounts is none, a
  /// key never counted has none.
  @Test func anchorsAreInBookOrder() {
    let late = count(92, on: "2026-03-20", [(key(id(1)), 3000), (key(id(2)), 50)])
    let balances = build(
      [operation(1, 100, on: "2026-03-10")],
      counts: [
        count(90, on: "2026-03-01", kind: .opening, [(key(id(1)), 1000)]),
        count(93, on: "2026-03-05", kind: .total, [(key(id(1)), 9999)]),
        late,
        count(91, on: "2026-03-08", [(key(id(1)), 2000)]),
      ])
    let anchors = balances.anchors(key(id(1)))
    #expect(anchors.map(\.balance.id) == [id(9000), id(9200), id(9100)])
    #expect(
      anchors.map(\.at) == [
        at("2026-03-01", hour: 10), at("2026-03-20", hour: 10), at("2026-03-08", hour: 10),
      ])
    #expect(anchors.last?.balance.id == balances.latestAnchor(key(id(1)))?.balance.id)
    #expect(balances.anchors(key(id(2))).map(\.balance.id) == [id(9201)])
    #expect(balances.anchors(key(id(3), kzt)).isEmpty)
    #expect(balances.anchors(key(id(9))).isEmpty)
  }

  /// What moved on a key after one moment and up to another: a movement at the first moment is
  /// not in it, one at the second is; the other keys, a line with no date and a line dated only
  /// by the day of the first moment are not either — that day says nothing of before or after.
  @Test func movedIsWhatMovedBetweenTwoMoments() {
    let owe = Debt(id: id(200), direction: .iOwe, type: .personal, name: "From a friend")
    let start = at("2026-03-05", hour: 10)
    let end = at("2026-03-09", hour: 18)
    let balances = build(
      [
        operation(1, 100, on: "2026-03-05", hour: 10),
        operation(2, 200, on: "2026-03-06"),
        operation(3, 400, .income, on: "2026-03-09", hour: 18),
        operation(4, 800, on: "2026-03-09", hour: 19),
        operation(5, 1600, on: "2026-03-07", account: id(2)),
      ],
      transfers: [
        Transfer(
          id: id(70), occurredAt: at("2026-03-08"), fromAccountId: id(1), fromCurrency: .rub,
          fromAmountE4: money(50), toAccountId: id(2), toCurrency: .rub, toAmountE4: money(50))
      ],
      journal: [
        line(10, debt: owe.id, amount: 3000, date: "2026-03-05"),
        line(11, debt: owe.id, amount: 6000, date: "2026-03-07"),
        line(12, debt: owe.id, amount: 12000),
      ],
      debts: [owe])
    #expect(
      balances.moved(key(id(1)), after: start, through: end) == money(-200 + 400 - 50 + 6000))
    #expect(balances.moved(key(id(2)), after: start, through: end) == money(-1600 + 50))
    #expect(balances.moved(key(id(1)), after: end, through: start) == .zero)
    #expect(balances.moved(key(id(1)), after: start, through: start) == .zero)
    #expect(balances.moved(key(id(9)), after: start, through: end) == .zero)
    // From a moment of the day before, the line of the 5th is in.
    #expect(
      balances.moved(key(id(1)), after: at("2026-03-04"), through: end)
        == money(-100 - 200 + 400 - 50 + 3000 + 6000))
  }

  /// For every moment and the count `balance(_:at:)` takes then, the balance is that count plus
  /// what moved after it up to the moment: `moved` is the same rule, on random histories with
  /// counts listed out of order, lines dated by their day only and lines with no date.
  @Test(arguments: Array(UInt64(1)...40))
  func movedMatchesTheBalanceEngine(seed: UInt64) {
    var dice = MoneyDice(seed: seed)
    let owe = Debt(id: id(200), direction: .iOwe, type: .personal, name: "From a friend")
    let lent = Debt(id: id(201), direction: .owedToMe, type: .personal, name: "To a friend")
    let start = moment("2026-03-01")
    func someMoment() -> Date {
      start.addingTimeInterval(TimeInterval(dice.below(40 * 1440) * 60))
    }
    let accounts = [id(1), id(2)]
    var entries: [TransactionEntry] = []
    var transfers: [Transfer] = []
    var journal: [DebtEntry] = []
    var counts: [(Reconciliation, [ReconciledBalance])] = []
    for number in 1...60 {
      let when = someMoment()
      let account = dice.pick(accounts)
      let kind = dice.pick([TransactionKind.expense, .expense, .income, .refund])
      let amount = dice.amount(upTo: 5_000)
      entries.append(
        TransactionEntry(
          transaction: Transaction(
            id: id(number), kind: kind, occurredAt: when, currency: .rub, amountE4: amount,
            paymentMethodId: account, deletedAt: dice.chance(10) ? when : nil),
          parts: [
            TransactionPart(
              id: id(number * 10), transactionId: id(number), amountE4: amount)
          ]))
    }
    for number in 1...10 {
      let sent = dice.amount(upTo: 2_000)
      transfers.append(
        Transfer(
          id: id(1000 + number), occurredAt: someMoment(), fromAccountId: id(1),
          fromCurrency: .rub, fromAmountE4: sent, toAccountId: id(2), toCurrency: .rub,
          toAmountE4: sent))
    }
    for number in 1...12 {
      let when = someMoment()
      let dated = dice.below(3)
      journal.append(
        DebtEntry(
          id: id(2000 + number), debtId: dice.chance(50) ? owe.id : lent.id,
          date: dated == 0 ? CalendarContext.utc.day(of: when) : nil,
          amountE4: dice.amount(upTo: 3_000), kind: .borrowed,
          paymentMethodId: dice.pick(accounts), occurredAt: dated == 1 ? when : nil))
    }
    for number in 1...6 {
      let when = someMoment()
      let reconciliation = Reconciliation(
        id: id(3000 + number), date: CalendarContext.utc.day(of: when), reconciledAt: when,
        actualTotalRubE4: .zero,
        kind: dice.pick([ReconciliationKind.accounts, .accounts, .opening, .total]))
      let rows = accounts.enumerated().compactMap { index, account -> ReconciledBalance? in
        guard dice.chance(70) else { return nil }
        return ReconciledBalance(
          id: id(4000 + number * 10 + index), reconciliationId: reconciliation.id,
          accountId: account, currency: .rub, actualE4: dice.amount(upTo: 100_000))
      }
      counts.append((reconciliation, rows))
    }
    counts = dice.shuffled(counts)
    let balances = build(
      entries, transfers: transfers, journal: journal, debts: [owe, lent], counts: counts,
      accounts: [card, cash], now: "2026-04-30")
    var instants = entries.prefix(12).map(\.transaction.occurredAt)
    instants += counts.compactMap(\.0.reconciledAt)
    instants += journal.compactMap(\.occurredAt)
    for _ in 0..<12 { instants.append(someMoment()) }
    for account in accounts {
      let pair = key(account)
      let anchors = balances.anchors(pair)
      let written = counts.filter { $0.0.kind != .total }.flatMap(\.1).filter { $0.key == pair }
      #expect(anchors.map(\.balance.id) == written.map(\.id), "seed \(seed)")
      for instant in instants {
        guard let anchor = anchors.last(where: { $0.at <= instant }) else {
          #expect(balances.balance(pair, at: instant) == nil, "seed \(seed)")
          continue
        }
        #expect(
          balances.balance(pair, at: instant)
            == anchor.balance.actualE4 + balances.moved(pair, after: anchor.at, through: instant),
          "seed \(seed), \(instant)")
      }
    }
  }

  // MARK: The window of a count

  @Test func expectedForACountIsThePreviousCountPlusItsWindow() {
    let balances = build(
      [
        operation(1, 300, on: "2026-03-02"),
        operation(2, 5000, .income, on: "2026-03-04"),
        operation(3, 700, on: "2026-03-06"),
        operation(4, 200, on: "2026-03-09"),
      ],
      counts: [
        count(90, on: "2026-03-03", [(key(id(1)), 10_000)]),
        count(91, on: "2026-03-08", [(key(id(1)), 14_000)]),
      ])
    #expect(balances.expected(forCount: id(9000)) == nil)
    // 10,000 counted on 03.03 plus +5,000 and −700 in the window up to 08.03.
    #expect(balances.expected(forCount: id(9100)) == money(14_300))
    #expect(balances.expected(forCount: id(4242)) == nil)
  }

  @Test func countHoldingFindsTheWindowWithTheDayRule() {
    let owe = Debt(id: id(200), direction: .iOwe, type: .personal, name: "From a friend")
    let first = count(90, on: "2026-03-03", [(key(id(1)), 10_000)])
    let second = count(91, on: "2026-03-08", [(key(id(1)), 14_000)])
    let sameDay = line(1, debt: owe.id, amount: 500, date: "2026-03-03")
    let inside = line(2, debt: owe.id, amount: 500, date: "2026-03-05")
    let onTheCountDay = line(3, debt: owe.id, amount: 500, date: "2026-03-08")
    let undated = line(4, debt: owe.id, amount: 500)
    let balances = build(
      [operation(1, 300, on: "2026-03-05"), operation(2, 300, on: "2026-03-09")],
      journal: [sameDay, inside, onTheCountDay, undated], debts: [owe],
      counts: [first, second])
    let moves = [
      AccountMovement(
        key: key(id(1)), at: at("2026-03-05"), amountE4: money(-300),
        source: .operation(id(1))),
      AccountMovement(
        key: key(id(1)), at: moment("2026-03-03"), amountE4: money(500),
        source: .journal(id(1)), timing: .day(day("2026-03-03"))),
      AccountMovement(
        key: key(id(1)), at: moment("2026-03-05"), amountE4: money(500),
        source: .journal(id(2)), timing: .day(day("2026-03-05"))),
      AccountMovement(
        key: key(id(1)), at: moment("2026-03-08"), amountE4: money(500),
        source: .journal(id(3)), timing: .day(day("2026-03-08"))),
      AccountMovement(
        key: key(id(1)), at: .distantPast, amountE4: money(500), source: .journal(id(4)),
        timing: .undated),
      AccountMovement(
        key: key(id(1)), at: at("2026-03-09"), amountE4: money(-300),
        source: .operation(id(2))),
      AccountMovement(
        key: key(id(1)), at: at("2026-03-01"), amountE4: money(-300),
        source: .operation(id(3))),
    ]
    let holding = moves.map { balances.countHolding($0)?.id }
    #expect(holding == [id(9100), nil, id(9100), id(9100), nil, nil, nil])
    // The expected balance agrees: the window holds −300, +500 and +500.
    #expect(balances.expected(forCount: id(9100)) == money(10_700))
  }
}
