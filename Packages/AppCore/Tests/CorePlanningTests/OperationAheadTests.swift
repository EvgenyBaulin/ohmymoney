import CoreAccounting
import CoreKit
import Foundation
import Testing

@testable import CorePlanning

/// An operation dated after today, written as it stands, is a «future expense» that belongs to
/// nobody's plan: a payment waiting for its day, or an income waiting to come. Before it is
/// written the owner is asked whether it is a record or a plan, and a plan is made from it here.
@Suite("An operation dated ahead")
struct OperationAheadTests {
  let calendar = CalendarContext.utc
  let today = DateOnly(year: 2026, month: 10, day: 4)
  let food = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
  let account = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
  let card = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
  let event = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!

  private func draft(
    _ kind: TransactionKind = .expense, on day: DateOnly? = nil, amount: Int64 = 2500,
    configure: (inout TransactionDraft) -> Void = { _ in }
  ) -> TransactionDraft {
    let when = calendar.noon(of: day ?? DateOnly(year: 2026, month: 10, day: 15))
    var draft = TransactionDraft(
      kind: kind, occurredAt: when, currency: .eur, amount: AmountE4(whole: amount),
      note: "sofa", paymentMethodId: account, cardId: card)
    draft.normalizeSinglePart()
    draft.parts[0].categoryId = kind == .expense ? food : nil
    draft.parts[0].eventId = event
    configure(&draft)
    return draft
  }

  @Test func anExpenseAheadMayBecomeAPayment() {
    #expect(OperationAhead.plan(for: draft(), today: today, calendar: calendar) == .payment)
  }

  @Test func anIncomeAheadMayBecomeAnExpectedIncome() {
    #expect(
      OperationAhead.plan(for: draft(.income), today: today, calendar: calendar) == .income)
  }

  /// Today and the past are records: only a day after today asks.
  @Test func todayAndThePastAreRecords() {
    for day in [today, DateOnly(year: 2026, month: 10, day: 3)] {
      #expect(OperationAhead.plan(for: draft(on: day), today: today, calendar: calendar) == nil)
    }
    let tomorrow = DateOnly(year: 2026, month: 10, day: 5)
    #expect(OperationAhead.plan(for: draft(on: tomorrow), today: today, calendar: calendar) != nil)
  }

  /// A refund and money back are tied to what they take back, and a transfer is no operation of
  /// this kind: nothing is asked.
  @Test func aRefundAndMoneyBackAreNeverPlans() {
    for kind in [TransactionKind.refund, .reimbursement] {
      #expect(OperationAhead.plan(for: draft(kind), today: today, calendar: calendar) == nil)
    }
  }

  /// A plan holds one payment: a split, a contribution to a goal, a payment on a debt and a
  /// purchase on credit have no such plan, so they are written as the owner entered them.
  @Test func whatAPlanCannotHoldIsARecord() {
    let split = draft { draft in
      draft.parts = [
        PartDraft(categoryId: food, amount: AmountE4(whole: 1000)),
        PartDraft(categoryId: food, amount: AmountE4(whole: 1500)),
      ]
    }
    let goal = draft { $0.parts[0].goalId = UUID() }
    let debt = draft { $0.debtId = UUID() }
    let credit = draft { $0.creditDebtId = UUID() }
    let refund = draft { $0.parts[0].refundOfPartId = UUID() }
    for held in [split, goal, debt, credit, refund] {
      #expect(OperationAhead.plan(for: held, today: today, calendar: calendar) == nil)
    }
  }

  @Test func aZeroAmountIsNoPlan() {
    #expect(OperationAhead.plan(for: draft(amount: 0), today: today, calendar: calendar) == nil)
  }

  /// The payment is one of «Разово»: every month, ending on its own date — so Planning reads it
  /// as one charge — carrying what the operation said.
  @Test func thePaymentIsAOneOffWithTheFieldsOfTheOperation() {
    let due = DateOnly(year: 2026, month: 10, day: 15)
    let payment = OperationAhead.scheduledPayment(
      from: draft { $0.parts[0].forWhom = .family }, named: "Sofa", calendar: calendar)
    #expect(payment.name == "Sofa")
    #expect(payment.kind == .bill)
    #expect(payment.amountE4 == AmountE4(whole: 2500))
    #expect(payment.currency == .eur)
    #expect(payment.categoryId == food)
    #expect(payment.paymentMethodId == account)
    #expect(payment.cardId == card)
    #expect(payment.eventId == event)
    #expect(payment.forWhom == .family)
    #expect(payment.nextDate == due && payment.endDate == due)
    #expect(payment.day == 15 && payment.freq == .monthly && payment.interval == 1)
    #expect(payment.isOneOff)
    #expect(payment.active)
  }

  @Test func thePaymentKeepsWhoGivesTheMoneyBack() {
    let debtor = UUID()
    let payment = OperationAhead.scheduledPayment(
      from: draft { draft in
        draft.parts[0].reimbursable = true
        draft.parts[0].debtorPersonId = debtor
      }, named: "Dinner", calendar: calendar)
    #expect(payment.reimbursable)
    #expect(payment.debtorPersonId == debtor)
  }

  /// A category of the app — «Не помню», Loans and what is under it — is not one a payment may
  /// have: the form of a payment refuses it («Системную категорию здесь выбрать нельзя»). An
  /// expense dated ahead in it becomes a payment with no category, one Planning saves as it is;
  /// an ordinary category stays.
  @Test func thePaymentLeavesACategoryOfTheAppOut() {
    let unknown = CoreKit.Category(kind: .expense, name: "Не помню", systemRole: .unknown)
    let loans = CoreKit.Category(kind: .expense, name: "Кредиты", systemRole: .loans)
    let mortgage = CoreKit.Category(parentId: loans.id, kind: .expense, name: "Ипотека")
    let groceries = CoreKit.Category(id: food, kind: .expense, name: "Продукты")
    let tree = CategoryTree([unknown, loans, mortgage, groceries])
    for category in [unknown.id, loans.id, mortgage.id] {
      let payment = OperationAhead.scheduledPayment(
        from: draft { $0.parts[0].categoryId = category }, named: "Sofa", calendar: calendar,
        tree: tree)
      #expect(payment.categoryId == nil)
      #expect(ScheduledRules.validate(payment, tree: tree) == nil)
    }
    let payment = OperationAhead.scheduledPayment(
      from: draft(), named: "Sofa", calendar: calendar, tree: tree)
    #expect(payment.categoryId == food)
  }

  @Test func theExpectedIncomeIsOneDueOnTheDay() {
    let due = DateOnly(year: 2026, month: 10, day: 15)
    let income = OperationAhead.expectedIncome(
      from: draft(.income) { $0.parts[0].categoryId = food }, named: "Salary", calendar: calendar)
    #expect(income.name == "Salary")
    #expect(income.kind == .oneOff)
    #expect(income.totalE4 == AmountE4(whole: 2500))
    #expect(income.currency == .eur)
    #expect(income.dueDate == due)
    #expect(income.categoryId == food)
    #expect(income.paymentMethodId == account)
    #expect(!income.closed)
  }
}
