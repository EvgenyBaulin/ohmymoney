import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CorePlanning

@Suite("Reconciliation by account and currency")
struct AccountReconciliationTests {
  typealias Fx = CashFx

  func balances(_ fx: CashFx, now: Date = CashFx.now) -> AccountBalances {
    let dataset = fx.ledger.dataset
    return AccountBalances.build(
      entries: dataset.entries, transfers: dataset.transfers,
      debtEntries: dataset.planning.debtEntries, debts: dataset.debtsById,
      reconciliations: dataset.planning.reconciliations,
      balances: dataset.planning.reconciledBalances, accounts: dataset.paymentMethods,
      tree: CategoryTree(dataset.categories), now: now, calendar: .utc)
  }

  /// A sequence of ids, the same on every run.
  final class Ids {
    private var next = 7000
    func make() -> UUID {
      next += 1
      return CashFx.id(next)
    }
  }

  // MARK: - The rows

  /// Every live account and each of its currencies, main first, Kazakhstan included; money in a
  /// currency the card does not hold right after the card's own rows; an archived account with
  /// money last. Expected is the balance now; never counted — a starting point. Euros spent
  /// from the card and never counted have no known balance and no row.
  @Test func theRowsOfTheSheet() {
    var fx = Fx()
    fx.accounts.append(PaymentMethod(id: Fx.id(4), name: "Old", currency: .rub, archived: true))
    fx.count(
      [
        (Fx.main, .rub, "100000"), (Fx.card, .usd, "50"), (Fx.card, .eur, "30"),
        (Fx.id(4), .rub, "300"),
      ],
      at: Fx.at("2026-09-10", 14))
    fx.add(.expense, "1500", at: Fx.at("2026-09-12", 12))
    // Euros paid from the card, which does not hold them; francs never counted.
    fx.add(.expense, "20", at: Fx.at("2026-09-13", 12), currency: .eur, account: Fx.card)
    fx.add(
      .expense, "5", at: Fx.at("2026-09-13", 12), currency: CurrencyCode("CHF"), account: Fx.card)
    let rows = AccountReconciliation.rows(
      accounts: fx.accounts, groups: fx.groups, balances: balances(fx), at: Fx.now,
      locale: Locale(identifier: "en"))
    #expect(
      rows.map(\.key) == [
        BalanceKey(accountId: Fx.main, currency: .rub),
        BalanceKey(accountId: Fx.card, currency: .rub),
        BalanceKey(accountId: Fx.card, currency: .usd),
        BalanceKey(accountId: Fx.card, currency: .eur),
        BalanceKey(accountId: Fx.freedom, currency: Fx.tenge),
        BalanceKey(accountId: Fx.id(4), currency: .rub),
      ])
    #expect(
      rows.map(\.expected) == [
        Fx.money("98500"), nil, Fx.money("50"), Fx.money("10"), nil, Fx.money("300"),
      ])
    #expect(rows.map(\.isHeld) == [true, true, true, false, true, false])
    #expect(rows[0].lastCountedAt == Fx.at("2026-09-10", 14))
    #expect(rows[1].lastCountedAt == nil)
  }

  // MARK: - Recording

  /// Main expected 98 500 and counted 98 000: a difference of −500, written as an expense in
  /// «Сверка» on Main. The card's dollars are unchanged: counted again, no operation. Its
  /// rubles were never counted: a starting point. Freedom was left empty: nothing written.
  /// Right after it the money now is exactly the count.
  @Test func recordingTheSheet() {
    var fx = Fx()
    fx.count([(Fx.main, .rub, "100000"), (Fx.card, .usd, "50")], at: Fx.at("2026-09-10", 14))
    fx.add(.expense, "1500", at: Fx.at("2026-09-12", 12))
    let t0 = Fx.at("2026-09-19", 14, 5)
    let rows = AccountReconciliation.rows(
      accounts: fx.accounts, groups: fx.groups, balances: balances(fx), at: t0,
      locale: Locale(identifier: "en"))
    let reconcileExpense = Fx.id(801)
    let reconcileIncome = Fx.id(802)
    let ids = Ids()
    let record = AccountReconciliation.record(
      counted: [
        BalanceKey(accountId: Fx.main, currency: .rub): Fx.money("98000"),
        BalanceKey(accountId: Fx.card, currency: .usd): Fx.money("50"),
        BalanceKey(accountId: Fx.card, currency: .rub): Fx.money("7000"),
      ],
      rows: rows, writeDifference: true, kind: .accounts, at: t0, calendar: .utc,
      tree: CategoryTree(Fx.categories), categories: (reconcileExpense, reconcileIncome),
      rubPerUnit: fx.rubPerUnit, makeId: ids.make)

    let reconciliation = record.reconciliation
    #expect(reconciliation.kind == .accounts)
    #expect(reconciliation.reconciledAt == t0)
    #expect(reconciliation.date == Fx.day("2026-09-19"))
    #expect(reconciliation.actualTotalRubE4 == Fx.money("109500"))
    #expect(reconciliation.expectedTotalRubE4 == Fx.money("103000"))
    #expect(reconciliation.differenceE4 == nil)

    #expect(
      record.balances.map(\.key) == [
        BalanceKey(accountId: Fx.main, currency: .rub),
        BalanceKey(accountId: Fx.card, currency: .rub),
        BalanceKey(accountId: Fx.card, currency: .usd),
      ])
    #expect(record.balances.map(\.expectedE4) == [Fx.money("98500"), nil, Fx.money("50")])
    #expect(record.balances.map(\.differenceE4) == [Fx.money("-500"), nil, .zero])
    #expect(record.balances.allSatisfy { $0.reconciliationId == reconciliation.id })

    #expect(record.differences.count == 1)
    let difference = record.differences[0]
    #expect(difference.transaction.kind == .expense)
    #expect(difference.transaction.amountE4 == Fx.money("500"))
    #expect(difference.transaction.currency == .rub)
    #expect(difference.transaction.paymentMethodId == Fx.main)
    #expect(difference.transaction.occurredAt == t0)
    #expect(difference.parts.map(\.categoryId) == [reconcileExpense])
    #expect(record.balances[0].transactionId == difference.id)
    #expect(
      difference.transaction.externalId
        == OperationLink.reconciledBalance(
          reconciliation: reconciliation.id, balance: record.balances[0].id
        ).externalId)
    #expect(record.withoutRate.isEmpty)

    // Written, the count is the money now: the difference moves nothing.
    fx.reconciliations.append(reconciliation)
    fx.counts += record.balances
    fx.entries += record.differences
    let after = AccountsSnapshot.build(
      dataset: fx.ledger.dataset, now: Fx.at("2026-09-19", 14, 6), calendar: .utc,
      rubPerUnit: fx.rubPerUnit, localeIdentifier: "en")
    #expect(after.inSummaryTotalRub == Fx.money("109500"))
  }

  /// More money than expected is income in the twin; «Сохранить только» writes no operation;
  /// a foreign difference without a rate is counted and listed, not written.
  @Test func incomeSaveOnlyAndNoRate() {
    var fx = Fx()
    fx.accounts[1].otherCurrencies = [.usd, .eur]
    fx.count([(Fx.main, .rub, "1000"), (Fx.card, .eur, "10")], at: Fx.at("2026-09-10", 14))
    let t0 = Fx.at("2026-09-19", 14)
    let rows = AccountReconciliation.rows(
      accounts: fx.accounts, groups: fx.groups, balances: balances(fx), at: t0,
      locale: Locale(identifier: "en"))
    let counted = [
      BalanceKey(accountId: Fx.main, currency: .rub): Fx.money("1200"),
      BalanceKey(accountId: Fx.card, currency: .eur): Fx.money("12"),
    ]
    func record(_ write: Bool) -> AccountReconciliationRecord {
      AccountReconciliation.record(
        counted: counted, rows: rows, writeDifference: write, kind: .accounts, at: t0,
        calendar: .utc, tree: CategoryTree(Fx.categories), categories: (Fx.id(801), Fx.id(802)),
        rubPerUnit: fx.rubPerUnit, makeId: Ids().make)
    }
    let written = record(true)
    #expect(written.differences.map(\.transaction.kind) == [.income])
    #expect(written.differences.first?.parts.map(\.categoryId) == [Fx.id(802)])
    #expect(written.withoutRate == [BalanceKey(accountId: Fx.card, currency: .eur)])
    #expect(written.balances.map(\.differenceE4) == [Fx.money("200"), Fx.money("2")])

    let saved = record(false)
    #expect(saved.differences.isEmpty)
    #expect(saved.balances.allSatisfy { $0.transactionId == nil })
  }

  // MARK: - How a count keeps its difference

  /// Main expected 98 500, the card's dollars 50; its rubles never counted.
  func sheet() -> (fx: CashFx, rows: [ReconcileRow], t0: Date) {
    var fx = Fx()
    fx.count([(Fx.main, .rub, "100000"), (Fx.card, .usd, "50")], at: Fx.at("2026-09-10", 14))
    fx.add(.expense, "1500", at: Fx.at("2026-09-12", 12))
    let t0 = Fx.at("2026-09-19", 14, 5)
    let rows = AccountReconciliation.rows(
      accounts: fx.accounts, groups: fx.groups, balances: balances(fx), at: t0,
      locale: Locale(identifier: "en"))
    return (fx, rows, t0)
  }

  func record(
    _ counted: [BalanceKey: AmountE4], write: Bool, startingPoints: Set<BalanceKey> = []
  ) -> AccountReconciliationRecord {
    let (fx, rows, t0) = sheet()
    return AccountReconciliation.record(
      counted: counted, rows: rows, writeDifference: write, kind: .accounts, at: t0,
      calendar: .utc, tree: CategoryTree(Fx.categories), categories: (Fx.id(801), Fx.id(802)),
      rubPerUnit: fx.rubPerUnit, makeId: Ids().make, startingPoints: startingPoints)
  }

  let mainRub = BalanceKey(accountId: CashFx.main, currency: .rub)
  let cardUsd = BalanceKey(accountId: CashFx.card, currency: .usd)
  let cardRub = BalanceKey(accountId: CashFx.card, currency: .rub)

  /// Nothing differs: there was nothing to decline, so every compared count records — its
  /// difference follows the books from now on. A starting point keeps nothing.
  @Test func aSaveWithNothingDifferentRecords() {
    let counted = [mainRub: Fx.money("98500"), cardUsd: Fx.money("50"), cardRub: Fx.money("10")]
    for write in [false, true] {
      let saved = record(counted, write: write)
      #expect(saved.balances.map(\.key) == [mainRub, cardRub, cardUsd])
      #expect(saved.balances.map(\.recordsDifference) == [true, nil, true])
      #expect(saved.differences.isEmpty)
    }
  }

  /// «Сохранить без записи» with a difference keeps: no operation, and every compared count of
  /// the sheet — the one at zero too — only follows the numbers. «Записать разницу» records
  /// every compared count, the one at zero included.
  @Test func saveWithoutRecordingKeeps() {
    let counted = [mainRub: Fx.money("98000"), cardUsd: Fx.money("50"), cardRub: Fx.money("10")]
    let kept = record(counted, write: false)
    #expect(kept.balances.map(\.recordsDifference) == [false, nil, false])
    #expect(kept.differences.isEmpty)
    #expect(kept.balances.allSatisfy { $0.transactionId == nil })
    let recorded = record(counted, write: true)
    #expect(recorded.balances.map(\.recordsDifference) == [true, nil, true])
    #expect(recorded.differences.count == 1)
  }

  /// A key the owner makes a starting point is written like a first count — no expected
  /// balance, no difference, nothing to keep and no operation — whatever the books expected.
  @Test func startingPointsWriteNoDifference() {
    let counted = [mainRub: Fx.money("98000"), cardUsd: Fx.money("52")]
    let saved = record(counted, write: true, startingPoints: [mainRub])
    #expect(saved.balances.map(\.key) == [mainRub, cardUsd])
    #expect(saved.balances[0].expectedE4 == nil)
    #expect(saved.balances[0].differenceE4 == nil)
    #expect(saved.balances[0].recordsDifference == nil)
    #expect(saved.balances[0].transactionId == nil)
    #expect(saved.balances[0].actualE4 == Fx.money("98000"))
    // The dollars still compare: 2 more than expected, recorded.
    #expect(saved.balances[1].differenceE4 == Fx.money("2"))
    #expect(saved.balances[1].recordsDifference == true)
    #expect(saved.differences.map(\.transaction.paymentMethodId) == [Fx.card])
    // Only compared rows give the expected rubles: the dollars at their rate.
    #expect(saved.reconciliation.expectedTotalRubE4 != nil)
    // A starting point that differs does not make the others keep.
    let alone = record(
      [mainRub: Fx.money("98000"), cardUsd: Fx.money("50")], write: false,
      startingPoints: [mainRub])
    #expect(alone.balances.map(\.recordsDifference) == [nil, true])
  }

  /// The operation of a difference and its one part take the ids derived from the count, so
  /// the count and its operation always name each other, whenever it is written again.
  @Test func aNewDifferenceOperationHasTheDerivedIds() throws {
    let saved = record([mainRub: Fx.money("98000")], write: true)
    let count = try #require(saved.balances.first)
    let operation = try #require(saved.differences.first)
    #expect(operation.id == ReconcileDifferenceIds.operation(forCount: count.id))
    #expect(operation.parts.map(\.id) == [ReconcileDifferenceIds.part(forCount: count.id)])
    #expect(operation.parts.allSatisfy { $0.transactionId == operation.id })
    #expect(count.transactionId == operation.id)
    #expect(operation.isBalanced)
  }

  // MARK: - Before the count

  /// Counted today at 14:05. Saved at 15:00 and dated today, an operation asks; «Да» stamps
  /// 14:04:59. Saved before the count, or dated another day, it does not. Yesterday's count
  /// at 14:05 asks about «такси 500 вчера» typed today, and «Нет» puts it after 14:05.
  @Test func beforeTheCount() {
    var fx = Fx()
    let count = Fx.at("2026-09-19", 14, 5)
    fx.count([(Fx.main, .rub, "1000")], at: count)
    let keys = [BalanceKey(accountId: Fx.main, currency: .rub)]
    let today = balances(fx)
    let asked = AccountReconciliation.beforeTheCount(
      occurredAt: Fx.at("2026-09-19", 9), savedAt: Fx.at("2026-09-19", 15), keys: keys,
      balances: today, calendar: .utc)
    #expect(asked == count)
    #expect(
      AccountReconciliation.stamped(
        occurredAt: Fx.at("2026-09-19", 9), count: count, wasBefore: true)
        == Fx.at("2026-09-19", 14, 4).addingTimeInterval(59))
    #expect(
      AccountReconciliation.beforeTheCount(
        occurredAt: Fx.at("2026-09-19", 9), savedAt: Fx.at("2026-09-19", 13), keys: keys,
        balances: today, calendar: .utc) == nil)
    #expect(
      AccountReconciliation.beforeTheCount(
        occurredAt: Fx.at("2026-09-18", 12), savedAt: Fx.at("2026-09-19", 15), keys: keys,
        balances: today, calendar: .utc) == nil)
    #expect(
      AccountReconciliation.beforeTheCount(
        occurredAt: Fx.at("2026-09-19", 9), savedAt: Fx.at("2026-09-19", 15),
        keys: [BalanceKey(accountId: Fx.card, currency: .rub)], balances: today,
        calendar: .utc) == nil)

    var yesterday = Fx()
    let counted = Fx.at("2026-09-18", 14, 5)
    yesterday.count([(Fx.main, .rub, "1000")], at: counted)
    let noon = CalendarContext.utc.noon(of: Fx.day("2026-09-18"))
    #expect(
      AccountReconciliation.beforeTheCount(
        occurredAt: noon, savedAt: Fx.at("2026-09-19", 10), keys: keys,
        balances: balances(yesterday), calendar: .utc) == counted)
    #expect(
      AccountReconciliation.stamped(occurredAt: noon, count: counted, wasBefore: false)
        == counted.addingTimeInterval(1))
    // A time later than the count stays as it was.
    #expect(
      AccountReconciliation.stamped(
        occurredAt: Fx.at("2026-09-18", 20), count: counted, wasBefore: false)
        == Fx.at("2026-09-18", 20))
  }

  /// A transfer moves two balances; an operation the one of its account, the main one when it
  /// names none; money put into a goal moves none.
  @Test func theBalancesAMovementAsksAbout() {
    var fx = Fx()
    fx.add(.expense, "100", at: Fx.at("2026-09-19", 9), account: nil)
    fx.add(.expense, "100", at: Fx.at("2026-09-19", 9), category: Fx.tripGoal, goal: Fx.id(401))
    let tree = CategoryTree(Fx.categories)
    #expect(
      AccountReconciliation.movedKeys(of: fx.entries[0], mainId: Fx.main, tree: tree)
        == [BalanceKey(accountId: Fx.main, currency: .rub)])
    #expect(AccountReconciliation.movedKeys(of: fx.entries[1], mainId: Fx.main, tree: tree) == [])
    let transfer = Transfer(
      occurredAt: Fx.now, fromAccountId: Fx.main, fromCurrency: .rub,
      fromAmountE4: Fx.money("9000"), toAccountId: Fx.card, toCurrency: .usd,
      toAmountE4: Fx.money("100"))
    #expect(
      AccountReconciliation.movedKeys(of: transfer) == [
        BalanceKey(accountId: Fx.main, currency: .rub),
        BalanceKey(accountId: Fx.card, currency: .usd),
      ])
  }

  // MARK: - The reminder

  /// The reminder counts from the latest sheet of every account (or of one total, as before
  /// accounts); a later opening — a new account's balance — never puts it off. With only
  /// openings, the first one — the setup of the accounts — stands in.
  @Test func aNewAccountsOpeningDoesNotPutTheReminderOff() {
    var fx = Fx()
    fx.count([(Fx.main, .rub, "1000")], at: Fx.at("2026-08-20", 9), kind: .opening)
    fx.count([(Fx.main, .rub, "1000")], at: Fx.at("2026-09-01", 9))
    fx.count([(Fx.card, .rub, "500")], at: Fx.at("2026-09-18", 9), kind: .opening)
    let book = fx.book
    #expect(AccountReconciliation.reminderAnchor(book: book)?.date == Fx.day("2026-09-01"))
    #expect(AccountReconciliation.isDue(book: book, today: Fx.today, everyDays: 14))
    #expect(!AccountReconciliation.isDue(book: book, today: Fx.day("2026-09-15"), everyDays: 14))

    var openings = Fx()
    openings.count([(Fx.main, .rub, "1000")], at: Fx.at("2026-09-10", 9), kind: .opening)
    openings.count([(Fx.card, .rub, "500")], at: Fx.at("2026-09-18", 9), kind: .opening)
    #expect(
      AccountReconciliation.reminderAnchor(book: openings.book)?.date == Fx.day("2026-09-10"))
    #expect(
      AccountReconciliation.isDue(book: openings.book, today: Fx.day("2026-09-25"), everyDays: 14))

    let legacy = PlanningBook(
      reconciliations: [
        Reconciliation(date: Fx.day("2026-09-12"), actualTotalRubE4: Fx.money("5000"))
      ])
    #expect(!AccountReconciliation.isDue(book: legacy, today: Fx.today, everyDays: 14))
    #expect(AccountReconciliation.isDue(book: PlanningBook(), today: Fx.today, everyDays: 14))

    // The snapshot and the reminders follow the same rule.
    let snapshot = fx.snapshot()
    #expect(snapshot.lastReconciliation?.date == Fx.day("2026-09-01"))
    #expect(snapshot.reconciliationDue)
    #expect(snapshot.reminders.contains { $0.id == "reconcile:2026-09-01" })
  }

  /// A 1.0 total of 1 September, then the setup of the accounts on the 19th: that setup counts
  /// every account, so the reminder counts from it and is not due the day it was made. A
  /// later opening of one new account still puts nothing off.
  @Test func theSetupAfterAnOldTotalStartsTheRhythm() {
    var fx = Fx()
    fx.reconciliations.append(
      Reconciliation(
        id: Fx.id(900), date: Fx.day("2026-09-01"), reconciledAt: Fx.at("2026-09-01", 9),
        actualTotalRubE4: Fx.money("5000"), kind: .total))
    fx.count(
      [(Fx.main, .rub, "1000"), (Fx.card, .rub, "500")], at: Fx.at("2026-09-19", 10), kind: .opening
    )
    fx.count([(Fx.freedom, Fx.tenge, "900")], at: Fx.at("2026-09-25", 10), kind: .opening)
    let book = fx.book
    #expect(AccountReconciliation.reminderAnchor(book: book)?.date == Fx.day("2026-09-19"))
    #expect(!AccountReconciliation.isDue(book: book, today: Fx.today, everyDays: 14))
    #expect(!AccountReconciliation.isDue(book: book, today: Fx.day("2026-10-03"), everyDays: 14))
    #expect(AccountReconciliation.isDue(book: book, today: Fx.day("2026-10-04"), everyDays: 14))
  }

  /// Money borrowed or lent through the journal alone moves the line's account, in what moved
  /// on it; a payment line or a line with its own operation moves nothing here.
  @Test func theBalancesADebtLineAsksAbout() {
    let lent = Debt(id: Fx.id(310), direction: .owedToMe, type: .personal, name: "Lent")
    let borrowed = DebtEntry(
      debtId: lent.id, date: Fx.today, amountE4: Fx.money("-100"), kind: .borrowed,
      paymentMethodId: Fx.card, occurredAt: Fx.now, accountCurrency: .usd,
      accountAmountE4: Fx.money("100"))
    #expect(
      AccountReconciliation.movedKeys(of: borrowed, debt: lent, mainId: Fx.main, calendar: .utc)
        == [BalanceKey(accountId: Fx.card, currency: .usd)])
    var noAccount = borrowed
    noAccount.paymentMethodId = nil
    noAccount.accountCurrency = nil
    #expect(
      AccountReconciliation.movedKeys(of: noAccount, debt: lent, mainId: Fx.main, calendar: .utc)
        == [BalanceKey(accountId: Fx.main, currency: .rub)])
    var payment = borrowed
    payment.kind = .payment
    #expect(
      AccountReconciliation.movedKeys(of: payment, debt: lent, mainId: Fx.main, calendar: .utc)
        .isEmpty)
    var withOperation = borrowed
    withOperation.transactionId = Fx.id(311)
    #expect(
      AccountReconciliation.movedKeys(
        of: withOperation, debt: lent, mainId: Fx.main, calendar: .utc
      ).isEmpty)
  }

  /// Rows of a group left out of the summary say so; the ruble totals of the reconciliation
  /// name the currencies they could not count for want of a rate.
  @Test func rowsOutOfTheSummaryAndTotalsWithoutARate() {
    var fx = Fx()
    fx.accounts[1].otherCurrencies = [.usd, .eur]
    let t0 = Fx.at("2026-09-19", 14)
    let rows = AccountReconciliation.rows(
      accounts: fx.accounts, groups: fx.groups, balances: balances(fx), at: t0,
      locale: Locale(identifier: "en"))
    #expect(rows.filter { !$0.isInSummary }.map(\.key.accountId) == [Fx.freedom])
    let record = AccountReconciliation.record(
      counted: [
        BalanceKey(accountId: Fx.main, currency: .rub): Fx.money("1000"),
        BalanceKey(accountId: Fx.card, currency: .eur): Fx.money("10"),
      ],
      rows: rows, writeDifference: true, kind: .accounts, at: t0, calendar: .utc,
      tree: CategoryTree(Fx.categories), categories: (Fx.id(801), Fx.id(802)),
      rubPerUnit: fx.rubPerUnit, makeId: Ids().make)
    #expect(record.reconciliation.actualTotalRubE4 == Fx.money("1000"))
    #expect(record.totalsWithoutRate == [.eur])
  }
}
