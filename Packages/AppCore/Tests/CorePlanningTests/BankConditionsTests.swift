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

  @Test func aTransferToOwnAccountInAnotherBankHasItsOwnSbpLimitAndOneWithinTheBankIsFree() throws {
    var books = books()
    books.transfers = [
      B.transfer(1, "2026-10-05", "20000", from: B.current, to: B.other),
      B.transfer(2, "2026-10-06", "99000", from: B.current, to: B.savings),
    ]
    let lines = books.report.limits(of: B.current)
    // Money sent to oneself in another bank is not money sent to people: the limit for people
    // stays untouched and the limit for oneself is the 30 million of the system.
    #expect(try #require(lines.first { $0.kind == .sbp }).usedE4 == .zero)
    let own = try #require(lines.first { $0.kind == .sbpOwn })
    #expect(own.limitE4 == B.money("30000000"))
    #expect(own.usedE4 == B.money("20000"))
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

@Suite("Banks: SBP fee estimate, card count, cashback note")
struct BankRuExtrasTests {
  private typealias B = BankBooks

  private func line(_ limit: String, _ amounts: [String]) -> BankLimitLine {
    let movements = amounts.enumerated().map { index, amount in
      BankLimitMovement(
        id: B.id(100 + index), source: .operation, accountId: B.current, kind: .sbp,
        day: B.day("2026-10-0\(index + 1)"), amountE4: B.money(amount))
    }.reversed()
    return BankLimitLine(
      accountId: B.current, kind: .sbp, currency: .rub, limitE4: B.money(limit),
      usedE4: AmountE4.sum(movements.map(\.amountE4)), movements: Array(movements))
  }

  @Test func nothingIsTakenWithinTheLimit() {
    #expect(line("100000", ["60000", "40000"]).feeEstimateE4 == .zero)
  }

  @Test func halfAPercentOfTheUnfreePartOfEachTransfer() {
    // 40 000 fits; of 30 000 the last 20 000 is past the limit: 0.5 % of it.
    #expect(line("50000", ["40000", "30000"]).feeEstimateE4 == B.money("100"))
    // The transfer after that is past the limit as a whole.
    #expect(line("50000", ["40000", "30000", "10000"]).feeEstimateE4 == B.money("150"))
  }

  @Test func aTransferIsNeverCharged1500Plus() {
    #expect(line("50000", ["1000000"]).feeEstimateE4 == B.money("1500"))
  }

  @Test func theEstimateIsOnlyForTransfersToPeople() {
    var own = line("50000", ["100000"])
    own.kind = .sbpOwn
    #expect(own.feeEstimateE4 == .zero)
  }

  @Test func theSwitchedOffTransferIsNotCharged() {
    var charged = line("50000", ["40000", "30000"])
    charged.movements[0].off = true
    #expect(charged.feeEstimateE4 == .zero)
  }

  @Test func ownLimitIsWhereTheAccountStatesSbp() {
    var books = BankBooks()
    books.conditions = [BankConditions(accountId: B.current, freeSbpE4: B.money("100000"))]
    #expect(books.report.limits(of: B.current).map(\.kind) == [.sbp, .sbpOwn])
    books.conditions = [BankConditions(accountId: B.current, freeCashE4: B.money("1"))]
    #expect(books.report.limits(of: B.current).map(\.kind) == [.cash])
  }

  @Test func theCardsOfTheOwnerAreCountedAcrossBanks() {
    var books = BankBooks()
    books.cards = (0..<18).map { number in
      PaymentCard(
        id: B.id(500 + number), accountId: number % 2 == 0 ? B.current : B.other,
        name: "Card \(number)")
    }
    books.cards.append(PaymentCard(id: B.id(600), accountId: B.cash, name: "Cash card"))
    books.cards.append(
      PaymentCard(id: B.id(601), accountId: B.current, name: "Closed", archived: true))
    let status = CardCount.status(ledger: books.ledger, today: B.today)
    #expect(status.count == 18)
    #expect(status.limit == 20)
    #expect(status.left == 2)
    #expect(status.isNear && !status.isAtLimit && !status.isOver)
    #expect(status.limitFrom == B.day("2027-09-01"))
    #expect(!status.inForce(on: B.today))
    #expect(status.inForce(on: B.day("2027-09-01")))
  }

  @Test func theCountSaysNothingFarFromTheCap() {
    var books = BankBooks()
    books.cards = (0..<10).map { PaymentCard(id: B.id(500 + $0), accountId: B.current, name: "C") }
    let status = CardCount.status(ledger: books.ledger, today: B.today)
    #expect(!status.isNear)
    #expect(BankReport.build(
      ledger: books.ledger, accounts: books.accountsSnapshot, today: B.today, rubPerUnit: [:]
    ).notes().isEmpty)
  }

  @Test func aCardNothingWasPaidWithIsListedAndTheLongestIdleComesFirst() {
    var books = BankBooks()
    let recent = PaymentCard(id: B.id(701), accountId: B.current, name: "Recent")
    let old = PaymentCard(id: B.id(702), accountId: B.current, name: "Old")
    let never = PaymentCard(id: B.id(703), accountId: B.current, name: "Never")
    books.cards = [recent, old, never]
    books.entries = [
      B.expense(1, "2026-10-10", "100", card: recent.id),
      B.expense(2, "2026-05-01", "100", card: old.id),
    ]
    let status = CardCount.status(ledger: books.ledger, today: B.today)
    #expect(status.unused == [never.id, old.id])
  }

  @Test func aCardOfSomeoneElseIsNotOurs() {
    var books = BankBooks()
    var borrowed = PaymentMethod(id: B.id(801), name: "Mum", currency: .rub)
    borrowed.borrowed = BorrowedCardTerms()
    books.accounts.append(borrowed)
    books.cards = [PaymentCard(id: B.id(802), accountId: borrowed.id, name: "Mum card")]
    #expect(CardCount.status(ledger: books.ledger, today: B.today).count == 0)
  }

  @Test func theNoteAppearsFromEighty() {
    var books = BankBooks()
    books.cards = (0..<16).map { PaymentCard(id: B.id(500 + $0), accountId: B.current, name: "C") }
    let notes = BankReport.build(
      ledger: books.ledger, accounts: books.accountsSnapshot, today: B.today, rubPerUnit: [:]
    ).notes()
    #expect(notes == [.cardCount(count: 16, limit: 20, from: B.day("2027-09-01"), inForce: false)])
  }

  @Test func largeYearlyCashbackBringsTheNoteAndSmallBringsNone() throws {
    var books = BankBooks()
    var big = B.expense(1, "2026-03-01", "500000")
    big.transaction.cashback = Money(amount: B.money("120000"), currency: .rub)
    var lastYear = B.expense(2, "2025-12-31", "500000")
    lastYear.transaction.cashback = Money(amount: B.money("900000"), currency: .rub)
    books.entries = [big, lastYear]
    let note = try #require(
      CashbackTax.note(ledger: books.ledger, today: B.today, rubPerUnit: [:]))
    #expect(note.year == 2026)
    #expect(note.totalRub == B.money("120000"))
    var small = B.expense(3, "2026-04-01", "1000")
    small.transaction.cashback = Money(amount: B.money("50"), currency: .rub)
    books.entries = [small]
    #expect(CashbackTax.note(ledger: books.ledger, today: B.today, rubPerUnit: [:]) == nil)
  }
}

