import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CorePlanning

/// What the launch asks about: one row for each payment or debt with a due date passed and
/// unpaid, and whether the money may already be inside a later count.
@Suite("Overdue due dates and the count after them")
struct OverdueDuesTests {
  typealias Fx = CashFx

  static let loan = Debt(
    id: Fx.id(301), direction: .iOwe, type: .loan, name: "Loan",
    monthlyPaymentE4: Fx.money("8000"), paymentDay: 5)

  /// Rent due on the 5th of every month since August, nothing paid; a loan taken on 20 August,
  /// due on the 5th, nothing paid. Today the 19th of September: one row each, the earliest due
  /// first, with the number of the others.
  @Test func oneRowPerSubjectWithItsEarliestDue() {
    var fx = Fx()
    fx.count([(Fx.main, .rub, "100000")], at: Fx.at("2026-09-10", 14))
    fx.scheduled = [Fx.payment(1, "Rent", "30000", day: 5, next: "2026-08-05")]
    fx.debts = [Self.loan]
    fx.debtEntries = [
      DebtEntry(
        debtId: Self.loan.id, date: Fx.day("2026-08-20"), amountE4: Fx.money("80000"),
        kind: .borrowed)
    ]
    let overdue = fx.snapshot().overdue
    #expect(overdue.map(\.subject) == [.scheduled(Fx.id(1)), .debt(Self.loan.id)])
    #expect(overdue.map(\.due) == [Fx.day("2026-08-05"), Fx.day("2026-09-05")])
    #expect(overdue.map(\.moreOverdue) == [1, 0])
    #expect(overdue.map(\.amount) == [Fx.money("30000"), Fx.money("8000")])
    #expect(
      overdue.map(\.id) == [
        "pay:\(Fx.id(1).uuidString.lowercased()):2026-08-05",
        "debt:\(Self.loan.id.uuidString.lowercased()):2026-09-05",
      ])
    // Main was counted on the 10th, after both due dates.
    #expect(overdue.map(\.countAfter) == [Fx.at("2026-09-10", 14), Fx.at("2026-09-10", 14)])
  }

  /// «Пропустить все N»: skipping stops at the latest of the unpaid dues before today. Rent
  /// nobody paid since June, today 19 September: four dues, the first 5 June, the last 5 September.
  @Test func theLastOverdueDueIsWhereSkippingAllStops() {
    var fx = Fx()
    fx.scheduled = [Fx.payment(1, "Rent", "30000", day: 5, next: "2026-06-05")]
    let due = fx.snapshot().overdue.first
    #expect(due?.due == Fx.day("2026-06-05"))
    #expect(due?.moreOverdue == 3)
    #expect(due?.lastDue == Fx.day("2026-09-05"))
    #expect(due?.skipping(all: false) == Fx.day("2026-06-05"))
    #expect(due?.skipping(all: true) == Fx.day("2026-09-05"))
  }

  /// One overdue due is its own last: skipping one and skipping all are the same.
  @Test func aSingleOverdueDueIsItsOwnLast() {
    var fx = Fx()
    fx.scheduled = [Fx.payment(1, "Rent", "30000", day: 5, next: "2026-09-05")]
    let due = fx.snapshot().overdue.first
    #expect(due?.moreOverdue == 0)
    #expect(due?.lastDue == due?.due)
    #expect(due?.skipping(all: true) == due?.skipping(all: false))
  }

  /// A due an ordinary operation paid is not among the unpaid ones, and the last one is still the
  /// latest unpaid: rent of July paid, June, August and September are not.
  @Test func aPaidDueInTheMiddleIsNotCounted() {
    var fx = Fx()
    fx.scheduled = [Fx.payment(1, "Rent", "30000", day: 5, next: "2026-06-05")]
    fx.add(
      .expense, "30000", at: Fx.at("2026-07-06", 12), category: Fx.housing,
      link: .scheduled(paymentId: Fx.id(1), due: Fx.day("2026-07-05")))
    let due = fx.snapshot().overdue.first
    #expect(due?.due == Fx.day("2026-06-05"))
    #expect(due?.moreOverdue == 2, "August and September stand with June")
    #expect(due?.lastDue == Fx.day("2026-09-05"))
  }

  /// A debt has the same: the earliest unpaid due, and the last before today.
  @Test func aDebtKnowsItsLastOverdueDueToo() {
    var fx = Fx()
    fx.debts = [Self.loan]
    fx.debtEntries = [
      DebtEntry(
        debtId: Self.loan.id, date: Fx.day("2026-06-20"), amountE4: Fx.money("80000"),
        kind: .borrowed)
    ]
    let due = fx.snapshot().overdue.first
    #expect(due?.isDebt == true)
    #expect(due?.due == Fx.day("2026-07-05"))
    #expect(due?.lastDue == Fx.day("2026-09-05"))
    #expect(due?.moreOverdue == 2)
  }

  /// A count on the due day itself may hold the money; one before it cannot; none, nothing.
  @Test func countAfterOnlyWithACountOnOrAfterTheDueDay() {
    var fx = Fx()
    fx.scheduled = [Fx.payment(1, "Rent", "30000", day: 5, next: "2026-09-05")]
    #expect(fx.snapshot().overdue.first?.countAfter == nil)
    fx.count([(Fx.main, .rub, "100000")], at: Fx.at("2026-09-04", 9))
    #expect(fx.snapshot().overdue.first?.countAfter == nil)
    fx.count([(Fx.main, .rub, "90000")], at: Fx.at("2026-09-05", 18))
    #expect(fx.snapshot().overdue.first?.countAfter == Fx.at("2026-09-05", 18))
  }

  /// A reminder put off hides nothing here: the overdue row asks again at every launch.
  @Test func dismissedRemindersAreIgnored() {
    var fx = Fx()
    fx.scheduled = [Fx.payment(1, "Rent", "30000", day: 5, next: "2026-09-05")]
    fx.settings.dismissedReminders = ["pay:\(Fx.id(1).uuidString.lowercased()):2026-09-05"]
    let snapshot = fx.snapshot()
    #expect(snapshot.reminders.filter { $0.kind == .payment }.isEmpty)
    #expect(snapshot.overdue.map(\.due) == [Fx.day("2026-09-05")])
  }

  /// A payment whose money is out of the summary is not asked about, as the free sum leaves it
  /// out; one paid, one due today or later, and one not active neither.
  @Test func whatIsNotOverdueOrNotInTheSummaryIsLeftOut() {
    var fx = Fx()
    var paused = Fx.payment(4, "Paused", "100", day: 1, next: "2026-09-01")
    paused.active = false
    fx.scheduled = [
      Fx.payment(1, "Phone", "5000", day: 5, next: "2026-09-05", account: Fx.freedom),
      Fx.payment(2, "Today", "700", day: 19, next: "2026-09-19"),
      Fx.payment(3, "Paid", "900", day: 10, next: "2026-09-10"),
      paused,
    ]
    fx.add(
      .expense, "900", at: Fx.at("2026-09-10", 12), category: Fx.housing,
      link: .scheduled(paymentId: Fx.id(3), due: Fx.day("2026-09-10")))
    #expect(fx.snapshot().overdue.isEmpty)
  }

  /// A payment on an archived account is about the main account's money.
  @Test func anArchivedAccountIsAboutTheMainAccount() {
    var fx = Fx()
    let old = Fx.id(9)
    fx.accounts.append(
      PaymentMethod(
        id: old, name: "Old", currency: .rub, archived: true, groupId: Fx.kazakhstan))
    fx.count([(Fx.main, .rub, "100000")], at: Fx.at("2026-09-10", 14))
    fx.scheduled = [Fx.payment(1, "Gym", "2000", day: 5, next: "2026-09-05", account: old)]
    let row = fx.snapshot().overdue.first
    #expect(row?.key == BalanceKey(accountId: Fx.main, currency: .rub))
    #expect(row?.countAfter == Fx.at("2026-09-10", 14))
  }

  /// A debt's due is about the account of its last payment — the card that paid it —, in the
  /// debt's currency when the card holds it.
  @Test func aDueIsAboutTheAccountOfTheLastPayment() {
    var fx = Fx()
    fx.debts = [Self.loan]
    fx.debtEntries = [
      DebtEntry(
        debtId: Self.loan.id, date: Fx.day("2026-07-20"), amountE4: Fx.money("80000"),
        kind: .borrowed)
    ]
    fx.add(.expense, "8000", at: Fx.at("2026-08-05", 12), account: Fx.card, debt: Self.loan.id)
    fx.count([(Fx.card, .rub, "5000")], at: Fx.at("2026-09-12", 9))
    let row = fx.snapshot().overdue.first
    #expect(row?.key == BalanceKey(accountId: Fx.card, currency: .rub))
    #expect(row?.countAfter == Fx.at("2026-09-12", 9))
    #expect(
      DueKeys.key(
        of: Self.loan, ledger: fx.ledger, journal: fx.debtEntries, mainId: Fx.main)
        == BalanceKey(accountId: Fx.card, currency: .rub))
  }

  // MARK: - The count after a due

  static let key = BalanceKey(accountId: CashFx.main, currency: .rub)

  func balances(_ fx: CashFx) -> AccountBalances { fx.snapshot().accounts.balances }

  /// Rent due on the 5th, Main counted on the 10th at 14:00: «Провести» on the 19th dated the
  /// due day at noon asks about the count of the 10th. A due on the count's own day is the
  /// question of that day, not this one.
  @Test func countAfterDueAsksOnlyForAnEarlierDueDay() {
    var fx = Fx()
    fx.count([(Fx.main, .rub, "100000")], at: Fx.at("2026-09-10", 14))
    let calendar = CalendarContext.utc
    #expect(
      AccountReconciliation.countAfterDue(
        due: Fx.day("2026-09-05"), occurredAt: Fx.at("2026-09-05", 12), savedAt: Fx.now,
        keys: [Self.key], balances: balances(fx), calendar: calendar)
        == Fx.at("2026-09-10", 14))
    #expect(
      AccountReconciliation.countAfterDue(
        due: Fx.day("2026-09-10"), occurredAt: Fx.at("2026-09-10", 12), savedAt: Fx.now,
        keys: [Self.key], balances: balances(fx), calendar: calendar) == nil)
    // Dated now, after the count: nothing to ask.
    #expect(
      AccountReconciliation.countAfterDue(
        due: Fx.day("2026-09-05"), occurredAt: Fx.now, savedAt: Fx.now, keys: [Self.key],
        balances: balances(fx), calendar: calendar) == nil)
    // The question the action asks: the dated one, then the day's own.
    guard
      case .dueBefore(let count, let due, let reconciliation) = AccountReconciliation.dueQuestion(
        due: Fx.day("2026-09-05"), occurredAt: Fx.at("2026-09-05", 12), savedAt: Fx.now,
        keys: [Self.key], balances: balances(fx), calendar: calendar)
    else {
      Issue.record("the dated question")
      return
    }
    #expect(count == Fx.at("2026-09-10", 14))
    #expect(due == Fx.day("2026-09-05"))
    // The count's reconciliation: the question can offer «Больше не спрашивать для этой сверки».
    #expect(reconciliation == fx.reconciliations.last?.id)
    guard
      case .sameDay = AccountReconciliation.dueQuestion(
        due: Fx.day("2026-09-10"), occurredAt: Fx.at("2026-09-10", 15), savedAt: Fx.now,
        keys: [Self.key], balances: balances(fx), calendar: calendar)
    else {
      Issue.record("the question of the day")
      return
    }
  }

  /// A payment saved before the count was made is not asked about it.
  @Test func countAfterDueIsNotAskedWhenSavedBeforeTheCount() {
    var fx = Fx()
    fx.count([(Fx.main, .rub, "100000")], at: Fx.at("2026-09-10", 14))
    #expect(
      AccountReconciliation.countAfterDue(
        due: Fx.day("2026-09-05"), occurredAt: Fx.at("2026-09-05", 12),
        savedAt: Fx.at("2026-09-10", 13), keys: [Self.key], balances: balances(fx),
        calendar: .utc) == nil)
  }

  /// Of several balances the payment moves, the latest count is asked about.
  @Test func countAfterDueTakesTheLatestOfTheKeys() {
    var fx = Fx()
    fx.count([(Fx.main, .rub, "100000")], at: Fx.at("2026-09-10", 14))
    fx.count([(Fx.card, .usd, "100")], at: Fx.at("2026-09-12", 9))
    #expect(
      AccountReconciliation.countAfterDue(
        due: Fx.day("2026-09-05"), occurredAt: Fx.at("2026-09-05", 12), savedAt: Fx.now,
        keys: [Self.key, BalanceKey(accountId: Fx.card, currency: .usd)],
        balances: balances(fx), calendar: .utc) == Fx.at("2026-09-12", 9))
  }

  /// «Да, до сверки» keeps the moment while it is before the count, else a second before it.
  @Test func yesBeforeTheCountKeepsTheMomentOrStampsIt() {
    let count = Fx.at("2026-09-10", 14)
    #expect(
      AccountReconciliation.momentBefore(count: count, occurredAt: Fx.at("2026-09-05", 12))
        == Fx.at("2026-09-05", 12))
    #expect(
      AccountReconciliation.momentBefore(count: count, occurredAt: Fx.at("2026-09-10", 15))
        == count.addingTimeInterval(-1))
  }

  /// The answer to «Деньги за «Аренда» ушли до сверки 10 сентября в 14:00?» dates the payment:
  /// «Да» on the due day at noon, inside the count; «Нет» now, after it.
  @Test func theAnswerToTheDatedQuestionDatesThePayment() {
    let count = Fx.at("2026-09-10", 14)
    let moment = Fx.at("2026-09-05", 12)
    #expect(
      AccountReconciliation.dueAnswer(
        count: count, occurredAt: moment, wasBefore: true, now: Fx.now) == moment)
    #expect(
      AccountReconciliation.dueAnswer(
        count: count, occurredAt: moment, wasBefore: false, now: Fx.now) == Fx.now)
    // A moment not before the count is put a second before it.
    #expect(
      AccountReconciliation.dueAnswer(
        count: count, occurredAt: Fx.at("2026-09-10", 15), wasBefore: true, now: Fx.now)
        == count.addingTimeInterval(-1))
  }

  /// «Больше не спрашивать для этой сверки» answers the dated question of that count without
  /// asking: «до» dates the payment inside the count, «после» now. An answer kept for another
  /// reconciliation leaves the question to be asked.
  @Test func aRememberedAnswerSettlesTheDatedQuestion() {
    var fx = Fx()
    fx.count([(Fx.main, .rub, "100000")], at: Fx.at("2026-09-10", 14))
    let reconciliation = fx.reconciliations.last?.id ?? UUID()
    let moment = Fx.at("2026-09-05", 12)
    func question(_ remembered: [UUID: Bool]) -> DueCountAsk {
      AccountReconciliation.dueQuestion(
        due: Fx.day("2026-09-05"), occurredAt: moment, savedAt: Fx.now, keys: [Self.key],
        balances: balances(fx), calendar: .utc, remembered: remembered)
    }
    guard case .dueAnswered(let before) = question([reconciliation: true]) else {
      Issue.record("«до» remembered")
      return
    }
    #expect(before == moment)
    guard case .dueAnswered(let after) = question([reconciliation: false]) else {
      Issue.record("«после» remembered")
      return
    }
    #expect(after == Fx.now)
    guard case .dueBefore = question([Fx.id(999): true]) else {
      Issue.record("another reconciliation answers nothing here")
      return
    }
  }
}
