import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CorePlanning

/// The books the bank-condition suites share: two banks, a cash account, one card; everything
/// counted at noon on 1 October 2026 (utc), «today» is 15 October.
private struct BankBooks {
  static func id(_ number: Int) -> UUID {
    UUID(uuidString: String(format: "BAC00000-0000-0000-0000-%012d", number))!
  }
  static func day(_ iso: String) -> DateOnly { DateOnly(iso: iso)! }
  static func noon(_ iso: String) -> Date {
    CalendarContext.utc.startOfDay(day(iso)).addingTimeInterval(12 * 3600)
  }
  static func money(_ text: String) -> AmountE4 { amountLiteral(text) }

  static let bankX = id(1)
  static let bankY = id(2)
  static let current = id(11)  // bank X, main
  static let savings = id(12)  // bank X
  static let other = id(13)  // bank Y
  static let cash = id(14)
  static let card = id(21)
  static let today = day("2026-10-15")
  static let now = noon("2026-10-15")

  var entries: [TransactionEntry] = []
  var transfers: [Transfer] = []
  var conditions: [BankConditions] = []
  var settings = BankSettings()
  var tags: [CoreKit.Tag] = []
  var links: [PartTag] = []
  var cards: [PaymentCard] = [PaymentCard(id: card, accountId: current, name: "Visa")]
  var categories: [CoreKit.Category] = []
  var scheduled: [ScheduledPayment] = []
  var debts: [Debt] = []
  var debtEntries: [DebtEntry] = []
  var accounts: [PaymentMethod] = [
    PaymentMethod(id: current, name: "Current", currency: .rub, isDefault: true, bankId: bankX),
    PaymentMethod(id: savings, name: "Savings", currency: .rub, bankId: bankX),
    PaymentMethod(id: other, name: "Other", currency: .rub, bankId: bankY),
    PaymentMethod(id: cash, name: "Cash", kind: .cash, currency: .rub),
  ]
  /// What each account was counted at on 1 October.
  var counted: [UUID: String] = [
    current: "100000", savings: "900000", other: "500000", cash: "0",
  ]

  static func expense(
    _ number: Int, _ iso: String, _ amount: String, account: UUID = current, card: UUID? = nil,
    external: String? = nil, category: UUID? = nil, partId: UUID? = nil
  ) -> TransactionEntry {
    let when = noon(iso)
    let transactionId = id(1000 + number)
    return TransactionEntry(
      transaction: Transaction(
        id: transactionId, kind: .expense, occurredAt: when, amountE4: money(amount),
        paymentMethodId: account, externalId: external, createdAt: when, updatedAt: when,
        cardId: card),
      parts: [
        TransactionPart(
          id: partId ?? id(2000 + number), transactionId: transactionId, categoryId: category,
          quality: .neutral, qualitySource: .category, amountE4: money(amount))
      ])
  }

  static func transfer(
    _ number: Int, _ iso: String, _ amount: String, from: UUID, to: UUID
  ) -> Transfer {
    Transfer(
      id: id(3000 + number), occurredAt: noon(iso), fromAccountId: from, fromCurrency: .rub,
      fromAmountE4: money(amount), toAccountId: to, toCurrency: .rub, toAmountE4: money(amount),
      createdAt: noon(iso), updatedAt: noon(iso))
  }

  var dataset: Dataset {
    let opening = Reconciliation(
      id: Self.id(90), date: Self.day("2026-10-01"), reconciledAt: Self.noon("2026-10-01"),
      actualTotalRubE4: .zero, kind: .opening)
    let counts = accounts.compactMap { account -> ReconciledBalance? in
      counted[account.id].map {
        ReconciledBalance(
          id: UUID(), reconciliationId: opening.id, accountId: account.id, currency: .rub,
          actualE4: Self.money($0))
      }
    }
    var dataset = Dataset(
      entries: entries, categories: categories, paymentMethods: accounts, debts: debts,
      planning: PlanningBook(
        scheduled: scheduled, reconciliations: [opening], debtEntries: debtEntries,
        reconciledBalances: counts),
      transfers: transfers, cards: cards,
      banks: [Bank(id: Self.bankX, name: "Bank X"), Bank(id: Self.bankY, name: "Bank Y")],
      tagBook: TagBook(tags: tags, links: links))
    dataset.bankData = BankData(conditions: conditions, settings: settings)
    return dataset
  }

