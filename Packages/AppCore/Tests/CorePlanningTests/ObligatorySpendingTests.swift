import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CorePlanning

/// What a month without income would cost: scheduled payments as paid, the dues of the debts
/// with a schedule, the essential categories — each row once —, the median of the last full
/// months and the floor of what is committed today.
@Suite("Obligatory spending of the safety cushion")
struct ObligatorySpendingTests {
  typealias Fx = CapitalFx

  let today = Fx.day("2026-10-11")
  // Categories.
  let food = Fx.id(10)
  let groceries = Fx.id(11)
  let cafe = Fx.id(12)
  let fun = Fx.id(13)
  let loans = Fx.id(14)
  // Records.
  let rent = Fx.id(20)
  let loan = Fx.id(21)
  let credit = Fx.id(22)

  var categories: [CoreKit.Category] {
    [
      CoreKit.Category(id: food, kind: .expense, name: "Food", essential: true),
      CoreKit.Category(id: groceries, parentId: food, kind: .expense, name: "Groceries"),
      CoreKit.Category(id: cafe, parentId: food, kind: .expense, name: "Cafe", essential: false),
      CoreKit.Category(id: fun, kind: .expense, name: "Fun"),
      CoreKit.Category(id: loans, kind: .expense, name: "Loans", systemRole: .loans),
    ]
  }

  var debts: [Debt] {
    [
      Debt(
        id: loan, direction: .iOwe, type: .loan, name: "Loan", monthlyPaymentE4: Fx.rub("10000"),
        paymentDay: 5),
      Debt(
        id: credit, direction: .iOwe, type: .installment, name: "Phone",
        monthlyPaymentE4: Fx.rub("2000"), paymentDay: 10, paymentsAreExpenses: false,
        origin: .purchase),
    ]
  }

  func spending(
    _ entries: [TransactionEntry], journal: [DebtEntry] = [], debts: [Debt]? = nil,
    scheduled: [ScheduledPayment] = [], matches: ScheduledMatches = .empty,
    subscriptions: AmountE4 = .zero, settings: CapitalSettings = .standard
  ) -> (ObligatorySpending, DebtsOverview) {
    let book = PlanningBook(scheduled: scheduled, debtEntries: journal)
    let ledger = Ledger(
      dataset: Dataset(
        entries: entries, categories: categories, debts: debts ?? self.debts, planning: book),
      calendar: .utc)
    let overview = DebtsOverview.build(ledger: ledger, book: book, today: today, rubPerUnit: [:])
    let result = ObligatoryRules.build(
      ledger: ledger, book: book, matches: matches, debts: overview,
      subscriptionsMonthly: subscriptions, settings: settings, today: today)
    return (result, overview)
  }

