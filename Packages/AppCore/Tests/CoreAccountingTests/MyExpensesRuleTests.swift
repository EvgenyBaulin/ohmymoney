import CoreKit
import Foundation
import Testing

@testable import CoreAccounting

@Suite("What counts as my spending")
struct MyExpensesRuleTests {
  let categories = StartingCategories()

  @Test func partsAddUpToTheTotal() {
    let dinner = entry(
      id(1),
      parts: [
        part(id(11), amount: money(600), category: categories.groceries),
        part(id(12), amount: money(400), category: categories.groceries),
      ])
    #expect(dinner.transaction.amountE4 == money(1000))
    #expect(dinner.isBalanced)
    #expect(dinner.partsBalance.isZero)
    #expect(dinner.isSplit)
  }

  @Test func aPlainExpenseIsMySpending() {
    let groceries = entry(
      id(1), parts: [part(id(11), amount: money(1000), category: categories.groceries)])
    #expect(MyExpensesRule.total(entries: [groceries]) == money(1000))
  }

  @Test func aPartPaidForSomebodyElseIsNotMySpending() {
    let dinner = entry(
      id(1),
      parts: [
        part(id(11), amount: money(600), category: categories.groceries),
        part(
          id(12), amount: money(400), category: categories.groceries, reimbursable: true,
          debtor: id(50)),
      ])
    #expect(MyExpensesRule.total(entries: [dinner]) == money(600))
    #expect(MyExpensesRule.totalOwedToMe(entries: [dinner]) == money(400))
  }

  @Test func aReturnedPartIsNotMySpendingAndHasLeftTheOwedList() {
    let dinner = entry(
      id(1),
      parts: [
        part(
          id(11), amount: money(400), category: categories.groceries, reimbursable: true,
          status: .returned, debtor: id(50))
      ])
    #expect(MyExpensesRule.total(entries: [dinner]) == .zero)
    #expect(MyExpensesRule.owedToMe(entries: [dinner]).isEmpty)
  }

  @Test func aWrittenOffPartBecomesMySpending() {
    let dinner = entry(
      id(1),
      parts: [
        part(
          id(11), amount: money(400), category: categories.groceries, reimbursable: true,
          status: .writtenOff, debtor: id(50))
      ])
    #expect(MyExpensesRule.total(entries: [dinner]) == money(400))
    #expect(MyExpensesRule.owedToMe(entries: [dinner]).isEmpty)
    #expect(MyExpensesRule.byCategory(entries: [dinner])[categories.groceries] == money(400))
  }

  @Test func forWhomNeverChangesTheTotal() {
    let mine = entry(
      id(1), parts: [part(id(11), amount: money(3000), category: categories.groceries)])
    let present = entry(
      id(2),
      parts: [
        part(id(21), amount: money(3000), category: categories.groceries, forWhom: .friends)
      ])
    #expect(MyExpensesRule.total(entries: [mine]) == MyExpensesRule.total(entries: [present]))

    let both = MyExpensesRule.byForWhom(entries: [mine, present])
    #expect(both[.me] == money(3000))
    #expect(both[.friends] == money(3000))
    #expect(AmountE4.sum(both.values) == MyExpensesRule.total(entries: [mine, present]))
  }

  @Test func aRefundReducesItsOwnCategory() {
    let phone = entry(
      id(1), on: "2026-03-01",
      parts: [part(id(11), amount: money(50000), category: categories.groceries)])
    let back = entry(
      id(2), kind: .refund, on: "2026-03-05",
      parts: [part(id(21), amount: money(20000), category: categories.groceries)])
    let food = entry(
      id(3), on: "2026-03-06",
      parts: [part(id(31), amount: money(1000), category: categories.health)])

    let totals = MyExpensesRule.byCategory(entries: [phone, back, food])
    #expect(totals[categories.groceries] == money(30000))
    #expect(totals[categories.health] == money(1000))
    #expect(MyExpensesRule.total(entries: [phone, back, food]) == money(31000))
  }