  var ledger: Ledger { Ledger(dataset: dataset, calendar: .utc) }

  var accountsSnapshot: AccountsSnapshot {
    AccountsSnapshot.build(
      dataset: dataset, now: Self.now, calendar: .utc, rubPerUnit: [:], localeIdentifier: "en")
  }

  var report: BankReport {
    BankReport.build(
      ledger: ledger, accounts: accountsSnapshot, today: Self.today, rubPerUnit: [:])
  }
}

@Suite("Banks: free limits")
struct BankLimitTests {
  private typealias B = BankBooks

  private func books() -> BankBooks {
    var books = BankBooks()
    books.conditions = [
      BankConditions(
        accountId: B.current, freeCashE4: B.money("100000"), freeSbpE4: B.money("50000"),
        freeInterbankE4: B.money("30000"))
    ]
    return books
  }

  @Test func cashTakenOutIsCountedAgainstTheCashLimit() throws {
    var books = books()
    books.transfers = [B.transfer(1, "2026-10-05", "30000", from: B.current, to: B.cash)]
    let line = try #require(books.report.limits(of: B.current).first { $0.kind == .cash })
    #expect(line.limitE4 == B.money("100000"))
    #expect(line.usedE4 == B.money("30000"))
    #expect(line.leftE4 == B.money("70000"))
    #expect(!line.exceeded)
  }

  @Test func aTransferToAnotherBankIsAnSbpTransferAndOneWithinTheBankIsFree() throws {
    var books = books()
    books.transfers = [
      B.transfer(1, "2026-10-05", "20000", from: B.current, to: B.other),
      B.transfer(2, "2026-10-06", "99000", from: B.current, to: B.savings),
    ]
    let lines = books.report.limits(of: B.current)
    let sbp = try #require(lines.first { $0.kind == .sbp })
    #expect(sbp.usedE4 == B.money("20000"))
    #expect(sbp.leftE4 == B.money("30000"))
    #expect(try #require(lines.first { $0.kind == .interbank }).usedE4 == .zero)
    #expect(try #require(lines.first { $0.kind == .cash }).usedE4 == .zero)
  }

  @Test func withoutAnSbpLimitTheTransferCountsAsInterbank() throws {
    var books = books()
    books.conditions[0].freeSbpE4 = nil
    books.transfers = [B.transfer(1, "2026-10-05", "20000", from: B.current, to: B.other)]
    let lines = books.report.limits(of: B.current)
    #expect(lines.map(\.kind) == [.cash, .interbank])
    #expect(lines.last?.usedE4 == B.money("20000"))
  }

  @Test func theSbpLimitExistsOnlyForRubleAccounts() {
    var books = books()
    books.conditions[0].currency = .usd
    #expect(!books.report.limits(of: B.current).contains { $0.kind == .sbp })
  }

  @Test func onlyTheMonthCounts() throws {
    var books = books()
    books.transfers = [B.transfer(1, "2026-09-30", "40000", from: B.current, to: B.cash)]
    #expect(try #require(books.report.limits(of: B.current).first).usedE4 == .zero)
  }

