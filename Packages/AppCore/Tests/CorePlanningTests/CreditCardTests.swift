import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CorePlanning

/// A credit card as Т-Банк keeps it: statements on the 5th, 25 days to pay, interest back to
/// the day of each purchase once a statement is missed, cash from the day after.
@Suite("Credit cards: statements, minimum payments and interest")
struct CreditCardTests {
  private static func uuid(_ number: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number))!
  }
  private static func rub(_ text: String) -> AmountE4 {
    (try? AmountE4(decimal: Decimal(string: text)!)) ?? .zero
  }
  private static func day(_ iso: String) -> DateOnly { DateOnly(iso: iso)! }
  private static let calendar = CalendarContext.utc
  private static func noon(_ iso: String) -> Date { calendar.noon(of: day(iso)) }

  static let cardId = uuid(1)
  static let mainId = uuid(2)
  static let cashId = uuid(3)

  static let terms = CreditCardTerms(
    limitE4: rub("150000"), grace: .statement(day: 5, payDays: 25),
    purchaseRate: Decimal(string: "29.9"), cashRate: Decimal(string: "49.9"),
    minPercent: 8, minFloorE4: rub("600"), cashFeePercent: Decimal(string: "2.9"),
    cashFeeFixedE4: rub("290"), cashWithoutGrace: true)

  static func card(_ terms: CreditCardTerms? = CreditCardTests.terms) -> PaymentMethod {
    PaymentMethod(id: cardId, name: "Т-Банк", currency: .rub, credit: terms)
  }

  static let accounts = [
    card(), PaymentMethod(id: mainId, name: "Основной", currency: .rub, isDefault: true),
    PaymentMethod(id: cashId, name: "Наличные", kind: .cash, currency: .rub),
  ]

  static func purchase(_ number: Int, _ amount: String, on iso: String) -> TransactionEntry {
    TransactionEntry(
      transaction: Transaction(
        id: uuid(number), kind: .expense, occurredAt: noon(iso), currency: .rub,
        amountE4: rub(amount), paymentMethodId: cardId),
      parts: [
        TransactionPart(id: uuid(number + 1000), transactionId: uuid(number), amountE4: rub(amount))
      ])
  }

  static func transfer(
    _ number: Int, _ amount: String, on iso: String, from: UUID, to: UUID
  ) -> Transfer {
    Transfer(
      id: uuid(number), occurredAt: noon(iso), fromAccountId: from, fromCurrency: .rub,
      fromAmountE4: rub(amount), toAccountId: to, toCurrency: .rub, toAmountE4: rub(amount))
  }

  /// The books of the card counted at zero on 1 October, with `entries` and `transfers`.
  struct Books {
    var ledger: Ledger
    var balances: AccountBalances
    var movements: [CreditMovement]
    var statements: [CreditStatement]
    var today: DateOnly
    var account: PaymentMethod

    var now: CreditCardNow {
      CreditStatements.now(
        account: account, terms: account.credit!, statements: statements, movements: movements,
        balances: balances, today: today, calendar: CreditCardTests.calendar)
    }

    func estimates(recorded: [String: AmountE4] = [:]) -> [CreditInterestEstimate] {
      CreditInterest.estimates(
        terms: account.credit!, statements: statements,
        movements: CreditStatements.withOpening(
          movements, account: account, balances: balances, calendar: CreditCardTests.calendar),
        recorded: recorded, through: today)
    }
  }

  static func books(
    _ entries: [TransactionEntry], transfers: [Transfer] = [], today iso: String,
    terms: CreditCardTerms = CreditCardTests.terms, opening: String = "0"
  ) -> Books {
    let account = card(terms)
    let all = [account] + accounts.dropFirst()
    let count = Reconciliation(
      id: uuid(900), date: day("2026-10-01"), reconciledAt: noon("2026-10-01"),
      actualTotalRubE4: .zero, kind: .accounts)
    let counted = ReconciledBalance(
      id: uuid(901), reconciliationId: uuid(900), accountId: cardId, currency: .rub,
      actualE4: rub(opening))
    let book = PlanningBook(reconciliations: [count], reconciledBalances: [counted])
    let dataset = Dataset(
      entries: entries, paymentMethods: all, planning: book, transfers: transfers)
    let ledger = Ledger(dataset: dataset, calendar: calendar)
    let today = day(iso)
    let balances = AccountBalances.build(
      entries: entries, transfers: transfers, debtEntries: [], debts: [:],
      reconciliations: [count], balances: [counted], accounts: all, tree: CategoryTree(),
      now: calendar.endOfDay(today), calendar: calendar)
    let movements = CreditStatements.movements(
      account: account, ledger: ledger, transfers: transfers)
    let statements = CreditStatements.statements(
      account: account, terms: terms, movements: movements, balances: balances, through: today,
      calendar: calendar)
    return Books(
      ledger: ledger, balances: balances, movements: movements, statements: statements,
      today: today, account: account)
  }

  static let twoPurchases = [
    purchase(10, "10000", on: "2026-10-10"), purchase(20, "20000", on: "2026-10-20"),
  ]

  // MARK: Statements

  /// 10,000 on 10 October and 20,000 on the 20th: the statement of 5 November owes 30,000, is
  /// due on the 30th, its minimum 8 % (not below 600) is 2,400; paid in full — no interest.
  @Test func aStatementPaidInFullCostsNothing() {
    let books = Self.books(
      Self.twoPurchases,
      transfers: [Self.transfer(30, "30000", on: "2026-11-30", from: Self.mainId, to: Self.cardId)],
      today: "2026-12-10")
    let first = books.statements[1]
    #expect(first.closesOn == Self.day("2026-11-05"))
    #expect(first.periodAfter == Self.day("2026-10-05"))
    #expect(first.due == Self.day("2026-11-30"))
    #expect(first.debtE4 == Self.rub("30000"))
    #expect(first.purchasesE4 == Self.rub("30000"))
    #expect(first.minimumE4 == Self.rub("2400"))
    #expect(first.state == .paidInFull)
    #expect(books.estimates().isEmpty)
    #expect(books.now.graceKept)
  }

  /// Only 900 paid on 25 November at 29.9 %: the statement of 5 December charges
  /// 0.299 / 365 × (10,000 × 56 + 20,000 × 46 − 900 × 10) = 1,205.01.
  @Test func aMissedStatementChargesInterestBackToEachPurchase() {
    let books = Self.books(
      Self.twoPurchases,
      transfers: [Self.transfer(30, "900", on: "2026-11-25", from: Self.mainId, to: Self.cardId)],
      today: "2026-12-10")
    #expect(books.statements[1].state == .missed)
    let estimate = books.estimates().first { $0.statementDay == Self.day("2026-12-05") }
    #expect(estimate?.purchaseInterestE4 == Self.rub("1205.01"))
    #expect(estimate?.shownE4 == Self.rub("1205.01"))
    #expect(!books.now.graceKept)
    #expect(books.now.toPayNoInterestE4 == Self.rub("29100"))
  }

  /// While the statement waits for its due day: pay 30,000 by 30 November, minimum 2,400; the
  /// card has 150,000 − 30,000 left.
  @Test func aWaitingStatementSaysWhatToPayByWhen() {
    let books = Self.books(Self.twoPurchases, today: "2026-11-10")
    let now = books.now
    #expect(books.statements.last?.state == .waiting)
    #expect(now.toPayNoInterestE4 == Self.rub("30000"))
    #expect(now.minimumE4 == Self.rub("2400"))
    #expect(now.payBy == Self.day("2026-11-30"))
    #expect(now.availableE4 == Self.rub("120000"))
    #expect(now.debtE4 == Self.rub("30000"))
    #expect(now.nextStatement == Self.day("2026-12-05"))
    #expect(now.graceKept)
    #expect(now.estimate == nil)
  }

  /// Cash of 5,000 on 15 October without grace at 49.9 %: the fee is 2.9 % + 290 = 435.00 and
  /// interest runs from the 16th, though the statement is paid in full.
  @Test func cashEarnsFromTheDayAfterWhateverTheStatement() {
    let books = Self.books(
      Self.twoPurchases,
      transfers: [
        Self.transfer(40, "5000", on: "2026-10-15", from: Self.cardId, to: Self.cashId),
        Self.transfer(41, "35000", on: "2026-11-30", from: Self.mainId, to: Self.cardId),
      ], today: "2026-12-10")
    #expect(books.statements[1].state == .paidInFull)
    #expect(books.statements[1].cashLikeE4 == Self.rub("5000"))
    #expect(CreditInterest.cashFee(amount: Self.rub("5000"), terms: Self.terms) == Self.rub("435"))
    let november = books.estimates().first { $0.statementDay == Self.day("2026-11-05") }
    #expect(november?.cashFeesE4 == Self.rub("435"))
    #expect(november?.purchaseInterestE4 == .zero)
    // 5,000 × 0.499 × 21 / 365 = 143.547…
    #expect(november?.cashInterestE4 == Self.rub("143.55"))
  }

  /// The interest recorded from the statement replaces the estimate of that statement, any sum.
  @Test func theRecordedInterestReplacesTheEstimate() {
    let books = Self.books(
      Self.twoPurchases,
      transfers: [Self.transfer(30, "900", on: "2026-11-25", from: Self.mainId, to: Self.cardId)],
      today: "2026-12-10")
    let key = CreditInterest.recordKey(account: Self.cardId, statementDay: Self.day("2026-12-05"))
    let estimate = books.estimates(recorded: [key: Self.rub("1190")]).first {
      $0.statementDay == Self.day("2026-12-05")
    }
    #expect(estimate?.recordedE4 == Self.rub("1190"))
    #expect(estimate?.shownE4 == Self.rub("1190"))
    #expect(CreditInterest.parseKey(key)?.statementDay == Self.day("2026-12-05"))
  }

  /// The minimum: 8 % but not below 600 and never above the debt; no terms — none.
  @Test func theMinimumPayment() {
    #expect(CreditStatements.minimum(debt: Self.rub("5000"), terms: Self.terms) == Self.rub("600"))
    #expect(CreditStatements.minimum(debt: Self.rub("300"), terms: Self.terms) == Self.rub("300"))
    #expect(CreditStatements.minimum(debt: .zero, terms: Self.terms) == .zero)
    let bare = CreditCardTerms(limitE4: Self.rub("1000"))
    #expect(CreditStatements.minimum(debt: Self.rub("500"), terms: bare) == nil)
  }

  /// The 31st is the last day of every month; nothing before the first count.
  @Test func theStatementDayAndTheFirstCount() {
    #expect(
      CreditStatements.day(31, in: MonthKey(year: 2026, month: 2), calendar: Self.calendar)
        == Self.day("2026-02-28"))
    let books = Self.books(Self.twoPurchases, today: "2026-12-10")
    #expect(
      books.statements.map(\.closesOn) == [
        Self.day("2026-10-05"), Self.day("2026-11-05"), Self.day("2026-12-05"),
      ])
  }

  /// A debt already on the card when it was counted is a purchase of that moment.
  @Test func aDebtAtTheCountIsChargedToo() {
    let books = Self.books([], today: "2026-11-10", opening: "-12000")
    #expect(books.statements.last!.debtE4 == Self.rub("12000"))
    let opened = CreditStatements.withOpening(
      books.movements, account: books.account, balances: books.balances,
      calendar: Self.calendar)
    #expect(opened.map(\.amountE4) == [Self.rub("-12000")])
  }

  /// «N дней с покупки»: the whole debt is due that many days after the oldest purchase not
  /// repaid; past it, the grace is lost and interest runs from each purchase.
  @Test func daysFromThePurchase() {
    var terms = Self.terms
    terms.grace = .fromPurchase(days: 30)
    let kept = Self.books(Self.twoPurchases, today: "2026-11-01", terms: terms)
    #expect(kept.now.payBy == Self.day("2026-11-09"))
    #expect(kept.now.toPayNoInterestE4 == Self.rub("30000"))
    #expect(kept.now.graceKept)
    #expect(kept.statements.isEmpty)
    let lost = Self.books(Self.twoPurchases, today: "2026-11-20", terms: terms)
    #expect(!lost.now.graceKept)
    #expect((lost.now.estimate?.purchaseInterestE4.raw ?? 0) > 0)
  }

  // MARK: The free sum

  /// A card out of the summary keeps back what its latest statement still asks by the day; a
  /// card in the summary nothing — its minus is in the money already.
  @Test func outOfTheSummaryOnly() {
    let books = Self.books(Self.twoPurchases, today: "2026-11-10")
    let group = AccountGroup(id: Self.uuid(50), name: "Кредитки", inSummary: false)
    var outside = books.account
    outside.groupId = group.id
    let statements = [Self.cardId: books.statements]
    func snapshot(_ account: PaymentMethod) -> AccountsSnapshot {
      AccountsSnapshot.build(
        balances: books.balances, accounts: [account] + Self.accounts.dropFirst(),
        groups: [group], rubPerUnit: [.rub: 1], locale: Locale(identifier: "ru"))
    }
    #expect(
      CreditCardDues.outOfSummary(
        accounts: snapshot(outside), statements: statements, today: books.today,
        until: Self.day("2026-11-30")) == Self.rub("30000"))
    #expect(
      CreditCardDues.outOfSummary(
        accounts: snapshot(outside), statements: statements, today: books.today,
        until: Self.day("2026-11-29")) == .zero)
    #expect(
      CreditCardDues.outOfSummary(
        accounts: snapshot(books.account), statements: statements, today: books.today,
        until: Self.day("2026-11-30")) == .zero)
  }

  // MARK: Keeping only the account

  /// «Оставить только счёт»: the debt goes softly, its rate becomes the rate of purchases when
  /// the account has none; a rate there stays.
  @Test func keepingOnlyTheAccount() {
    let debt = Debt(
      id: Self.uuid(70), direction: .iOwe, type: .creditCard, name: "Т-Банк", currency: .rub,
      interestRate: Decimal(string: "34.9"))
    var bare = Self.terms
    bare.purchaseRate = nil
    let merged = CreditCardDebtMerge.keepOnlyAccount(debt: debt, account: Self.card(bare))
    #expect(merged.debtDeleted.deletedAt != nil)
    #expect(merged.account.credit?.purchaseRate == Decimal(string: "34.9"))
    let kept = CreditCardDebtMerge.keepOnlyAccount(debt: debt, account: Self.card())
    #expect(kept.account.credit?.purchaseRate == Decimal(string: "29.9"))
    #expect(CreditCardDebtMerge.offered(for: debt))
    #expect(!CreditCardDebtMerge.offered(for: merged.debtDeleted))
  }
}
