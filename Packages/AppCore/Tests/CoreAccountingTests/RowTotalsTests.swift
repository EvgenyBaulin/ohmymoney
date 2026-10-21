import CoreKit
import Foundation
import Testing

@testable import CoreAccounting

@Suite("What a day or a selection comes to")
struct RowTotalsTests {
  let categories = StartingCategories()

  /// One day with a bit of everything: the four sums never borrow from one another.
  @Test func eachSumTakesOnlyWhatBelongsToIt() {
    let groceries = entry(
      id(1), parts: [part(id(11), amount: money(1000), category: categories.groceries)])
    let dinner = entry(
      id(2),
      parts: [
        part(id(21), amount: money(200), category: categories.groceries),
        part(
          id(22), amount: money(400), category: categories.groceries, reimbursable: true,
          debtor: id(50)),
      ])
    let givenUp = entry(
      id(3),
      parts: [
        part(
          id(31), amount: money(250), category: categories.groceries, reimbursable: true,
          status: .writtenOff, debtor: id(50))
      ])
    let refund = entry(
      id(4), kind: .refund,
      parts: [part(id(41), amount: money(100), category: categories.groceries)])
    let salary = entry(
      id(5), kind: .income, parts: [part(id(51), amount: money(5000), category: categories.salary)])
    let moneyBack = entry(id(6), kind: .reimbursement, parts: [part(id(61), amount: money(300))])
    let deleted = entry(
      id(7), deleted: true,
      parts: [part(id(71), amount: money(999), category: categories.groceries)])

    let totals = RowTotals(
      entries: [groceries, dinner, givenUp, refund, salary, moneyBack, deleted])

    // 1000 + 200 + 250 written off − 100 refunded.
    #expect(totals.myExpenses == money(1350))
    #expect(totals.income == money(5000))
    // Only what still waits: the written-off part is my spending now.
    #expect(totals.forOthers == money(400))
    // Money given back is neither income nor spending.
    #expect(totals.moneyReturned == money(300))
    #expect(totals.nonEmptyGroups == [.myExpenses, .income, .forOthers, .moneyReturned])
    #expect(totals[.income] == money(5000))
  }

  /// Two operations that were each accepted alone, on one day: the day's total
  /// used to trap on every open of the day. Now it stops at the edge of what money holds.
  @Test func aDayOfHugeOperationsDoesNotTrap() {
    let huge = AmountE4(raw: 6_000_000_000_000_000_000)
    let first = entry(id(1), parts: [part(id(11), amount: huge, category: categories.groceries)])
    let second = entry(id(2), parts: [part(id(21), amount: huge, category: categories.groceries)])
    let totals = RowTotals(entries: [first, second])
    #expect(totals.myExpenses == AmountE4(raw: .max))
  }

  @Test func emptyGroupsAreNotShown() {
    let coffee = entry(
      id(1), parts: [part(id(11), amount: money(250), category: categories.groceries)])
    #expect(RowTotals(entries: [coffee]).nonEmptyGroups == [.myExpenses])
    #expect(RowTotals(entries: []).isEmpty)
    #expect(RowTotals(entries: []) == .zero)
  }

  /// The day header follows the same debt rules as the month: a payment on something
  /// bought in instalments is not spending, a payment on an old loan is.
  @Test func aPaymentOnADebtCountsOnlyWhenTheDebtSaysSo() {
    let instalments = purchaseDebt()
    let loan = existingDebt()
    let debts = [instalments.id: instalments, loan.id: loan]
    let laptop = entry(
      id(1), debtId: instalments.id,
      parts: [part(id(11), amount: money(5000), category: categories.loansCar)])
    let car = entry(
      id(2), debtId: loan.id,
      parts: [part(id(21), amount: money(7000), category: categories.loansCar)])

    #expect(RowTotals(entries: [laptop], debts: debts).isEmpty)
    #expect(RowTotals(entries: [laptop, car], debts: debts).myExpenses == money(7000))
  }

  /// A refund of something bought for somebody else is neither my spending nor money I laid
  /// out for them.
  @Test func aReimbursableRefundPartIsInNoSum() {
    let back = entry(
      id(1), kind: .refund,
      parts: [
        part(
          id(11), amount: money(400), category: categories.groceries, reimbursable: true,
          debtor: id(50))
      ])
    #expect(RowTotals(entries: [back]).isEmpty)
  }

  /// Every operation of a day selected at once comes to exactly the day's header.
  @Test func theWholeDayAddsUpFromItsOperations() {
    let one = entry(
      id(1), parts: [part(id(11), amount: money("12.34"), category: categories.groceries)])
    let two = entry(
      id(2), parts: [part(id(21), amount: money("0.66"), category: categories.fuel)])
    let day = RowTotals(entries: [one, two])
    let separately = RowTotals(entries: [one]).myExpenses + RowTotals(entries: [two]).myExpenses
    #expect(day.myExpenses == separately)
    #expect(day.myExpenses == money(13))
  }
}