@Suite("Banks: tax on the interest of deposits")
struct InterestTaxTests {
  private func rub(_ whole: Int64) -> AmountE4 { AmountE4(whole: whole) }

  @Test func theFreeSumOfEachYearIsTheKeyRateTimesAMillion() {
    #expect(InterestTax.exemption(year: 2025).amountE4 == rub(210_000))
    #expect(!InterestTax.exemption(year: 2025).isEstimate)
    #expect(InterestTax.exemption(year: 2026).amountE4 == rub(160_000))
    // The year is not over: December can still move the rate.
    #expect(InterestTax.exemption(year: 2026).isEstimate)
  }

  @Test func aYearTheTableDoesNotKnowTakesTheLastOneAsAnEstimate() {
    let later = InterestTax.exemption(year: 2030)
    #expect(later.amountE4 == rub(160_000))
    #expect(later.isEstimate)
  }

  @Test func nothingIsOwedBelowTheFreeSum() {
    let figure = InterestTax.figure(year: 2026, interestRub: rub(160_000))
    #expect(figure.taxableE4 == .zero)
    #expect(figure.taxE4 == .zero)
  }

  @Test func thirteenPercentOfWhatIsPast() {
    let figure = InterestTax.figure(year: 2025, interestRub: rub(300_000))
    #expect(figure.taxableE4 == rub(90_000))
    #expect(figure.taxE4 == rub(11_700))
    #expect(figure.dueDay == DateOnly(year: 2026, month: 12, day: 1))
    #expect(!figure.isEstimate)
  }

