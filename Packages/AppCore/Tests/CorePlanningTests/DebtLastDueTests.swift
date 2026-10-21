import CoreAccounting
import CoreAnalytics
import CoreKit
import CorePlanning
import Foundation
import Testing

/// The last due of a loan is what is left of it. 12 000 borrowed at 8 000 a month on the 5th,
/// 8 000 paid on 5 September: on 1 October 4 000 are left. The planned month, «Платёж…», the
/// overdue list and the free sum all ask for those 4 000 — once, and nothing after.
@Suite("The last due of a debt is what is left of it")
struct DebtLastDueTests {
  typealias Fx = SchedFx

  let loans = Fx.id(13)
  let bankLoan = Fx.id(14)
  var debt: Debt {
    Debt(
      id: Fx.id(21), direction: .iOwe, type: .loan, name: "Loan",
      monthlyPaymentE4: Fx.money("8000"), paymentDay: 5, paymentsAreExpenses: true,
      origin: .existing, loansSubcategoryId: bankLoan)
  }

  var book: PlanningBook {
    var book = PlanningBook.empty
    book.debtEntries = [
      DebtEntry(
        id: Fx.id(50), debtId: debt.id, date: Fx.day("2026-08-20"),
        amountE4: Fx.money("12000"), kind: .borrowed),
      DebtEntry(
        id: Fx.id(51), debtId: debt.id, date: Fx.day("2026-09-05"),
        amountE4: Fx.money("-8000"), kind: .payment),
    ]
    return book
  }

  var ledger: Ledger {
    Ledger(
      dataset: Dataset(
        categories: [
          CoreKit.Category(id: loans, kind: .expense, name: "Loans", systemRole: .loans),
          CoreKit.Category(id: bankLoan, parentId: loans, kind: .expense, name: "Bank loan"),
        ], debts: [debt], planning: book),
      calendar: .utc)
  }

  /// Through the end of November the planned payments hold one due of 4 000, not 8 000 in
  /// October and 8 000 more in November.
  @Test func thePlannedMonthsAskForWhatIsLeft() {
    let planned = PlannedMonth.build(
      ledger: ledger, book: book, today: Fx.day("2026-10-01"), until: Fx.day("2026-11-30"))
    let debts = planned.items.filter { $0.kind == .debt }
    #expect(debts.map(\.due) == [Fx.day("2026-10-05")])
    #expect(debts.map(\.amount) == [Fx.money("4000")])
    #expect(planned.debts == Fx.money("4000"))
  }

  /// «Платёж…» starts with what is left, and the overdue list names one due of 4 000.
  @Test func thePaymentAndTheOverdueListTakeWhatIsLeft() throws {
    let today = Fx.day("2026-12-10")
    let overview = DebtsOverview.build(ledger: ledger, book: book, today: today, rubPerUnit: [:])
    let line = try #require(overview.iOwe.first)
    #expect(DebtTerms.amountToPay(debt, dues: line.dues) == Fx.money("4000"))
    let overdue = OverdueDues.build(
      ledger: ledger, book: book, matches: .empty, debts: overview, accounts: .empty,
      today: today)
    #expect(overdue.map(\.amount) == [Fx.money("4000")])
    #expect(overdue.map(\.moreOverdue) == [0], "one due is owed, not three")
  }

  /// Paying what is left of the debt pays it off: there is no month after it for «в этом месяце
  /// больше платежей не будет» to speak of, so the panel does not offer it; less than that, it
  /// does.
  @Test func payingOffTheDebtIsNoPaymentToCloseATermWith() throws {
    let today = Fx.day("2026-10-03")
    let overview = DebtsOverview.build(ledger: ledger, book: book, today: today, rubPerUnit: [:])
    let line = try #require(overview.iOwe.first)
    #expect(!DebtTerms.offersClosing(debt, paying: Fx.money("4000"), dues: line.dues))
    #expect(DebtTerms.offersClosing(debt, paying: Fx.money("3000"), dues: line.dues))
  }

  /// Seeded: whatever was borrowed and paid, the planned months, «Платёж…» and the overdue list
  /// never ask more than is left on the debt, and never a due of nothing.
  @Test(arguments: 0..<150)
  func nothingAsksMoreThanTheDebt(seed: Int) throws {
    var state = UInt64(seed) &* 0x9E37_79B9_7F4A_7C15 &+ 17
    func next(_ bound: Int) -> Int {
      state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      return Int((state >> 33) % UInt64(bound))
    }
    var book = PlanningBook.empty
    book.debtEntries = [
      DebtEntry(
        id: Fx.id(50), debtId: debt.id, date: Fx.day("2026-03-20"),
        amountE4: AmountE4(whole: Int64(1 + next(60)) * 1_000), kind: .borrowed)
    ]
    var day = Fx.day("2026-03-21")
    for index in 0..<next(9) {
      day = day.adding(days: next(40))
      let amount = [8_000, 4_000, 7_950, 12_000, 500, 16_000][next(6)]
      book.debtEntries.append(
        DebtEntry(
          id: Fx.id(60 + index), debtId: debt.id, date: day,
          amountE4: -AmountE4(whole: Int64(amount)), kind: .payment, closesTerm: next(4) == 0))
    }
    let today = day.adding(days: next(120))
    let ledger = Ledger(
      dataset: Dataset(
        categories: [
          CoreKit.Category(id: loans, kind: .expense, name: "Loans", systemRole: .loans),
          CoreKit.Category(id: bankLoan, parentId: loans, kind: .expense, name: "Bank loan"),
        ], debts: [debt], planning: book),
      calendar: .utc)
    let left = DebtRules.balance(entries: book.debtEntries)
    let overview = DebtsOverview.build(ledger: ledger, book: book, today: today, rubPerUnit: [:])
    guard let line = overview.iOwe.first, left.raw > 0 else { return }

    let planned = PlannedMonth.build(
      ledger: ledger, book: book, today: today, until: today.adding(months: 4))
    let items = planned.items.filter { $0.kind == .debt }
    #expect(
      AmountE4.sum(items.map(\.amount)) + planned.debtsDueByToday <= left,
      "seed \(seed): planned \(items.map(\.amount)) over \(left)")
    #expect(items.allSatisfy { $0.amount.raw > 0 }, "seed \(seed): a due of nothing")
    #expect(DebtTerms.amountToPay(debt, dues: line.dues) <= left, "seed \(seed)")
    let overdue = OverdueDues.build(
      ledger: ledger, book: book, matches: .empty, debts: overview, accounts: .empty,
      today: today)
    if let first = overdue.first {
      let owedEach = line.dues.overdue(today: today).map {
        line.dues.owed($0, monthly: Fx.money("8000"))
      }
      #expect(first.moreOverdue + 1 == owedEach.count, "seed \(seed)")
      #expect(AmountE4.sum(owedEach) <= left, "seed \(seed): overdue over the balance")
      #expect(owedEach.allSatisfy { $0.raw > 0 }, "seed \(seed): an overdue due of nothing")
    }
  }
}