  @Test func passingTheLimitSaysByHowMuch() throws {
    var books = books()
    books.transfers = [
      B.transfer(1, "2026-10-05", "80000", from: B.current, to: B.cash),
      B.transfer(2, "2026-10-06", "30000", from: B.current, to: B.cash),
    ]
    let line = try #require(books.report.limits(of: B.current).first { $0.kind == .cash })
    #expect(line.exceeded)
    #expect(line.overE4 == B.money("10000"))
    #expect(line.leftE4 == .zero)
    let notes = books.report.notes()
    #expect(
      notes.first
        == .limitExceeded(
          accountId: B.current, kind: .cash, overE4: B.money("10000"), currency: .rub))
    #expect(notes.first?.isAlarm == true)
  }

  @Test func closeToTheLimitIsAWarningAndFarIsNothing() {
    var books = books()
    books.transfers = [B.transfer(1, "2026-10-05", "85000", from: B.current, to: B.cash)]
    let near = books.report.notes()
    #expect(
      near == [
        .limitNear(accountId: B.current, kind: .cash, leftE4: B.money("15000"), currency: .rub)
      ])
    books.transfers = [B.transfer(1, "2026-10-05", "10000", from: B.current, to: B.cash)]
    #expect(books.report.notes().isEmpty)
  }

  @Test func aMovementTheOwnerSwitchedOffIsListedAndNotCounted() throws {
    var books = books()
    let transfer = B.transfer(1, "2026-10-05", "30000", from: B.current, to: B.cash)
    books.transfers = [transfer]
    books.settings.limitOff = [transfer.id]
    let line = try #require(books.report.limits(of: B.current).first { $0.kind == .cash })
    #expect(line.usedE4 == .zero)
    #expect(line.movements.map(\.off) == [true])
    #expect(line.movements.map(\.amountE4) == [B.money("30000")])
  }

  @Test func anExpenseWithTheReservedTagCountsAsThatKind() throws {
    var books = books()
    let tag = CoreKit.Tag(name: BankLimitTags.sbp)
    let entry = B.expense(1, "2026-10-07", "12000")
    books.tags = [tag]
    books.links = [PartTag(partId: entry.parts[0].id, tagId: tag.id)]
    books.entries = [entry, B.expense(2, "2026-10-08", "999")]
    let line = try #require(books.report.limits(of: B.current).first { $0.kind == .sbp })
    #expect(line.usedE4 == B.money("12000"))
    #expect(line.movements.first?.source == .operation)
  }

  @Test func theSettingsKeepTheSwitchedOffMovements() {
    let id = UUID()
    let settings = BankSettings(
      forgottenDays: 60, limitOff: [id], insuranceLimitE4: B.money("1500000"))
    let stored = settings.storedValues.compactMapValues { $0 }
    #expect(BankSettings(storedValues: stored) == settings)
    #expect(BankSettings().storedValues.values.allSatisfy { $0 == nil })
    #expect(BankSettings(storedValues: [BankSettings.forgottenDaysKey: "0"]).forgottenDays == 90)
  }
}

@Suite("Banks: free service, the minimum balance")
struct BankServiceTests {
  private typealias B = BankBooks

  @Test func spendingOnTheCardsOfTheAccountIsWhatCountsTowardFreeService() throws {
    var books = BankBooks()
    books.conditions = [
      BankConditions(accountId: B.current, serviceFreeSpendE4: B.money("10000"))
    ]
    books.entries = [
      B.expense(1, "2026-10-03", "4000", card: B.card),
      B.expense(2, "2026-10-04", "2600", card: B.card),
      // Not a card purchase, a purchase of last month, another account's, and a fee.
      B.expense(3, "2026-10-05", "5000"),
      B.expense(4, "2026-09-28", "5000", card: B.card),
      B.expense(5, "2026-10-05", "700", account: B.other, card: B.card),
      B.expense(
        6, "2026-10-05", "50",
        card: B.card, external: "transfer:\(UUID().uuidString.lowercased()):fee"),
    ]
    let progress = try #require(books.report.service(of: B.current))
    #expect(progress.spentE4 == B.money("6600"))
    #expect(progress.spendLeftE4 == B.money("3400"))
    #expect(progress.through == B.day("2026-10-31"))
    #expect(!progress.isFree)
  }

  @Test func reachingTheSpendingOrKeepingTheBalanceMakesItFree() throws {
    var books = BankBooks()
    books.conditions = [
      BankConditions(
        accountId: B.current, serviceFreeSpendE4: B.money("10000"),
        serviceFreeBalanceE4: B.money("90000"))
    ]
    books.entries = [B.expense(1, "2026-10-03", "11000", card: B.card)]
    // 100 000 − 11 000 = 89 000 is below 90 000, but the spending is met.
    var progress = try #require(books.report.service(of: B.current))
    #expect(progress.spendMet && !progress.balanceMet && progress.isFree)
    #expect(progress.spendLeftE4 == .zero)
    books.entries = []
    progress = try #require(books.report.service(of: B.current))
    #expect(progress.balanceMet && progress.isFree)
    #expect(progress.balanceShortE4 == .zero)
    books.counted[B.current] = "80000"
    progress = try #require(books.report.service(of: B.current))
    #expect(!progress.isFree)
    #expect(progress.balanceShortE4 == B.money("10000"))
  }

  @Test func anAccountWithoutAServiceConditionHasNoProgress() {
    var books = BankBooks()
    books.conditions = [BankConditions(accountId: B.current, freeCashE4: B.money("1"))]
    #expect(books.report.service.isEmpty)
  }

