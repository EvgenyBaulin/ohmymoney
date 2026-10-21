import CoreKit
import Foundation
import Testing

@testable import CoreAccounting

@Suite("Actions of the debt card: pay, adjust, close, a typed share")
struct DebtActionsTests {
  let categories = StartingCategories()

  func friendOwesMe(_ debtId: UUID = id(210), person: UUID? = id(40)) -> Debt {
    Debt(id: debtId, direction: .owedToMe, type: .personal, name: "Friend", personId: person)
  }

  // MARK: - Pay

  @Test func aPaymentOnADebtIOweIsAnExpenseAndOnADebtOwedToMeAReimbursement() {
    #expect(DebtRules.paymentKind(for: existingDebt()) == .expense)
    #expect(DebtRules.paymentKind(for: purchaseDebt()) == .expense)
    #expect(DebtRules.paymentKind(for: friendOwesMe()) == .reimbursement)
    // Money coming back is neither income nor spending.
    #expect(TransactionKind.reimbursement.reducesSpending)
    #expect(TransactionKind.reimbursement.categoryKind == .expense)
  }

  @Test func payingALoanGoesToItsLoansSubcategory() throws {
    let debt = existingDebt(subcategory: categories.loansCar)
    let paidAt = moment("2026-03-05")
    let draft = DebtRules.paymentDraft(
      debt: debt, amount: money(25000), occurredAt: paidAt, paymentMethodId: id(60),
      loansCategoryId: categories.loans)

    #expect(draft.kind == .expense)
    #expect(draft.debtId == debt.id)
    #expect(draft.creditDebtId == nil)
    #expect(draft.amount == money(25000))
    #expect(draft.currency == .rub)
    #expect(draft.occurredAt == paidAt)
    #expect(draft.paymentMethodId == id(60))
    #expect(draft.isBalanced)
    let part = try #require(draft.parts.first)
    #expect(draft.parts.count == 1)
    #expect(part.categoryId == categories.loansCar)
    #expect(part.categorySource == .system)
    #expect(part.reimbursable == false)

    // Written, it is 25 000 of my spending in Loans — the rule of a debt I already had.
    let written = try draft.materialize(id: id(1), now: paidAt)
    #expect(MyExpensesRule.total(entries: [written], debts: [debt.id: debt]) == money(25000))
  }

  @Test func withoutASubcategoryThePaymentGoesToTheLoansRoot() throws {
    let draft = DebtRules.paymentDraft(
      debt: existingDebt(), amount: money(-500), occurredAt: moment("2026-03-05"),
      paymentMethodId: nil, loansCategoryId: categories.loans)
    #expect(draft.amount == money(500))
    #expect(draft.parts.first?.categoryId == categories.loans)
    #expect(draft.parts.first?.amount == money(500))

    let nowhere = DebtRules.paymentDraft(
      debt: existingDebt(), amount: money(500), occurredAt: moment("2026-03-05"),
      paymentMethodId: nil, loansCategoryId: nil)
    #expect(nowhere.parts.first?.categoryId == nil)
    #expect(nowhere.parts.first?.categorySource == .manual)
  }

  /// Something bought in instalments: the payment is an operation on the debt, but the
  /// purchase was the expense, so the payment adds nothing to my spending.
  @Test func payingSomethingBoughtInInstalmentsIsNotSpendingAgain() throws {
    let debt = purchaseDebt()
    let draft = DebtRules.paymentDraft(
      debt: debt, amount: money(10000), occurredAt: moment("2026-03-10"), paymentMethodId: nil,
      loansCategoryId: categories.loans)
    #expect(draft.kind == .expense)
    #expect(draft.debtId == debt.id)
    let written = try draft.materialize(id: id(2), now: moment("2026-03-10"))
    #expect(MyExpensesRule.total(entries: [written], debts: [debt.id: debt]) == .zero)
  }

