import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CorePlanning

// Synthetic data only.

/// A small book with someone else's card: Т-Банк (main, rubles, counted 100 000 ₽ on 10
/// September) and «Карта папы», whose money is the father's. Someone even counted the card once —
/// an older build, a hand edit —: it must count for nothing.
private struct BorrowedBook {
  static func id(_ number: Int) -> UUID {
    UUID(uuidString: String(format: "BB000000-0000-0000-0000-%012d", number))!
  }
  static func day(_ iso: String) -> DateOnly { DateOnly(iso: iso)! }
  static func noon(_ iso: String) -> Date {
    CalendarContext.utc.startOfDay(day(iso)).addingTimeInterval(12 * 3600)
  }
  static func money(_ whole: Int64) -> AmountE4 { AmountE4(whole: whole) }

  static let tbank = id(1)
  static let papa = id(2)
  static let father = id(3)
  static let groceries = id(4)
  static let cafe = id(5)
  static let counted = noon("2026-09-10")
  static let now = noon("2026-09-19")

  var accounts: [PaymentMethod] = [
    PaymentMethod(id: tbank, name: "Т-Банк", currency: .rub, isDefault: true),
    PaymentMethod(
      id: papa, name: "Карта папы", currency: .rub, borrowed: BorrowedCardTerms(personId: father)),
  ]
  var entries: [TransactionEntry] = [
    expense(41, "2026-09-12", 1_500, account: tbank, category: cafe),
    expense(42, "2026-09-13", 4_000, account: papa, category: groceries),
    expense(43, "2026-09-14", 600, account: papa, category: cafe),
    // August: not this month.
    expense(44, "2026-08-20", 900, account: papa, category: groceries),
  ]
  var transfers: [Transfer] = []
  var counts: [ReconciledBalance] = [
    ReconciledBalance(
      id: id(31), reconciliationId: id(21), accountId: tbank, currency: .rub,
      actualE4: money(100_000)),
    ReconciledBalance(
      id: id(32), reconciliationId: id(21), accountId: papa, currency: .rub,
      actualE4: money(70_000)),
  ]

  static func expense(
    _ number: Int, _ iso: String, _ whole: Int64, account: UUID, category: UUID,
    kind: TransactionKind = .expense, refundOf: UUID? = nil
  ) -> TransactionEntry {
    let when = noon(iso)
    let transactionId = id(1000 + number)
    return TransactionEntry(
      transaction: Transaction(
        id: transactionId, kind: kind, occurredAt: when, currency: .rub,
        amountE4: money(whole), amountRubE4: money(whole), paymentMethodId: account,
        createdAt: when, updatedAt: when),
      parts: [
        TransactionPart(
          id: id(2000 + number), transactionId: transactionId, categoryId: category,
          quality: kind == .expense ? .neutral : nil,
          qualitySource: kind == .expense ? .category : nil, amountE4: money(whole),
          amountRubE4: money(whole), refundOfPartId: refundOf)
      ])
  }

  var categories: [CoreKit.Category] {
    [
      CoreKit.Category(id: Self.groceries, kind: .expense, name: "Продукты"),
      CoreKit.Category(id: Self.cafe, kind: .expense, name: "Кафе"),
    ]
  }

  var dataset: Dataset {
    Dataset(
      entries: entries, categories: categories, paymentMethods: accounts,
      planning: PlanningBook(
        reconciliations: [
          Reconciliation(
            id: Self.id(21), date: Self.day("2026-09-10"), reconciledAt: Self.counted,
            actualTotalRubE4: .zero, kind: .opening)
        ], reconciledBalances: counts),
      transfers: transfers)
  }

  func snapshot() -> AccountsSnapshot {
    AccountsSnapshot.build(
      dataset: dataset, now: Self.now, calendar: .utc, rubPerUnit: [:], localeIdentifier: "ru")
  }

  var ledger: Ledger { Ledger(dataset: dataset, calendar: .utc) }
}

@Suite("Someone else's card in the books")
struct BorrowedCardBooksTests {
  private typealias B = BorrowedBook
  let papaKey = BalanceKey(accountId: B.papa, currency: .rub)
  let ownKey = BalanceKey(accountId: B.tbank, currency: .rub)

  @Test func theCardKeepsNoBalanceWhateverMovedOrWasCountedOnIt() {
    let snapshot = BorrowedBook().snapshot()
    #expect(snapshot.balances[papaKey] == nil)
    #expect(!snapshot.balances.keys.contains(papaKey))
    #expect(!snapshot.balances.hasHistory(papaKey))
    #expect(snapshot.balances[ownKey]?.amountE4 == B.money(100_000 - 1_500))
  }

