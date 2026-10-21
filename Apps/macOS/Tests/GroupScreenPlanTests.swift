import AppCore
import AppKit
import SwiftUI
import XCTest

@testable import OhMyMoney

/// The screens of several accounts: a group of the sidebar and «Всего», every account of the
/// summary — what they list, the payments and incomes planned for their accounts, and the
/// moment an operation was last added to an account.
@MainActor
final class GroupScreenPlanTests: XCTestCase {
  private let calendar = CalendarContext(timeZone: TimeZone(identifier: "Europe/Moscow")!)
  private let today = DateOnly(year: 2026, month: 9, day: 22)

  private let sber = PaymentMethod(name: "Сбер", currency: .rub, isDefault: true)
  private let tbank = PaymentMethod(name: "Т-Банк", currency: .rub)
  private let kaspi = PaymentMethod(name: "Kaspi", currency: CurrencyCode("KZT"))

  // MARK: «Всего»

  /// «Всего» of the sidebar was a row nothing could choose: it had no tag and refused the
  /// selection, so a click on it did nothing, while every group under it opened its screen.
  /// It is a choice of its own now, which lists operations like the screen of a group and is
  /// never gone.
  func testTheTotalIsAChoiceOfTheSidebarThatListsOperations() {
    let total = SidebarItem.allAccounts
    XCTAssertTrue(total.listsOperations)
    XCTAssertNil(total.focusedAccountId, "no account takes the new operations")
    XCTAssertEqual(total.journalToken, "accounts")
    XCTAssertNil(
      total.fallback(liveAccounts: [], liveGroups: []), "the summary is there with no account")
    XCTAssertNotEqual(total, .group(UUID()))
  }

  /// The screen of «Всего» shows the accounts of the summary — a group left out of it stays
  /// out — with the total of the sidebar row; a group's screen shows its own accounts.
  func testTheTotalScreenShowsTheAccountsOfTheSummary() throws {
    let kz = AccountGroup(name: "Казахстан", inSummary: false)
    var kaspi = self.kaspi
    kaspi.groupId = kz.id
    let at = Date(timeIntervalSince1970: 1_790_000_000)
    let count = Reconciliation(
      date: calendar.day(of: at), reconciledAt: at, actualTotalRubE4: .zero, kind: .accounts)
    let dataset = Dataset(
      paymentMethods: [kaspi, sber, tbank],
      planning: PlanningBook(
        reconciliations: [count],
        reconciledBalances: [
          ReconciledBalance(
            reconciliationId: count.id, accountId: sber.id, currency: .rub,
            actualE4: AmountE4(whole: 1_000)),
          ReconciledBalance(
            reconciliationId: count.id, accountId: tbank.id, currency: .rub,
            actualE4: AmountE4(whole: 500)),
          ReconciledBalance(
            reconciliationId: count.id, accountId: kaspi.id, currency: CurrencyCode("KZT"),
            actualE4: AmountE4(whole: 57_000)),
        ]),
      accountGroups: [kz])
    let snapshot = AccountsSnapshot.build(
      dataset: dataset, now: at.addingTimeInterval(60), calendar: calendar,
      rubPerUnit: [CurrencyCode("KZT"): Decimal(string: "0.175")!], localeIdentifier: "ru")

    let total = try XCTUnwrap(GroupScope.summary.content(in: snapshot))
    XCTAssertNil(total.group)
    XCTAssertTrue(total.inSummary)
    XCTAssertEqual(Set(total.accounts.map(\.account.id)), [sber.id, tbank.id])
    XCTAssertEqual(total.totalRub, snapshot.inSummaryTotalRub)
    XCTAssertEqual(total.totalRub, AmountE4(whole: 1_500))

    let group = try XCTUnwrap(GroupScope.group(kz.id).content(in: snapshot))
    XCTAssertEqual(group.group?.id, kz.id)
    XCTAssertEqual(group.accounts.map(\.account.id), [kaspi.id])
    XCTAssertFalse(group.inSummary)
    XCTAssertNil(GroupScope.group(UUID()).content(in: snapshot), "a group gone shows nothing")
  }

  // MARK: The plan of a group