  @Test func fifteenPercentPastTwoPointFourMillion() {
    // 3 000 000 − 160 000 = 2 840 000: 13 % of 2 400 000 and 15 % of the 440 000 past it.
    let figure = InterestTax.figure(year: 2026, interestRub: rub(3_000_000))
    #expect(figure.taxE4 == rub(312_000 + 66_000))
  }

  @Test func theTaxIsRoundedToTheWholeRuble() {
    // 13 % of 1 003.50 is 130.455.
    let figure = InterestTax.figure(
      year: 2026, interestRub: rub(160_000) + AmountE4(raw: 1_003_5000))
    #expect(figure.taxE4 == rub(130))
  }

  private func booksWithInterest(received: [(String, String)]) -> (BankBooks, UUID) {
    var books = BankBooks()
    let category = UUID(uuidString: "BAC00000-0000-0000-0000-000000009999")!
    books.categories = [CoreKit.Category(id: category, kind: .income, name: "Interest")]
    for (index, item) in received.enumerated() {
      let when = BankBooks.noon(item.0)
      let id = BankBooks.id(7000 + index)
      books.entries.append(
        TransactionEntry(
          transaction: Transaction(
            id: id, kind: .income, occurredAt: when, amountE4: BankBooks.money(item.1),
            paymentMethodId: BankBooks.current, createdAt: when, updatedAt: when),
          parts: [
            TransactionPart(
              id: BankBooks.id(8000 + index), transactionId: id, categoryId: category,
              quality: .neutral, qualitySource: .category,
              amountE4: BankBooks.money(item.1))
          ]))
    }
    return (books, category)
  }

  @Test func theYearAddsWhatWasWrittenAndWhatIsStillToCome() {
    let (books, category) = booksWithInterest(received: [
      ("2026-02-01", "100000"), ("2025-12-01", "999999"),
    ])
    let payout = DepositPayout(
      accountId: BankBooks.current, target: BalanceKey(accountId: BankBooks.current, currency: .rub),
      periodStart: BankBooks.day("2026-10-01"), payDate: BankBooks.day("2026-11-01"),
      accruedE4: BankBooks.money("30000"), expectedE4: BankBooks.money("90000"),
      capitalized: false, state: .accruing)
    let year = InterestTax.year(
      ledger: books.ledger, payouts: [payout], interestCategoryId: category,
      today: BankBooks.today, rubPerUnit: [:])
    #expect(year.receivedE4 == BankBooks.money("100000"))
    #expect(year.accruedE4 == BankBooks.money("30000"))
    #expect(year.expectedE4 == BankBooks.money("190000"))
    // 190 000 − 160 000 = 30 000, 13 % of it; through today 130 000 is still free of tax.
    #expect(year.forecast.taxE4 == rub(3_900))
    #expect(year.sofar.taxE4 == .zero)
  }