  @Test func fallingBelowTheMinimumIsWarnedAboutOnlyWhenItWouldCrossIt() throws {
    let warning = try #require(
      BankMinBalance.warning(
        balanceE4: B.money("55000"), spendE4: B.money("15000"), minimumE4: B.money("50000"),
        currency: .rub))
    #expect(warning.afterE4 == B.money("40000"))
    #expect(warning.minimumE4 == B.money("50000"))
    #expect(
      BankMinBalance.warning(
        balanceE4: B.money("55000"), spendE4: B.money("5000"), minimumE4: B.money("50000"),
        currency: .rub) == nil)
    // Already below: the card says so, the entry is not nagged at.
    #expect(
      BankMinBalance.warning(
        balanceE4: B.money("45000"), spendE4: B.money("1000"), minimumE4: B.money("50000"),
        currency: .rub) == nil)
    #expect(
      BankMinBalance.warning(
        balanceE4: B.money("55000"), spendE4: .zero, minimumE4: B.money("50000"), currency: .rub)
        == nil)
  }

  @Test func aBalanceBelowTheMinimumIsARiskAndAnAlarm() throws {
    var books = BankBooks()
    books.conditions = [BankConditions(accountId: B.current, minBalanceE4: B.money("120000"))]
    let risk = try #require(books.report.minBalanceRisk(of: B.current))
    #expect(risk.shortE4 == B.money("20000"))
    #expect(
      BankMinBalance.shortfall(balanceE4: B.money("1"), minimumE4: B.money("3")) == B.money("2"))
    #expect(BankMinBalance.shortfall(balanceE4: B.money("3"), minimumE4: B.money("3")) == nil)
    #expect(books.report.notes().first?.isAlarm == true)
    books.conditions[0].minBalanceE4 = B.money("100000")
    #expect(books.report.minBalance.isEmpty)
  }
}

@Suite("Banks: the fees of the year")
struct BankFeesReportTests {
  private typealias B = BankBooks

  @Test func feesAndInterestAddUpMonthByMonth() throws {
    var books = BankBooks()
    let fees = CoreKit.Category(id: BankBooks.id(70), kind: .expense, name: "Комиссии")
    let service = CoreKit.Category(
      id: BankBooks.id(71), parentId: fees.id, kind: .expense, name: "Обслуживание")
    books.categories = [fees, service]
    books.entries = [
      B.expense(1, "2026-02-03", "300", category: fees.id),
      B.expense(2, "2026-02-20", "590", category: service.id),
      B.expense(3, "2026-10-01", "100", category: fees.id),
      B.expense(
        4, "2026-03-05", "1200", external: "ccinterest:\(UUID().uuidString.lowercased()):2026-03-01"
      ),
      B.expense(5, "2025-12-31", "9999", category: fees.id),
      B.expense(6, "2026-04-04", "4000"),
    ]
    let report = BankFeesReport.year(2026, ledger: books.ledger, rubPerUnit: [:])
    #expect(report.months.count == 12)
    #expect(report.feesRub == B.money("990"))
    #expect(report.interestRub == B.money("1200"))
    #expect(report.totalRub == B.money("2190"))
    #expect(report.months[1].feesRub == B.money("890"))
    #expect(report.months[2].interestRub == B.money("1200"))
    #expect(!report.isEmpty)
    #expect(BankFeesReport.year(2024, ledger: books.ledger, rubPerUnit: [:]).isEmpty)
  }

  @Test func interestPaidOnALoanThatAccruesItIsCounted() throws {
    var books = BankBooks()
    let debtId = B.id(80)
    books.debts = [
      Debt(
        id: debtId, direction: .iOwe, type: .loan, name: "Loan", currency: .rub,
        interestRate: 12, accruesInterest: true)
    ]
    books.debtEntries = [
      DebtEntry(
        id: B.id(81), debtId: debtId, date: B.day("2026-01-01"), amountE4: B.money("100000"),
        kind: .borrowed),
      DebtEntry(
        id: B.id(82), debtId: debtId, date: B.day("2026-02-01"), amountE4: B.money("-5000"),
        kind: .payment),
    ]
    let report = BankFeesReport.year(2026, ledger: books.ledger, rubPerUnit: [:])
    #expect(report.interestRub.raw > 0)
    #expect(report.months[1].interestRub == report.interestRub)
  }