  /// Something bought for a friend and taken back to the shop: that money was never mine,
  /// so a refund part marked «за другого» never takes anything off my spending — the month
  /// would go below what I actually spent.
  @Test func aRefundOfAPartBoughtForSomebodyElseLeavesMySpendingAlone() {
    let mine = entry(
      id(1), on: "2026-03-01",
      parts: [part(id(11), amount: money(1000), category: categories.groceries)])
    let back = entry(
      id(2), kind: .refund, on: "2026-03-05",
      parts: [
        part(
          id(21), amount: money(400), category: categories.groceries, reimbursable: true,
          debtor: id(50))
      ])

    let refund = back.parts[0]
    #expect(MyExpensesRule.contribution(part: refund, in: back.transaction) == .zero)
    #expect(MyExpensesRule.total(entries: [mine, back]) == money(1000))
    #expect(MyExpensesRule.byCategory(entries: [mine, back])[categories.groceries] == money(1000))
  }

  /// The status of a refund part changes nothing. Only an expense part is ever returned or
  /// written off in the app — the «Owed to me» list and the write-off button know nothing
  /// else — so a status on a refund part can only come from outside, and the rule does not
  /// lean on it.
  @Test(arguments: [ReimbursementStatus.expected, .returned, .writtenOff])
  func aReimbursableRefundPartNeverReducesMySpending(status: ReimbursementStatus) {
    let mine = entry(
      id(1), on: "2026-03-01",
      parts: [part(id(11), amount: money(1000), category: categories.groceries)])
    let back = entry(
      id(2), kind: .refund, on: "2026-03-05",
      parts: [
        part(
          id(21), amount: money(400), category: categories.groceries, reimbursable: true,
          status: status, debtor: id(50))
      ])
    #expect(MyExpensesRule.contribution(part: back.parts[0], in: back.transaction) == .zero)
    #expect(MyExpensesRule.total(entries: [mine, back]) == money(1000))
  }

  @Test func aRefundOutOfAGoalTakesTheProgressBack() {
    let goalId = id(70)
    let contribution = entry(
      id(1), on: "2026-03-01",
      parts: [
        part(id(11), amount: money(10000), category: categories.goalsTrip, goal: goalId)
      ])
    let back = entry(
      id(2), kind: .refund, on: "2026-03-20",
      parts: [
        part(id(21), amount: money(4000), category: categories.goalsTrip, goal: goalId)
      ])
    let progress = MyExpensesRule.goalProgress(entries: [contribution, back])
    #expect(progress[goalId] == money(6000))
    #expect(MyExpensesRule.total(entries: [contribution, back]) == money(6000))
  }

  @Test func incomeAndReimbursementsAreNeverSpending() {
    let salary = entry(
      id(1), kind: .income, parts: [part(id(11), amount: money(100_000))])
    let paidBack = entry(
      id(2), kind: .reimbursement, parts: [part(id(21), amount: money(400))])
    #expect(MyExpensesRule.total(entries: [salary, paidBack]) == .zero)
  }

  @Test func aPaymentOnADebtIAlreadyHadIsAnExpense() {
    let debt = existingDebt(subcategory: categories.loansCar)
    let payment = entry(
      id(1), debtId: debt.id,
      parts: [part(id(11), amount: money(25000), category: categories.loansCar)])
    let total = MyExpensesRule.total(entries: [payment], debts: [debt.id: debt])
    #expect(total == money(25000))
  }

  @Test func aPaymentOnSomethingBoughtInInstalmentsIsNotAnExpense() {
    let debt = purchaseDebt()
    let payment = entry(
      id(1), debtId: debt.id,
      parts: [part(id(11), amount: money(25000), category: categories.loansCar)])
    #expect(MyExpensesRule.total(entries: [payment], debts: [debt.id: debt]) == .zero)
  }

  @Test func aPaymentWhoseDebtWasNotSuppliedIsLeftOut() {
    let debt = purchaseDebt()
    let payment = entry(
      id(1), debtId: debt.id,
      parts: [part(id(11), amount: money(25000), category: categories.loansCar)])
    #expect(MyExpensesRule.total(entries: [payment]) == .zero)
  }

  @Test func aPurchaseOnCreditIsAnExpenseRightAway() {
    let debt = purchaseDebt()
    let laptop = entry(
      id(1), creditDebtId: debt.id,
      parts: [part(id(11), amount: money(120_000), category: categories.groceries)])
    #expect(MyExpensesRule.total(entries: [laptop], debts: [debt.id: debt]) == money(120_000))
  }