  @Test func theSidebarListsTheCardWithNoMoneyNoTotalAndNothingUncounted() throws {
    let snapshot = BorrowedBook().snapshot()
    let line = try #require(snapshot.line(of: B.papa))
    #expect(line.keys.isEmpty)
    #expect(line.totalRub == nil)
    #expect(line.unknown == 0)
    #expect(!snapshot.unanchored.contains { $0.accountId == B.papa }, "never «не сверен»")
    #expect(snapshot.inSummaryTotalRub == B.money(98_500), "«Всего» is the owner's money only")
    #expect(snapshot.leftOut.contains(B.papa))
    #expect(!snapshot.isInSummary(B.papa))
    #expect(snapshot.isInSummary(B.tbank))
  }

  @Test func aCardNeverCountedIsNeverAskedForACount() {
    var book = BorrowedBook()
    book.counts.removeAll { $0.accountId == B.papa }
    let snapshot = book.snapshot()
    #expect(snapshot.unanchored.isEmpty)
    #expect(snapshot.line(of: B.papa)?.unknown == 0)
  }

  @Test func inAGroupTheCardAddsNothingToTheGroupsTotal() throws {
    var book = BorrowedBook()
    let group = AccountGroup(id: B.id(11), name: "Семья")
    book.accounts[1].groupId = group.id
    book.accounts.append(
      PaymentMethod(id: B.id(6), name: "Сбер", currency: .rub, groupId: group.id))
    book.counts.append(
      ReconciledBalance(
        id: B.id(33), reconciliationId: B.id(21), accountId: B.id(6), currency: .rub,
        actualE4: B.money(5_000)))
    let snapshot = AccountsSnapshot.build(
      dataset: Dataset(
        entries: book.entries, categories: book.categories, paymentMethods: book.accounts,
        planning: book.dataset.planning, accountGroups: [group]),
      now: B.now, calendar: .utc, rubPerUnit: [:], localeIdentifier: "ru")
    let section = try #require(snapshot.sections.first { $0.group?.id == group.id })
    #expect(section.totalRub == B.money(5_000))
    #expect(snapshot.inSummaryTotalRub == B.money(98_500 + 5_000))
  }

  @Test func theCapitalHasNoPlaceForTheCard() {
    let capital = CapitalFx.capital(BorrowedBook().dataset, today: B.day("2026-09-19"))
    #expect(capital.now.accountsRub == B.money(98_500), "the owner's money only")
    #expect(capital.now.outOfSummaryRub == .zero, "not even among the money apart")
    #expect(!capital.now.unanchored.contains { $0.accountId == B.papa })
  }

  @Test func theReconciliationSheetHasNoRowForTheCard() {
    let book = BorrowedBook()
    let snapshot = book.snapshot()
    let rows = AccountReconciliation.rows(
      accounts: book.accounts, groups: [], balances: snapshot.balances, at: B.now,
      locale: Locale(identifier: "ru"))
    #expect(!rows.contains { $0.key.accountId == B.papa })
    #expect(rows.contains { $0.key == ownKey })
  }

  @Test func spendingWithTheCardTakesNothingFromWhatCanBeSpent() {
    var book = BorrowedBook()
    func main(_ book: BorrowedBook) -> AmountE4? {
      FreeMoney(
        accounts: book.snapshot(), plan: CashPlan(), stillExpected: .zero,
        today: B.day("2026-09-19"), until: B.day("2026-09-30")
      ).main
    }
    let before = main(book)
    #expect(before == B.money(98_500))
    book.entries.append(
      BorrowedBook.expense(45, "2026-09-15", 20_000, account: B.papa, category: B.groceries))
    #expect(main(book) == before, "«Можно тратить» and the free sum stay")
  }

  /// A payment planned from someone else's card is paid with someone else's money: the grey
  /// line of the free sum does not take it.
  @Test func aPaymentPlannedFromTheCardTakesNothingFromTheFreeSum() {
    var fx = CashFx()
    let card = CashFx.id(9)
    fx.accounts.append(
      PaymentMethod(id: card, name: "Карта папы", currency: .rub, borrowed: BorrowedCardTerms()))
    fx.count([(CashFx.main, .rub, "100000")], at: CashFx.at("2026-09-01", 9))
    fx.scheduled = [
      CashFx.payment(1, "Phone", "700", day: 25, next: "2026-09-25", account: card),
      CashFx.payment(2, "Rent", "30000", day: 26, next: "2026-09-26", account: CashFx.main),
    ]
    #expect(fx.plan(until: "2026-09-30").scheduled == CashFx.money("30000"))
  }