  /// April to September, each source once.
  @Test func eachSourceIsCountedOnce() {
    let matched = Fx.operation(6, "2026-06-15", "4000", category: fun)
    let entries = [
      Fx.operation(1, "2026-03-20", "100", category: fun),
      // April: groceries inherit «essential» from Food, the cafe says no, fun is not essential.
      Fx.operation(2, "2026-04-03", "1000", category: groceries),
      Fx.operation(3, "2026-04-04", "500", category: cafe),
      Fx.operation(4, "2026-04-05", "700", category: fun),
      // May: 25,000 paid on a loan of 10,000 a month, and a scheduled payment written by
      // «Провести» in an essential category — scheduled, not essential.
      Fx.operation(5, "2026-05-05", "25000", category: loans, debt: loan),
      Fx.operation(
        7, "2026-05-12", "3000", category: food,
        link: .scheduled(paymentId: rent, due: Fx.day("2026-05-12"))),
      // June: an ordinary operation that matched a due date.
      matched,
      // July: essential food; a difference of a count and a part paid for somebody else in it
      // are not spending of mine.
      Fx.operation(8, "2026-07-02", "2000", category: food),
      Fx.operation(
        9, "2026-07-03", "999", category: food, link: .reconciliation(Fx.id(70))),
      Fx.operation(10, "2026-07-04", "888", category: food, reimbursable: true),
      // September.
      Fx.operation(11, "2026-09-09", "1500", category: groceries),
    ]
    let journal = [
      DebtEntry(
        debtId: loan, date: Fx.day("2026-03-05"), amountE4: Fx.rub("100000"), kind: .borrowed),
      DebtEntry(
        debtId: loan, date: Fx.day("2026-05-05"), amountE4: Fx.rub("-25000"), kind: .payment,
        transactionId: entries[4].transaction.id),
      DebtEntry(
        debtId: credit, date: Fx.day("2026-04-10"), amountE4: Fx.rub("12000"), kind: .borrowed),
      DebtEntry(
        debtId: credit, date: Fx.day("2026-05-10"), amountE4: Fx.rub("-2000"), kind: .payment),
      DebtEntry(
        debtId: credit, date: Fx.day("2026-06-10"), amountE4: Fx.rub("-2000"), kind: .payment),
    ]
    let matches = ScheduledMatches(
      linked: [:], matched: [Fx.id(23): [Fx.day("2026-06-15"): matched.transaction.id]])
    let (result, overview) = spending(entries, journal: journal, matches: matches)

    #expect(
      result.months.map(\.month.iso) == [
        "2026-04", "2026-05", "2026-06", "2026-07", "2026-08", "2026-09",
      ])
    #expect(
      result.months.map(\.essentialRub) == [
        Fx.rub("1000"), .zero, .zero, Fx.rub("2000"), .zero, Fx.rub("1500"),
      ])
    #expect(
      result.months.map(\.scheduledRub) == [
        .zero, Fx.rub("3000"), Fx.rub("4000"), .zero, .zero, .zero,
      ])
    // May: the loan's due of 10,000 (the rest paid it off early) and the phone's 2,000 paid
    // through its journal; June: the phone again.
    #expect(
      result.months.map(\.debtsRub) == [
        .zero, Fx.rub("12000"), Fx.rub("2000"), .zero, .zero, .zero,
      ])
    #expect(
      result.months.map(\.total) == [
        Fx.rub("1000"), Fx.rub("15000"), Fx.rub("6000"), Fx.rub("2000"), .zero, Fx.rub("1500"),
      ])
    // 0, 1,000, 1,500, 2,000, 6,000, 15,000: the mean of the middle two.
    #expect(result.medianRub == Fx.rub("1750"))
    #expect(result.state == .ready)
    #expect(result.committedRub == overview.monthlyPaymentsRub)
    #expect(result.monthlyRub == max(Fx.rub("1750"), overview.monthlyPaymentsRub))
  }

  /// A debt without a schedule is not obligatory, however it is paid.
  @Test func aDebtWithoutDuesIsNotObligatory() {
    let friend = Debt(id: Fx.id(30), direction: .iOwe, type: .personal, name: "Friend")
    let entries = [
      Fx.operation(1, "2026-06-05", "5000", category: loans, debt: friend.id),
      Fx.operation(2, "2026-07-05", "100", category: fun),
    ]
    let journal = [
      DebtEntry(
        debtId: friend.id, date: Fx.day("2026-06-01"), amountE4: Fx.rub("9000"), kind: .borrowed),
      DebtEntry(
        debtId: friend.id, date: Fx.day("2026-06-05"), amountE4: Fx.rub("-5000"), kind: .payment,
        transactionId: entries[0].transaction.id),
    ]
    let (result, _) = spending(entries, journal: journal, debts: [friend])
    #expect(result.months.allSatisfy { $0.total == .zero })
  }

  @Test func theMedianOfAnOddCount() {
    let entries = [
      Fx.operation(1, "2026-07-03", "300", category: food),
      Fx.operation(2, "2026-08-03", "100", category: food),
      Fx.operation(3, "2026-09-03", "200", category: food),
    ]
    let (result, _) = spending(entries, debts: [])
    #expect(result.months.count == 3)
    #expect(result.medianRub == Fx.rub("200"))
    #expect(result.monthlyRub == Fx.rub("200"))
    #expect(result.committedRub == .zero)
  }

  @Test func fewerThanThreeFullMonthsAreNotEnough() {
    let entries = [
      Fx.operation(1, "2026-08-20", "300", category: food),
      Fx.operation(2, "2026-10-01", "100", category: food),
    ]
    let (result, _) = spending(entries, debts: [])
    #expect(result.state == .notEnoughData(fullMonths: 2))
    #expect(result.months.count == 2)
    #expect(result.medianRub == nil)
    #expect(result.monthlyRub == nil)

    let (none, _) = spending([], debts: [])
    #expect(none.state == .notEnoughData(fullMonths: 0))
  }

  @Test func theWindowIsTheHistoryMonthsBeforeThisOne() {
    let entries = (1...9).map { month in
      Fx.operation(month, String(format: "2026-%02d-10", month), "\(month * 100)", category: food)
    }
    let (six, _) = spending(entries, debts: [])
    #expect(six.months.map(\.month.month) == [4, 5, 6, 7, 8, 9])
    let (three, _) = spending(entries, debts: [], settings: CapitalSettings(historyMonths: 3))
    #expect(three.months.map(\.month.month) == [7, 8, 9])
    #expect(three.medianRub == Fx.rub("800"))
  }

  /// A new loan or subscription counts at once: the figure is never below what is committed
  /// today — the debts' monthly payments, the subscriptions and the bills that still repeat.
  @Test func theFigureIsNeverBelowWhatIsCommittedToday() {
    let entries = (7...9).map { month in
      Fx.operation(month, String(format: "2026-%02d-10", month), "1000", category: food)
    }
    let bills = [
      ScheduledPayment(
        name: "Rent", amountE4: Fx.rub("30000"), day: 1, nextDate: Fx.day("2026-11-01")),
      ScheduledPayment(
        name: "Insurance", amountE4: Fx.rub("12000"), freq: .yearly, day: 1, month: 3,
        nextDate: Fx.day("2027-03-01")),
      // Not committed: a one-off payment, one that ended, one in dollars, one paid for somebody
      // who gives it back, one switched off, and a subscription (counted by the caller).
      ScheduledPayment(
        name: "Once", amountE4: Fx.rub("5000"), nextDate: Fx.day("2026-11-01"),
        endDate: Fx.day("2026-11-01")),
      ScheduledPayment(
        name: "Ended", amountE4: Fx.rub("5000"), nextDate: Fx.day("2026-09-01"),
        endDate: Fx.day("2026-09-30")),
      ScheduledPayment(
        name: "Dollars", amountE4: Fx.rub("50"), currency: .usd, nextDate: Fx.day("2026-11-01")),
      ScheduledPayment(
        name: "For Anna", amountE4: Fx.rub("5000"), reimbursable: true,
        nextDate: Fx.day("2026-11-01")),
      ScheduledPayment(
        name: "Off", amountE4: Fx.rub("5000"), nextDate: Fx.day("2026-11-01"), active: false),
      ScheduledPayment(
        name: "Music", kind: .subscription, amountE4: Fx.rub("300"),
        nextDate: Fx.day("2026-11-01")),
    ]
    let (result, overview) = spending(
      entries, debts: [debts[0]], scheduled: bills, subscriptions: Fx.rub("300"))
    #expect(overview.monthlyPaymentsRub == Fx.rub("10000"))
    #expect(result.medianRub == Fx.rub("1000"))
    #expect(result.committedRub == Fx.rub("41300"))
    #expect(result.monthlyRub == Fx.rub("41300"))
  }
}
