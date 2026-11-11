import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CorePlanning

@Suite("Split and credit statement obligations")
struct SplitAndMinimumPlanningTests {
  private func day(_ text: String) -> DateOnly { DateOnly(iso: text)! }
  private func money(_ value: Int64) -> AmountE4 { AmountE4(whole: value) }

  @Test func manualMinimumAndDueReconcileActualPayments() throws {
    let books = CreditCardTests.books(
      CreditCardTests.twoPurchases,
      transfers: [
        CreditCardTests.transfer(
          30, "1000", on: "2026-11-12", from: CreditCardTests.mainId, to: CreditCardTests.cardId)
      ],
      today: "2026-11-15")
    let manual = CreditStatementOverride(
      accountId: books.account.id, closesOn: day("2026-11-05"), minimumE4: money(3200),
      due: day("2026-11-20"))
    let statements = CreditStatements.statements(
      account: books.account, terms: books.account.credit!, movements: books.movements,
      balances: books.balances, through: books.today, calendar: .utc, overrides: [manual])
    let last = try #require(statements.last)
    #expect(last.due == manual.due)
    #expect(!last.minimumIsEstimate)
    #expect(last.minimumRemainingE4 == money(2200))
    #expect(last.remainingE4 == money(29000))
    let now = CreditStatements.now(
      account: books.account, terms: books.account.credit!, statements: statements,
      movements: books.movements, balances: books.balances, today: books.today, calendar: .utc)
    #expect(now.minimumE4 == money(2200))
    #expect(now.payBy == manual.due)
    #expect(!now.minimumIsEstimate)

    let group = AccountGroup(name: "Cards outside", inSummary: false)
    var dataset = books.ledger.dataset
    dataset.accountGroups = [group]
    dataset.paymentMethods = dataset.paymentMethods.map { account in
      var account = account
      if account.id == books.account.id { account.groupId = group.id }
      return account
    }
    dataset.debtSettings.statementOverrides = [manual]
    let ledger = Ledger(dataset: dataset, calendar: .utc)
    let planning = PlanningSnapshot.build(
      ledger: ledger, today: books.today, now: CalendarContext.utc.endOfDay(books.today),
      rubPerUnit: [:])
    #expect(planning.freeMoney.plan.creditCards == money(2200))
    #expect(
      planning.planned.items.first { $0.creditAccountId == books.account.id }?.amount == money(2200)
    )
    let plans = CalendarPlans.collect(
      ledger: ledger, book: dataset.planning, today: books.today, through: manual.due)
    let plan = try #require(plans.first { $0.creditAccountId == books.account.id })
    #expect(plan.amount == money(2200))
    #expect(plan.fullAmountE4 == money(29000))
    #expect(!plan.isEstimate)

  }

  @Test func latePaymentReducesMinimumWithoutRestoringGrace() throws {
    let books = CreditCardTests.books(
      CreditCardTests.twoPurchases,
      transfers: [
        CreditCardTests.transfer(
          30, "1000", on: "2026-11-12",
          from: CreditCardTests.mainId, to: CreditCardTests.cardId)
      ], today: "2026-11-15")
    let manual = CreditStatementOverride(
      accountId: books.account.id,
      closesOn: day("2026-11-05"), minimumE4: money(3200), due: day("2026-11-10"))
    let list = CreditStatements.statements(
      account: books.account, terms: books.account.credit!, movements: books.movements,
      balances: books.balances, through: books.today, calendar: .utc, overrides: [manual])
    let statement = try #require(list.last)
    #expect(statement.state == .missed)
    #expect(statement.paidByDueE4 == .zero)
    #expect(statement.minimumRemainingE4 == money(2200))
    #expect(statement.remainingE4 == money(29000))
  }

  @Test func estimateUsesTermsAndCannotExceedDebt() {
    let books = CreditCardTests.books(CreditCardTests.twoPurchases, today: "2026-11-15")
    #expect(books.statements.last?.minimumIsEstimate == true)
    #expect(books.statements.last?.minimumRemainingE4 == money(2400))
  }

  @Test func splitRowsAreInCalendarAndPlanWithoutSpendingAgain() throws {
    let id = UUID()
    let dates = [day("2026-11-15"), day("2026-11-29"), day("2026-12-20")]
    let debt = Debt(
      id: id, direction: .iOwe, type: .installment, name: "Split", currency: .rub,
      paymentsAreExpenses: false, origin: .purchase,
      steps: DebtSteps(everyDays: 14, firstDue: dates[0]), parts: 3, markupE4: money(500))
    let journal = [
      DebtEntry(debtId: id, date: day("2026-11-11"), amountE4: money(6500), kind: .borrowed)
    ]
    let typed = [2000, 2000, 2500, 0].enumerated().map {
      DebtInstalmentStep(debtId: id, fromIndex: $0.offset, amountE4: money(Int64($0.element)))
    }
    let settings = DebtSettings(splitDates: [SplitDueDates(debtId: id, days: dates)])
    let book = PlanningBook(debtEntries: journal)
    let ledger = Ledger(
      dataset: Dataset(
        debts: [debt], planning: book, debtInstalments: typed, debtSettings: settings),
      calendar: .utc)
    let today = day("2026-11-12")
    let plan = PlannedMonth.build(ledger: ledger, book: book, today: today)
    #expect(plan.items.filter { $0.id == id }.map(\.amount) == [money(2000), money(2000)])
    #expect(plan.total == .zero)
    let calendar = CalendarPlans.collect(
      ledger: ledger, book: book, today: today, through: dates[2])
    #expect(calendar.filter { $0.sourceId == id }.map(\.day) == dates)
    #expect(
      calendar.filter { $0.sourceId == id }.map(\.amount) == [
        money(2000), money(2000), money(2500),
      ])
    let state = try #require(
      DebtDues.states(debts: [debt], ledger: ledger, journal: journal, today: today)[id])
    #expect(state.unpaid(through: dates[2]) == dates)
    #expect(state.owed(through: dates[2]) == money(6500))
  }

  @Test func unevenPaymentsCannotLoseCommission() {
    let payments = [money(1), money(99)]
    let shares = InstalmentPlan.markupShares(markup: money(99), payments: payments)
    #expect(shares == [money(1), money(98)])
    #expect(AmountE4.sum(shares) == money(99))
    #expect(zip(shares, payments).allSatisfy { $0 <= $1 })
  }

  @Test func settingsRoundTripPreservesStatementIdentityAndEditedDates() throws {
    let settings = DebtSettings(
      splitDates: [SplitDueDates(debtId: UUID(), days: [day("2026-11-20"), day("2026-12-07")])],
      statementOverrides: [
        CreditStatementOverride(
          accountId: UUID(), closesOn: day("2026-11-05"), minimumE4: money(2500),
          due: day("2026-11-25"))
      ])
    let rows = settings.storedValues.compactMapValues { $0 }
    #expect(DebtSettings(storedValues: rows) == settings)
    #expect(DebtSettings(storedValues: [:]).statementOverrides.isEmpty)
    #expect(try JSONDecoder().decode(DebtSettings.self, from: Data("{}".utf8)) == .standard)
  }
}