  @Test func moneyAFriendGivesBackIsAReimbursementWithoutACategory() throws {
    let debt = Debt(
      id: id(211), direction: .owedToMe, type: .personal, name: "Friend", personId: id(41),
      currency: .usd, loansSubcategoryId: categories.loansCar)
    let draft = DebtRules.paymentDraft(
      debt: debt, amount: money(50), occurredAt: moment("2026-03-12"), paymentMethodId: id(61),
      loansCategoryId: categories.loans)

    #expect(draft.kind == .reimbursement)
    #expect(draft.currency == .usd)
    #expect(draft.debtId == debt.id)
    #expect(draft.paymentMethodId == id(61))
    let part = try #require(draft.parts.first)
    #expect(part.categoryId == nil)
    #expect(part.forPersonId == id(41))
    #expect(part.amount == money(50))

    let written = try draft.materialize(id: id(3), now: moment("2026-03-12"))
    #expect(MyExpensesRule.total(entries: [written], debts: [debt.id: debt]) == .zero)
    let totals = RowTotals(entries: [written], debts: [debt.id: debt])
    #expect(totals.income == .zero)
    #expect(totals.moneyReturned == money(50))
  }

  // MARK: - Adjust

  @Test func anAdjustmentIsTheNewBalanceMinusTheOld() throws {
    let debt = existingDebt()
    let down = try DebtRules.adjustment(
      on: debt, from: money(100_000), to: money(98500), date: day("2026-03-31"),
      note: "bank statement")
    #expect(down.kind == .adjustment)
    #expect(down.debtId == debt.id)
    #expect(down.amountE4 == money(-1500))
    #expect(down.date == day("2026-03-31"))
    #expect(down.note == "bank statement")

    let up = try DebtRules.adjustment(on: debt, from: money("1000.50"), to: money(1200))
    #expect(up.amountE4 == money("199.5"))

    // The journal lands on the balance typed in.
    let journal = [
      DebtRules.makeEntry(debtId: debt.id, kind: .borrowed, amountE4: money(100_000)), down,
    ]
    #expect(DebtRules.balance(entries: journal) == money(98500))
  }

  @Test func anAdjustmentToTheSameBalanceIsRefused() {
    #expect(throws: DebtActionError.nothingToAdjust) {
      try DebtRules.adjustment(on: existingDebt(), from: money(700), to: money(700))
    }
  }

  // MARK: - Close

  @Test func closingKeepsTheRemainderUnlessItIsWrittenOff() {
    let debt = existingDebt()
    let kept = DebtRules.closing(debt, balance: money(1200), writeOffRemainder: false)
    #expect(kept.debt.closed)
    #expect(kept.debt.id == debt.id)
    #expect(kept.debt.name == debt.name)
    #expect(kept.entry == nil)

    let writtenOff = DebtRules.closing(
      debt, balance: money(1200), writeOffRemainder: true, date: day("2026-04-01"),
      entryId: id(5))
    #expect(writtenOff.debt.closed)
    let entry = writtenOff.entry
    #expect(entry?.id == id(5))
    #expect(entry?.kind == .adjustment)
    #expect(entry?.amountE4 == money(-1200))
    #expect(entry?.date == day("2026-04-01"))

    // An overpaid debt is brought back up to zero the same way.
    let overpaid = DebtRules.closing(debt, balance: money(-300), writeOffRemainder: true)
    #expect(overpaid.entry?.amountE4 == money(300))
  }

  @Test func closingASettledDebtWritesNothing() {
    let closed = DebtRules.closing(friendOwesMe(), balance: .zero, writeOffRemainder: true)
    #expect(closed.debt.closed)
    #expect(closed.entry == nil)
  }

  // MARK: - A share typed by hand

  @Test(arguments: [
    ("1/2", "0.5"), ("0.5", "0.5"), ("0,5", "0.5"), ("50%", "0.5"), (" 50 % ", "0.5"),
    ("1", "1"), ("100%", "1"), ("2/4", "0.5"), ("3/3", "1"), ("12,5%", "0.125"),
    ("1,5/3", "0.5"),
  ])
  func aShareCanBeTypedManyWays(_ text: String, _ expected: String) {
    #expect(DebtRules.parseShare(text) == Decimal(string: expected))
  }

  @Test func aThirdIsDividedExactly() throws {
    let third = try #require(DebtRules.parseShare(" 1 / 3 "))
    #expect(third == Decimal(1) / Decimal(3))
    #expect(try DebtRules.share(of: money(100), share: third) == money("33.3333"))
  }

  @Test(arguments: [
    "", " ", "0", "0/5", "1/0", "3/2", "1.5", "150%", "-1/2", "-0.5", "1/2/3", "half", "1/",
    "/2", "%", "50%%", "1//2",
  ])
  func notAShare(_ text: String) {
    #expect(DebtRules.parseShare(text) == nil)
  }
}