  @Test func aRefundOfAPaymentThatWasNeverAnExpenseDoesNotReduceMySpending() {
    // The payment on something bought in instalments is not an expense, so the money
    // coming back for it must not be taken off my spending either.
    let debt = purchaseDebt()
    let debts = [debt.id: debt]
    let groceries = entry(
      id(1), parts: [part(id(11), amount: money(30000), category: categories.groceries)])
    let payment = entry(
      id(2), debtId: debt.id,
      parts: [part(id(21), amount: money(25000), category: categories.loansCar)])
    let bounced = entry(
      id(3), kind: .refund, debtId: debt.id,
      parts: [part(id(31), amount: money(25000), category: categories.loansCar)])

    #expect(MyExpensesRule.total(entries: [groceries, payment], debts: debts) == money(30000))
    #expect(
      MyExpensesRule.total(entries: [groceries, payment, bounced], debts: debts)
        == money(30000))
    #expect(
      MyExpensesRule.byCategory(entries: [payment, bounced], debts: debts)[categories.loansCar]
        == .zero)
  }

  @Test func aRefundOnADebtNobodySuppliedIsLeftOutJustLikeItsPayment() {
    // Without the debt the payment is left out, so its refund has to be left out too —
    // otherwise the pair turns into spending below zero.
    let debt = existingDebt()
    let payment = entry(
      id(1), debtId: debt.id,
      parts: [part(id(11), amount: money(25000), category: categories.loansCar)])
    let bounced = entry(
      id(2), kind: .refund, debtId: debt.id,
      parts: [part(id(21), amount: money(25000), category: categories.loansCar)])
    #expect(MyExpensesRule.total(entries: [payment, bounced]) == .zero)
  }

  @Test func aPurchaseOnCreditIsNotCountedAgainWhenItsPaymentsAreExpenses() {
    // The «payments are expenses» switch of the debt card decides which side counts. With
    // it on, the payments are the expense and the purchase must not be counted a second
    // time (one purchase is an expense exactly once).
    var debt = purchaseDebt()
    debt.paymentsAreExpenses = true
    let purchase = entry(
      id(1), on: "2026-01-10", creditDebtId: debt.id,
      parts: [part(id(11), amount: money(120_000), category: categories.groceries)])
    let payments = [
      entry(
        id(2), on: "2026-02-10", debtId: debt.id,
        parts: [part(id(21), amount: money(60000), category: categories.loansCar)]),
      entry(
        id(3), on: "2026-03-10", debtId: debt.id,
        parts: [part(id(31), amount: money(60000), category: categories.loansCar)]),
    ]
    let entries = [purchase] + payments
    #expect(MyExpensesRule.total(entries: entries, debts: [debt.id: debt]) == money(120_000))
    #expect(
      MyExpensesRule.byCategory(entries: entries, debts: [debt.id: debt])[categories.groceries]
        == .zero)
  }

  @Test func aPurchaseOnCreditStillCountsWhenTheDebtWasNotSupplied() {
    // The payments of an unknown debt are left out, so the purchase has to stay in:
    // between the two, the money is shown exactly once.
    let debt = purchaseDebt()
    let laptop = entry(
      id(1), creditDebtId: debt.id,
      parts: [part(id(11), amount: money(120_000), category: categories.groceries)])
    #expect(MyExpensesRule.total(entries: [laptop]) == money(120_000))
  }

  @Test func debtBalancesStayOutOfTheTotals() {
    let debt = existingDebt()
    let journal = [
      DebtRules.makeEntry(debtId: debt.id, kind: .borrowed, amountE4: money(500_000))
    ]
    #expect(DebtRules.balance(entries: journal) == money(500_000))
    #expect(MyExpensesRule.total(entries: [], debts: [debt.id: debt]) == .zero)
  }

  @Test func deletedOperationsAreIgnored() {
    let gone = entry(
      id(1), deleted: true,
      parts: [part(id(11), amount: money(1000), category: categories.groceries)])
    #expect(MyExpensesRule.total(entries: [gone]) == .zero)
    #expect(MyExpensesRule.owedToMe(entries: [gone]).isEmpty)
  }

  @Test func owedPartsAreListedOldestFirst() {
    let march = entry(
      id(1), on: "2026-03-10",
      parts: [
        part(
          id(11), amount: money(400), category: categories.groceries, reimbursable: true,
          debtor: id(50))
      ])
    let february = entry(
      id(2), on: "2026-02-02",
      parts: [
        part(
          id(21), amount: money(250), category: categories.health, reimbursable: true,
          debtor: id(50))
      ])
    let owed = MyExpensesRule.owedToMe(entries: [march, february])
    #expect(owed.map(\.partId) == [id(21), id(11)])
    #expect(owed.first?.categoryId == categories.health)
  }

  /// A shortfall left of an owed part stays with the person and the event of the purchase,
  /// so the owed part has to bring them along.
  @Test func anOwedPartKnowsWhomItWasForAndItsEvent() {
    var ticket = part(
      id(11), amount: money(1500), category: categories.groceries, forWhom: .friends,
      reimbursable: true, debtor: id(50))
    ticket.forPersonId = id(51)
    ticket.eventId = id(70)
    let owed = MyExpensesRule.owedToMe(entries: [entry(id(1), parts: [ticket])])
    #expect(owed.first?.forPersonId == id(51))
    #expect(owed.first?.debtorPersonId == id(50))
    #expect(owed.first?.eventId == id(70))
  }

  @Test func categoryTotalsRollUpToTheParent() {
    let fuel = entry(
      id(1), parts: [part(id(11), amount: money(4000), category: categories.fuel)])
    let fine = entry(
      id(2), parts: [part(id(21), amount: money(500), category: categories.fines)])
    let loose = entry(id(3), parts: [part(id(31), amount: money(100))])

    let totals = MyExpensesRule.byCategory(entries: [fuel, fine, loose])
    #expect(totals.uncategorized == money(100))
    let rolled = totals.rolledUp(with: categories.tree)
    #expect(rolled[categories.car] == money(4500))
    #expect(rolled.total == money(4600))
  }

  @Test func qualityTotalsSplitTheSameMoney() {
    let entries = [
      entry(
        id(1),
        parts: [
          part(id(11), amount: money(1000), category: categories.groceries, quality: .neutral),
          part(id(12), amount: money(500), category: categories.fines, quality: .bad),
        ]),
      entry(
        id(2), parts: [part(id(21), amount: money(2000), category: categories.education)]),
    ]
    let totals = MyExpensesRule.byQuality(entries: entries)
    #expect(totals[.bad] == money(500))
    #expect(totals[.neutral] == money(3000))
    #expect(AmountE4.sum(totals.values) == MyExpensesRule.total(entries: entries))
  }

  /// A part stored without a quality is counted the way the ledger counts it: by the resolver
  /// — a goal is good, then my last rating of the same description, then the category, a
  /// subcategory following its parent. Not as «neutral» whatever the category says.
  @Test func aPartWithoutAQualityIsResolvedAsTheLedgerResolvesIt() {
    let entries = [
      entry(id(1), parts: [part(id(11), amount: money(2000), category: categories.education)]),
      entry(id(2), parts: [part(id(21), amount: money(300), category: categories.pharmacy)]),
      entry(id(3), parts: [part(id(31), amount: money(700), category: categories.goalsTrip)]),
      entry(
        id(4), on: "2026-03-01", note: "Taxi",
        parts: [
          part(
            id(41), amount: money(400), category: categories.groceries, quality: .bad,
            qualitySource: .manual)
        ]),
      entry(
        id(5), note: "taxi",
        parts: [part(id(51), amount: money(500), category: categories.groceries)]),
      entry(id(6), parts: [part(id(61), amount: money(100), category: categories.groceries)]),
    ]
    let totals = MyExpensesRule.byQuality(entries: entries, categories: categories.tree)
    #expect(totals[.good] == money(3000))
    #expect(totals[.bad] == money(900))
    #expect(totals[.neutral] == money(100))
    #expect(AmountE4.sum(totals.values) == MyExpensesRule.total(entries: entries))
  }
}