  @Test func theCsvHasTheShapeOfTheOtherReports() {
    let months = (1...12).map {
      BankFeesMonth(
        month: MonthKey(year: 2026, month: $0),
        feesRub: $0 == 1 ? B.money("100.5") : .zero, interestRub: $0 == 2 ? B.money("200") : .zero)
    }
    let csv = String(
      decoding: BankFeesReport.csv(BankFeesYear(year: 2026, months: months)), as: UTF8.self)
    let lines = csv.split(separator: "\n").map(String.init)
    #expect(lines.count == 14)
    #expect(
      lines[0]
        == "row_type,name,fees_rub,fees_rub_exact,interest_rub,interest_rub_exact,total_rub,total_rub_exact"
    )
    #expect(lines[1] == "item,2026-01,101,100.5000,0,0.0000,101,100.5000")
    #expect(lines[13] == "total,Total,101,100.5000,200,200.0000,301,300.5000")
    #expect(!csv.hasPrefix("\u{FEFF}"))
  }
}

@Suite("Banks: the insurance of deposits")
struct BankInsuranceTests {
  private typealias B = BankBooks

  @Test func theLimitIsTheOneInForceOnTheDay() {
    #expect(DepositInsurance.limitE4(on: B.day("2026-10-15")) == B.money("1400000"))
    #expect(DepositInsurance.limitE4(on: B.day("2023-03-29")) == B.money("1400000"))
    #expect(DepositInsurance.limitE4(on: B.day("2023-03-28")) == B.money("700000"))
    #expect(
      DepositInsurance.limitE4(on: B.day("2026-10-15"), override: B.money("2000000"))
        == B.money("2000000"))
    #expect(DepositInsurance.since(on: B.day("2026-10-15")) == B.day("2023-03-29"))
  }

  @Test func theMoneyOfAllTheAccountsOfABankIsAddedUp() throws {
    let books = BankBooks()
    // Bank X: 100 000 + 900 000 = 1 000 000; bank Y: 500 000; the cash account is not in a bank.
    let report = books.report
    #expect(report.insurance.map(\.name) == ["Bank X", "Bank Y"])
    let x = try #require(report.insurance(of: B.bankX))
    #expect(x.totalRub == B.money("1000000"))
    #expect(x.accountIds.count == 2)
    #expect(x.limitRub == B.money("1400000"))
    #expect(!x.isOver)
    #expect(report.notes().isEmpty)
  }

  @Test func overTheLimitIsSaidAndCanBePutAway() throws {
    var books = BankBooks()
    books.counted[B.savings] = "1300000"
    let report = books.report
    let x = try #require(report.insurance(of: B.bankX))
    #expect(x.totalRub == B.money("1400000") + B.money("0"))
    books.counted[B.savings] = "1400001"
    let over = try #require(books.report.insurance(of: B.bankX))
    #expect(over.isOver)
    #expect(over.overRub == B.money("100001"))
    let notes = books.report.notes()
    #expect(notes.count == 1)
    let note = try #require(notes.first)
    #expect(note.canBePutAway)
    #expect(books.report.notes(dismissed: [note.id]).isEmpty)
    books.settings.insuranceLimitE4 = B.money("5000000")
    #expect(books.report.notes().isEmpty)
  }
}

@Suite("Banks: forgotten money and the end of a card")
struct BankForgottenTests {
  private typealias B = BankBooks

  @Test func aProductNothingMovedOnForNinetyDaysIsForgotten() throws {
    var books = BankBooks()
    books.entries = [
      B.expense(1, "2026-10-10", "100"),  // the current account is in use
      B.expense(2, "2026-06-01", "100", account: B.other),  // 136 days
    ]
    // Savings: never touched since the count on 1 October, 14 days: not forgotten.
    let list = books.report.forgotten
    #expect(list.map(\.accountId) == [B.other])
    #expect(list[0].idleDays == 136)
    #expect(list[0].balanceRub == B.money("500000"))
    #expect(list[0].lastMove == B.day("2026-06-01"))
  }

  @Test func aTransferIsAMovement() {
    var books = BankBooks()
    books.entries = [B.expense(1, "2026-06-01", "100", account: B.other)]
    books.transfers = [B.transfer(1, "2026-10-01", "10", from: B.savings, to: B.other)]
    #expect(books.report.forgotten.isEmpty)
  }