  @Test func aPayoutAlreadyWrittenIsNotCountedTwice() {
    let (books, category) = booksWithInterest(received: [("2026-02-01", "100000")])
    let payout = DepositPayout(
      accountId: BankBooks.current, target: BalanceKey(accountId: BankBooks.current, currency: .rub),
      periodStart: BankBooks.day("2026-01-01"), payDate: BankBooks.day("2026-02-01"),
      accruedE4: BankBooks.money("100000"), expectedE4: BankBooks.money("100000"),
      capitalized: false, state: .received(UUID()))
    let year = InterestTax.year(
      ledger: books.ledger, payouts: [payout], interestCategoryId: category,
      today: BankBooks.today, rubPerUnit: [:])
    #expect(year.expectedE4 == BankBooks.money("100000"))
  }

  @Test func aPayoutInAForeignCurrencyWithoutARateIsListedNotGuessed() {
    let (books, category) = booksWithInterest(received: [])
    let payout = DepositPayout(
      accountId: BankBooks.current, target: BalanceKey(accountId: BankBooks.current, currency: .usd),
      periodStart: BankBooks.day("2026-10-01"), payDate: BankBooks.day("2026-11-01"),
      accruedE4: BankBooks.money("30"), expectedE4: BankBooks.money("90"),
      capitalized: false, state: .accruing)
    let year = InterestTax.year(
      ledger: books.ledger, payouts: [payout], interestCategoryId: category,
      today: BankBooks.today, rubPerUnit: [:])
    #expect(year.expectedE4 == .zero)
    #expect(year.withoutRate == [.usd])
  }

  @Test func theReserveGrowsWithTheInterestPastTheFreeSum() {
    let (books, category) = booksWithInterest(received: [("2026-02-01", "260000")])
    let year = InterestTax.year(
      ledger: books.ledger, payouts: [], interestCategoryId: category,
      today: BankBooks.today, rubPerUnit: [:])
    #expect(year.sofar.taxE4 == rub(13_000))
    let plan = CashPlan(interestTax: year.sofar.taxE4)
    #expect(plan.total == rub(13_000))
  }
}

@Suite("Banks: the debt burden the way a bank reads it")
struct BankPdnTests {
  private typealias B = BankBooks
  private let october = MonthKey(year: 2026, month: 10)

  private func state(_ id: UUID, monthly: String) -> DebtDueState {
    DebtDueState(
      debtId: id, firstDue: B.day("2026-09-05"), paidCount: 1, owes: true, paymentDay: 5,
      balanceE4: B.money("500000"), monthlyE4: B.money(monthly))
  }

  private func fixture() -> (debts: [Debt], states: [UUID: DebtDueState], accounts: [PaymentMethod]) {
    let loan = Debt(
      id: B.id(901), direction: .iOwe, type: .loan, name: "Bank", monthlyPaymentE4: B.money("30000"),
      paymentDay: 5)
    let split = Debt(
      id: B.id(902), direction: .iOwe, type: .installment, name: "Split",
      monthlyPaymentE4: B.money("5000"), paymentDay: 5, origin: .purchase, parts: 4)
    let card = PaymentMethod(
      id: B.id(903), name: "Credit", currency: .rub,
      credit: CreditCardTerms(limitE4: B.money("200000")))
    return (
      [loan, split], [loan.id: state(loan.id, monthly: "30000"), split.id: state(split.id, monthly: "5000")],
      [card]
    )
  }

  @Test func aCardWeighsFivePercentOfItsLimitAndAnInstalmentIsToldApart() {
    let set = fixture()
    let pdn = BankPdn.build(
      month: october, debts: set.debts, states: set.states, accounts: set.accounts,
      incomeRub: B.money("100000"), rubPerUnit: [:])
    #expect(pdn.creditsRub == B.money("30000"))
    #expect(pdn.cardsRub == B.money("10000"))
    #expect(pdn.instalmentsRub == B.money("5000"))
    // As the credit history sees it: 40 %; with the instalment, 45 %.
    #expect(pdn.bankBp == 4_000)
    #expect(pdn.withInstalmentsBp == 4_500)
  }

