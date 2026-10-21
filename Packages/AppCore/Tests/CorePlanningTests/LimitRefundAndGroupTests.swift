import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CorePlanning

/// What a limit counts beyond plain purchases: a refund lives in its purchase's month, even
/// when it comes a month later, and so moves what the month carries on; the spending of a
/// group left out of the summary is still spending; the category «Сверка» sees only what the
/// owner filed under it by hand.
@Suite("Limits with refunds, groups left out and «Сверка»")
struct LimitRefundAndGroupTests {
  typealias Fx = CashFx

  /// Groceries: 10 000 a month, carried over from August.
  static let groceries = Budget(
    id: CashFx.id(751), scope: .category, categoryId: CashFx.groceries,
    amountE4: CashFx.money("10000"), rollover: true, startMonth: MonthKey(year: 2026, month: 8))

  /// A refund of `amount` on `iso` of the only part of the operation `purchase`.
  static func refund(_ fx: inout CashFx, _ amount: String, on iso: String, of purchase: UUID) {
    guard let part = fx.entries.first(where: { $0.id == purchase })?.parts.first?.id else {
      Issue.record("no purchase to refund")
      return
    }
    let id = fx.add(.refund, amount, at: Fx.at(iso, 12))
    if let index = fx.entries.firstIndex(where: { $0.id == id }) {
      fx.entries[index].parts[0].refundOfPartId = part
      fx.entries[index].parts[0].quality = nil
      fx.entries[index].parts[0].qualitySource = nil
    }
  }

  /// August spent 6 000, so September has 14 000. A purchase of 12 000 on 10 September, 5 000
  /// of it refunded on 3 October: September spent 7 000 and hands on 7 000 — not 2 000 —, and
  /// October's own spending is untouched by the refund.
  @Test func aRefundNextMonthLivesInItsPurchasesMonth() {
    var fx = Fx()
    fx.add(.expense, "6000", at: Fx.at("2026-08-12", 12))
    let purchase = fx.add(.expense, "12000", at: Fx.at("2026-09-10", 12))
    Self.refund(&fx, "5000", on: "2026-10-03", of: purchase)
    let ledger = fx.ledger
    #expect(
      LimitRules.spent(of: Self.groceries, in: MonthKey(year: 2026, month: 9), ledger: ledger)
        == Fx.money("7000"))
    let october = LimitRules.line(
      budget: Self.groceries, ledger: ledger, today: Fx.day("2026-10-05"))
    #expect(october.carry == Fx.money("7000"))
    #expect(october.spent == .zero)
    #expect(october.available == Fx.money("17000"))
    #expect(october.status == .ok)
  }

  /// Seen from September before the refund came, the same purchase puts the limit on the edge:
  /// 12 000 of 14 000 spent and the pace of the weeks before takes the forecast past 14 000.
  /// The whole purchase refunded, September has spent nothing and is fine — a limit is about
  /// what the month's purchases cost in the end.
  @Test func aRefundTurnsItsMonthBack() {
    var fx = Fx()
    fx.add(.expense, "6000", at: Fx.at("2026-08-12", 12))
    let purchase = fx.add(.expense, "12000", at: Fx.at("2026-09-10", 12))
    #expect(
      LimitRules.line(budget: Self.groceries, ledger: fx.ledger, today: Fx.today).status
        == .warning)
    Self.refund(&fx, "12000", on: "2026-09-18", of: purchase)
    let line = LimitRules.line(budget: Self.groceries, ledger: fx.ledger, today: Fx.today)
    #expect(line.spent == .zero)
    #expect(line.status == .ok)
  }

  /// Groceries bought in Kazakhstan — 50 000 ₸, 10 000 ₽ — are spending like any other: the
  /// group is left out of the money, not out of the limits.
  @Test func spendingOfAGroupLeftOutCountsInALimit() {
    var fx = Fx()
    fx.add(
      .expense, "50000", at: Fx.at("2026-09-12", 12), currency: Fx.tenge, account: Fx.freedom)
    fx.add(.expense, "1000", at: Fx.at("2026-09-13", 12))
    let line = LimitRules.line(budget: Self.groceries, ledger: fx.ledger, today: Fx.today)
    #expect(line.spent == Fx.money("11000"))
  }

  /// A limit on «Сверка» itself: the differences reconciliations write stay out of it — 8 000
  /// missing is the books catching up — and only what the owner filed under «Сверка» by hand,
  /// 300, is spent. Such a limit is allowed, and nearly always empty.
  @Test func aLimitOnReconciliationSeesOnlyWhatWasFiledByHand() {
    let reconcile = LimitReconciliationDifferenceTests.reconcileExpense
    let budget = Budget(
      id: Fx.id(752), scope: .category, categoryId: reconcile, amountE4: Fx.money("5000"))
    let tree = CategoryTree(LimitReconciliationDifferenceTests.categories)
    #expect(LimitRules.validate(budget, tree: tree, existing: []) == nil)
    var fx = Fx()
    fx.add(
      .expense, "8000", at: Fx.at("2026-09-15", 20), category: reconcile,
      link: .reconciledBalance(reconciliation: Fx.id(990), balance: Fx.id(991)))
    fx.add(
      .expense, "2000", at: Fx.at("2026-09-16", 20), category: reconcile,
      link: .reconciliation(Fx.id(992)))
    fx.add(.expense, "300", at: Fx.at("2026-09-17", 20), category: reconcile)
    let base = fx.ledger.dataset
    let ledger = Ledger(
      dataset: Dataset(
        entries: base.entries, categories: LimitReconciliationDifferenceTests.categories,
        events: base.events, paymentMethods: base.paymentMethods, debts: base.debts,
        goals: base.goals, planning: base.planning, transfers: base.transfers,
        accountGroups: base.accountGroups),
      calendar: .utc)
    let line = LimitRules.line(budget: budget, ledger: ledger, today: Fx.today)
    #expect(line.spent == Fx.money("300"))
  }
}