  @Test func theNumberOfDaysIsASetting() {
    var books = BankBooks()
    books.entries = [B.expense(1, "2026-09-01", "100", account: B.other)]
    #expect(books.report.forgotten.isEmpty)  // 44 days
    books.settings.forgottenDays = 30
    #expect(books.report.forgotten.map(\.accountId) == [B.other])
  }

  @Test func aDepositThatIsStillRunningIsNotForgotten() {
    var books = BankBooks()
    books.entries = [B.expense(1, "2026-01-01", "100", account: B.other)]
    books.accounts[2].interest = DepositTerms(
      rate: 15, period: .atEnd, openedOn: B.day("2026-01-01"), endsOn: B.day("2027-01-01"))
    #expect(books.report.forgotten.isEmpty)
    books.accounts[2].interest?.endsOn = B.day("2026-07-01")
    #expect(books.report.forgotten.map(\.accountId) == [B.other])
  }

  @Test func anEmptyAccountIsForgottenOnlyWhenItCharges() {
    var books = BankBooks()
    books.counted[B.other] = "0"
    books.entries = [B.expense(1, "2026-01-01", "100", account: B.other)]
    #expect(books.report.forgotten.isEmpty)
    books.conditions = [BankConditions(accountId: B.other, serviceFreeBalanceE4: B.money("1000"))]
    let list = books.report.forgotten
    #expect(list.map(\.accountId) == [B.other])
    #expect(list[0].mayCharge)
  }

  @Test func theNoteCountsTheProductsAndComesBackEveryMonth() throws {
    var books = BankBooks()
    books.entries = [B.expense(1, "2026-06-01", "100", account: B.other)]
    let note = try #require(books.report.notes().first)
    #expect(
      note
        == .forgotten(
          count: 1, balanceRub: B.money("500000"), month: MonthKey(year: 2026, month: 10)))
    #expect(books.report.notes(dismissed: [note.id]).isEmpty)
    #expect(
      note.id
        != BankNote.forgotten(count: 1, balanceRub: .zero, month: MonthKey(year: 2026, month: 11))
        .id)
  }

  @Test func aCardIsRemindedAMonthBeforeItsLastMonthEnds() throws {
    var books = BankBooks()
    #expect(books.report.cardExpiries.isEmpty)
    books.cards[0].expiresOn = MonthKey(year: 2026, month: 11)  // works to 30 November
    #expect(books.report.cardExpiries.isEmpty)  // 15 October: the reminder starts on 31 October
    books.cards[0].expiresOn = MonthKey(year: 2026, month: 10)  // works to 31 October
    let expiry = try #require(books.report.cardExpiries.first)
    #expect(!expiry.expired)
    #expect(expiry.cardId == B.card)
    books.cards[0].expiresOn = MonthKey(year: 2026, month: 9)
    #expect(try #require(books.report.cardExpiries.first).expired)
    books.cards[0].archived = true
    #expect(books.report.cardExpiries.isEmpty)
  }

  @Test func theListOfWhatToRebindHasThePaymentsAndSubscriptionsOfTheCard() throws {
    var books = BankBooks()
    books.cards[0].expiresOn = MonthKey(year: 2026, month: 10)
    books.accounts[0].mainCardId = B.card
    books.scheduled = [
      ScheduledPayment(
        id: B.id(60), name: "Music", kind: .subscription, amountE4: B.money("199"),
        paymentMethodId: B.current, freq: .monthly, cardId: B.card),
      ScheduledPayment(
        id: B.id(61), name: "Rent", kind: .bill, amountE4: B.money("50000"),
        paymentMethodId: B.current, freq: .monthly, cardId: B.card),
      ScheduledPayment(
        id: B.id(62), name: "Gym", kind: .bill, amountE4: B.money("3000"),
        paymentMethodId: B.current, freq: .monthly, cardId: nil),
      ScheduledPayment(
        id: B.id(63), name: "Old", kind: .bill, amountE4: B.money("1"),
        paymentMethodId: B.current, freq: .monthly, active: false, cardId: B.card),
    ]
    let expiry = try #require(books.report.cardExpiries.first)
    #expect(expiry.attached.map(\.name) == ["Music", "Rent"])
    #expect(expiry.attached.map(\.isSubscription) == [true, false])
    #expect(expiry.isMain)
    guard case .cardExpiry(_, _, _, _, let count) = try #require(books.report.notes().first) else {
      Issue.record("a card note")
      return
    }
    #expect(count == 2)
  }
}