  @Test func theCautiousIncomeIsNineTenths() {
    let set = fixture()
    let pdn = BankPdn.build(
      month: october, debts: set.debts, states: set.states, accounts: set.accounts,
      incomeRub: B.money("100000"), rubPerUnit: [:])
    #expect(pdn.cautiousIncomeRub == B.money("90000"))
    // 40 000 over 90 000 is 44.44 %, to the basis point 4 444.
    #expect(pdn.cautiousBp == 4_444)
    #expect(pdn.cautiousWithInstalmentsBp == 5_000)
  }

  @Test func withoutAnIncomeThereIsNoFigure() {
    let set = fixture()
    let pdn = BankPdn.build(
      month: october, debts: set.debts, states: set.states, accounts: set.accounts,
      incomeRub: nil, rubPerUnit: [:])
    #expect(pdn.bankBp == nil && pdn.withInstalmentsBp == nil && pdn.cautiousBp == nil)
    #expect(pdn.bankPaymentsRub == B.money("40000"))
  }

  @Test func aCardInADollarLimitWithoutARateIsListedNotGuessed() {
    var set = fixture()
    set.accounts[0].currency = .usd
    let pdn = BankPdn.build(
      month: october, debts: set.debts, states: set.states, accounts: set.accounts,
      incomeRub: B.money("100000"), rubPerUnit: [:])
    #expect(pdn.cardsRub == .zero)
    #expect(pdn.withoutRate == [B.id(903)])
    let rated = BankPdn.build(
      month: october, debts: set.debts, states: set.states, accounts: set.accounts,
      incomeRub: B.money("100000"), rubPerUnit: [.usd: 100])
    #expect(rated.cardsRub == B.money("1000000"))
  }

  @Test func aCreditCardKeptAsADebtIsNotCountedTwice() {
    var set = fixture()
    set.debts.append(
      Debt(
        id: B.id(904), direction: .iOwe, type: .creditCard, name: "Card debt",
        monthlyPaymentE4: B.money("7000"), paymentDay: 5))
    set.states[B.id(904)] = state(B.id(904), monthly: "7000")
    let pdn = BankPdn.build(
      month: october, debts: set.debts, states: set.states, accounts: set.accounts,
      incomeRub: B.money("100000"), rubPerUnit: [:])
    #expect(pdn.creditsRub == B.money("30000"))
  }
}

@Suite("Banks: the fee for an account without a card")
struct NoCardFeeTests {
  private typealias B = BankBooks

  @Test func anAccountWithoutACardPaysTheStatedFee() {
    var books = BankBooks()
    // The savings account has no card; the current one has one.
    books.cards = [PaymentCard(id: B.card, accountId: B.current, name: "Visa")]
    let lines = NoCardFee.lines(
      dataset: books.dataset, fees: [B.savings: B.money("150"), B.current: B.money("150")],
      service: [])
    #expect(lines == [NoCardFeeLine(accountId: B.savings, monthlyFeeE4: B.money("150"), currency: .rub)])
  }

  @Test func aMetConditionOfFreeServiceTakesTheFeeAway() {
    var books = BankBooks()
    books.cards = []
    let met = BankServiceProgress(
      accountId: B.savings, currency: .rub, spendTargetE4: B.money("5000"),
      spentE4: B.money("5000"), balanceTargetE4: nil, balanceE4: nil, through: B.today)
    #expect(
      NoCardFee.lines(dataset: books.dataset, fees: [B.savings: B.money("150")], service: [met])
        .isEmpty)
  }

  @Test func cashArchivedAndUnstatedAccountsArePassedOver() {
    var books = BankBooks()
    books.cards = []
    books.accounts[1].archived = true
    let lines = NoCardFee.lines(
      dataset: books.dataset, fees: [B.cash: B.money("150"), B.savings: B.money("150")],
      service: [])
    #expect(lines.isEmpty)
    #expect(
      NoCardFee.lines(dataset: books.dataset, fees: [B.other: .zero], service: []).isEmpty)
  }

  @Test func theLargestFeeComesFirst() {
    var books = BankBooks()
    books.cards = []
    let lines = NoCardFee.lines(
      dataset: books.dataset, fees: [B.savings: B.money("100"), B.other: B.money("300")],
      service: [])
    #expect(lines.map(\.accountId) == [B.other, B.savings])
  }
}
