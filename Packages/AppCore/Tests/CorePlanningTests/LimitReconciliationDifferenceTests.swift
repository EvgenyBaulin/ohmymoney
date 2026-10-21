import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CorePlanning

/// The difference a reconciliation writes is the books catching up with the money, not
/// spending a limit is about — whether it was written by the sheet of one total, as before
/// accounts, or by the sheet of every account and currency.
@Suite("Limits leave out the differences of reconciliations")
struct LimitReconciliationDifferenceTests {
  typealias Fx = CashFx

  static let reconcileExpense = CashFx.id(27)
  static let reconcileIncome = CashFx.id(28)
  static let categories =
    CashFx.categories + [
      CoreKit.Category(
        id: reconcileExpense, kind: .expense, name: "Сверка", quality: .neutral),
      CoreKit.Category(id: reconcileIncome, kind: .income, name: "Сверка"),
    ]

  /// A limit «для меня» of 10 000, one for bad spending of 1 000 and one on Groceries of
  /// 6 000.
  static let budgets = [
    Budget(id: CashFx.id(731), scope: .forWhom, forWhom: .me, amountE4: CashFx.money("10000")),
    Budget(id: CashFx.id(732), scope: .badTotal, amountE4: CashFx.money("1000")),
    Budget(
      id: CashFx.id(733), scope: .category, categoryId: CashFx.groceries,
      amountE4: CashFx.money("6000")),
  ]

  func ledger(_ fx: CashFx) -> Ledger {
    var book = fx.book
    book.budgets = Self.budgets
    let base = fx.ledger.dataset
    return Ledger(
      dataset: Dataset(
        entries: base.entries, categories: Self.categories, events: base.events,
        paymentMethods: base.paymentMethods, debts: base.debts, goals: base.goals,
        planning: book, transfers: base.transfers, accountGroups: base.accountGroups),
      calendar: .utc)
  }

  /// 5 000 of groceries this month; the sheet of 15 September finds 8 000 missing on the main
  /// account and writes the difference. The limits still see 5 000 — as they did with the
  /// difference of a total — and none of them goes over.
  @Test func aDifferenceOfTheSheetOfAccountsIsNoSpendingOfALimit() {
    var fx = Fx()
    fx.count([(Fx.main, .rub, "20000")], at: Fx.at("2026-09-01", 9))
    fx.add(.expense, "5000", at: Fx.at("2026-09-05", 12))
    let t0 = Fx.at("2026-09-15", 20)
    let balances = ReconciliationPropertyTests.Scenario.balances(fx, now: t0)
    let rows = AccountReconciliation.rows(
      accounts: fx.accounts, groups: fx.groups, balances: balances, at: t0,
      locale: Locale(identifier: "en"))
    var next = 7_500
    let record = AccountReconciliation.record(
      counted: [BalanceKey(accountId: Fx.main, currency: .rub): Fx.money("7000")], rows: rows,
      writeDifference: true, kind: .accounts, at: t0, calendar: .utc,
      tree: CategoryTree(Self.categories),
      categories: (Self.reconcileExpense, Self.reconcileIncome), rubPerUnit: fx.rubPerUnit,
      makeId: {
        next += 1
        return Fx.id(next)
      })
    #expect(record.differences.map(\.transaction.amountE4) == [Fx.money("8000")])
    fx.reconciliations.append(record.reconciliation)
    fx.counts += record.balances
    fx.entries += record.differences

    let ledger = ledger(fx)
    let lines = LimitRules.lines(book: ledger.dataset.planning, ledger: ledger, today: Fx.today)
    #expect(lines.map(\.spent) == [Fx.money("5000"), .zero, Fx.money("5000")])
    #expect(lines.map(\.status) == [.ok, .ok, .warning])
  }

  /// The same with the difference of a total, as 1.0 wrote it: left out as before.
  @Test func aDifferenceOfATotalIsNoSpendingOfALimitEither() {
    var fx = Fx()
    fx.add(.expense, "5000", at: Fx.at("2026-09-05", 12))
    fx.add(
      .expense, "8000", at: Fx.at("2026-09-15", 20), category: Self.reconcileExpense,
      link: .reconciliation(Fx.id(990)))
    let ledger = ledger(fx)
    let lines = LimitRules.lines(book: ledger.dataset.planning, ledger: ledger, today: Fx.today)
    #expect(lines.first?.spent == Fx.money("5000"))
  }

  /// A shortfall of money back is money the owner is out of pocket: a limit counts it.
  @Test func aShortfallIsSpendingOfALimit() {
    var fx = Fx()
    fx.add(.expense, "5000", at: Fx.at("2026-09-05", 12))
    fx.add(
      .expense, "700", at: Fx.at("2026-09-15", 20),
      link: .shortfall(reimbursement: "r", part: "p"))
    let ledger = ledger(fx)
    let lines = LimitRules.lines(book: ledger.dataset.planning, ledger: ledger, today: Fx.today)
    #expect(lines.first?.spent == Fx.money("5700"))
  }
}