  @Test func theCardsSpendingIsMySpendingInEveryTotalAndCategory() {
    let ledger = BorrowedBook().ledger
    let september = DayRange(B.day("2026-09-01"), B.day("2026-09-30"))
    #expect(ledger.expenses(in: september) == B.money(1_500 + 4_000 + 600))
    let entries = BorrowedBook().entries.filter {
      september.contains(CalendarContext.utc.day(of: $0.transaction.occurredAt))
    }
    let byCategory = MyExpensesRule.byCategory(entries: entries)
    #expect(byCategory.byCategory[B.groceries] == B.money(4_000))
    #expect(byCategory.byCategory[B.cafe] == B.money(2_100))
  }

  @Test func theScreenOfTheCardShowsWhatWasSpentThisMonth() {
    var book = BorrowedBook()
    let month = MonthKey(year: 2026, month: 9)
    #expect(
      BorrowedCardSpending.spent(ledger: book.ledger, accountId: B.papa, month: month)
        == B.money(4_600))
    #expect(
      BorrowedCardSpending.spent(ledger: book.ledger, accountId: B.papa, month: month.previous)
        == B.money(900))
    // A refund of a purchase made with the card takes its money back off the month.
    book.entries.append(
      BorrowedBook.expense(
        46, "2026-09-16", 1_000, account: B.papa, category: B.groceries, kind: .refund,
        refundOf: B.id(2042)))
    #expect(
      BorrowedCardSpending.spent(ledger: book.ledger, accountId: B.papa, month: month)
        == B.money(3_600))
  }

  @Test func theCutWithSomeoneElsesCardNamesEachCardAndItsOwner() {
    var book = BorrowedBook()
    book.accounts.append(
      PaymentMethod(id: B.id(7), name: "Корпоративная", borrowed: BorrowedCardTerms()))
    book.entries.append(
      BorrowedBook.expense(47, "2026-09-17", 9_000, account: B.id(7), category: B.cafe))
    let lines = BorrowedCardSpending.lines(
      ledger: book.ledger, accounts: book.accounts,
      in: DayRange(B.day("2026-09-01"), B.day("2026-09-30")))
    #expect(lines.map(\.account.id) == [B.id(7), B.papa], "the largest spending first")
    #expect(lines.map(\.spentRub) == [B.money(9_000), B.money(4_600)])
    #expect(lines.last?.personId == B.father)
    #expect(lines.first?.personId == nil)
  }

  @Test func moneyMovedFromTheCardStillArrivesOnTheOwnersAccount() {
    var book = BorrowedBook()
    book.transfers = [
      Transfer(
        id: B.id(51), occurredAt: B.noon("2026-09-15"), fromAccountId: B.papa,
        fromCurrency: .rub, fromAmountE4: B.money(3_000), toAccountId: B.tbank, toCurrency: .rub,
        toAmountE4: B.money(3_000))
    ]
    let snapshot = book.snapshot()
    #expect(snapshot.balances[ownKey]?.amountE4 == B.money(98_500 + 3_000))
    #expect(snapshot.balances[papaKey] == nil)
  }

  @Test func incomeWrittenFromTheCardIsIncomeOnTheOwnersAccount() throws {
    var book = BorrowedBook()
    let help = CoreKit.Category(id: B.id(8), kind: .income, name: "Помощь семьи")
    let transfer = Transfer(
      id: B.id(52), occurredAt: B.noon("2026-09-15"), fromAccountId: B.papa, fromCurrency: .rub,
      fromAmountE4: B.money(3_000), toAccountId: B.tbank, toCurrency: .rub,
      toAmountE4: B.money(3_000))
    let draft = BorrowedCardRules.incomeDraft(transfer: transfer, categoryId: help.id)
    let entry = try draft.materialize(
      now: B.now, timeZone: TimeZone(identifier: "UTC")!, rublesConverter: { $0 })
    book.entries.append(entry)
    let snapshot = book.snapshot()
    #expect(snapshot.balances[ownKey]?.amountE4 == B.money(98_500 + 3_000))
    let ledger = Ledger(
      dataset: Dataset(
        entries: book.entries, categories: book.categories + [help],
        paymentMethods: book.accounts),
      calendar: .utc)
    #expect(ledger.income(in: .month(MonthKey(year: 2026, month: 9))) == B.money(3_000))
  }
}