  /// A group's screen lists the payments and subscriptions paid from its accounts — one with
  /// no account is the main account's — and the incomes expected to them: to the account
  /// chosen for one, else the main account.
  func testAGroupShowsThePaymentsAndIncomesPlannedForItsAccounts() throws {
    let music = ScheduledPayment(
      name: "Музыка", amountE4: AmountE4(whole: 299), paymentMethodId: tbank.id,
      nextDate: today.adding(days: 3))
    let gym = ScheduledPayment(
      name: "Спортзал", amountE4: AmountE4(whole: 3_000), paymentMethodId: sber.id,
      nextDate: today.adding(days: 1))
    let rent = ScheduledPayment(
      name: "Квартира", amountE4: AmountE4(whole: 40_000), nextDate: today.adding(days: 5))
    let parents = ExpectedIncome(
      name: "Родители", kind: .recurring, totalE4: AmountE4(whole: 25_000),
      dueDate: DateOnly(year: 2026, month: 9, day: 30), freq: .monthly,
      paymentMethodId: tbank.id)
    let salary = ExpectedIncome(
      name: "Зарплата", totalE4: AmountE4(whole: 100_000), dueDate: today.adding(days: 3))
    let closed = ExpectedIncome(
      name: "Старое", totalE4: AmountE4(whole: 1), dueDate: today, closed: true,
      paymentMethodId: tbank.id)
    let dataset = Dataset(
      paymentMethods: [sber, tbank, kaspi],
      planning: PlanningBook(scheduled: [music, gym, rent], expected: [parents, salary, closed]))
    let ledger = Ledger(dataset: dataset, calendar: calendar)
    let planning = PlanningSnapshot.build(
      ledger: ledger, today: today, now: calendar.noon(of: today), rubPerUnit: [:])

    let group = GroupPlanModel(accountIds: [tbank.id], planning: planning, ledger: ledger)
    XCTAssertEqual(group.payments.map(\.status.payment.name), ["Музыка"])
    XCTAssertEqual(group.payments.first?.accountId, tbank.id)
    XCTAssertEqual(group.incomes.map(\.income.name), ["Родители"])
    XCTAssertEqual(group.incomes.first?.due, DateOnly(year: 2026, month: 9, day: 30))
    XCTAssertEqual(group.incomes.first?.remaining, AmountE4(whole: 25_000))

    let all = GroupPlanModel(accountIds: [sber.id, tbank.id], planning: planning, ledger: ledger)
    XCTAssertEqual(
      all.payments.map(\.status.payment.name), ["Спортзал", "Музыка", "Квартира"],
      "the soonest first; a payment with no account is the main account's")
    XCTAssertEqual(all.payments.last?.accountId, sber.id)
    XCTAssertEqual(
      all.incomes.map(\.income.name), ["Зарплата", "Родители"],
      "the soonest first; an income with no account comes to the main one")
    XCTAssertEqual(all.incomes.first?.accountId, sber.id)

    let none = GroupPlanModel(accountIds: [kaspi.id], planning: planning, ledger: ledger)
    XCTAssertTrue(none.payments.isEmpty)
    XCTAssertTrue(none.incomes.isEmpty)
  }

  // MARK: The last operation of an account

  /// The screen of an account and of a group says when an operation was last added there —
  /// the moment of writing, not the day the operation names —, and says so when none was.
  func testTheScreenSaysWhenAnOperationWasLastAdded() throws {
    let written = Date(timeIntervalSince1970: 1_790_000_000)
    var old = TransactionDraft(
      occurredAt: written.addingTimeInterval(-86_400 * 10), amount: AmountE4(whole: 250),
      paymentMethodId: tbank.id)
    old.normalizeSinglePart()
    let entry = try old.materialize(now: written)
    let dataset = Dataset(entries: [entry], paymentMethods: [sber, tbank])

    let history = AccountHistory.build(accountIds: [tbank.id], dataset: dataset, calendar: calendar)
    XCTAssertEqual(history.lastRecordedAt, entry.transaction.createdAt)
    let empty = AccountHistory.build(accountIds: [sber.id], dataset: dataset, calendar: calendar)
    XCTAssertNil(empty.lastRecordedAt)
    let both = AccountHistory.build(
      accountIds: [sber.id, tbank.id], dataset: dataset, calendar: calendar)
    XCTAssertEqual(both.lastRecordedAt, entry.transaction.createdAt)

    let environment = AppEnvironment()
    let before = environment.language.choice
    defer { environment.language.choice = before }
    environment.language.choice = .russian
    XCTAssertEqual(
      AccountText.lastRecord(entry.transaction.createdAt, environment),
      "Последняя операция добавлена \(environment.dates.moment(entry.transaction.createdAt))")
    XCTAssertEqual(AccountText.lastRecord(nil, environment), "Операций ещё не добавляли")
    environment.language.choice = .english
    XCTAssertEqual(AccountText.lastRecord(nil, environment), "No operation added yet")
  }
}
