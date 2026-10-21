import CoreKit
import Foundation
import Testing

@testable import CoreAccounting

@Suite("Debts, credits and their journal")
struct DebtRulesTests {
  let categories = StartingCategories()

  @Test func plusGrowsTheDebtAndMinusReducesIt() {
    #expect(DebtRules.effect(of: .borrowed) == .increases)
    #expect(DebtRules.effect(of: .transferIn) == .increases)
    #expect(DebtRules.effect(of: .payment) == .decreases)
    #expect(DebtRules.effect(of: .offset) == .decreases)
    #expect(DebtRules.effect(of: .transferOut) == .decreases)
    #expect(DebtRules.effect(of: .adjustment) == .signed)

    #expect(DebtRules.signedAmount(money(100), for: .borrowed) == money(100))
    #expect(DebtRules.signedAmount(money(100), for: .payment) == money(-100))
    #expect(DebtRules.signedAmount(money(-100), for: .payment) == money(-100))
    #expect(DebtRules.signedAmount(money(-100), for: .adjustment) == money(-100))
  }

  @Test func theBalanceIsTheSumOfTheJournal() {
    let debtId = id(200)
    let journal = [
      DebtRules.makeEntry(debtId: debtId, kind: .borrowed, amountE4: money(500_000)),
      DebtRules.makeEntry(debtId: debtId, kind: .payment, amountE4: money(25000)),
      DebtRules.makeEntry(debtId: debtId, kind: .offset, amountE4: money(5000)),
      DebtRules.makeEntry(debtId: debtId, kind: .adjustment, amountE4: money(-300)),
    ]
    #expect(DebtRules.balance(entries: journal) == money(469_700))
    #expect(DebtRules.balance(of: debtId, entries: journal) == money(469_700))
    #expect(DebtRules.balance(of: id(999), entries: journal) == .zero)
  }

  @Test func groupsHaveTheirOwnTotalsInTheOrderTheyAppear() {
    let debtId = id(200)
    let journal = [
      DebtRules.makeEntry(
        debtId: debtId, kind: .borrowed, amountE4: money(100_000), groupName: "Renovation"),
      DebtRules.makeEntry(debtId: debtId, kind: .borrowed, amountE4: money(50000)),
      DebtRules.makeEntry(
        debtId: debtId, kind: .payment, amountE4: money(30000), groupName: "Renovation"),
      DebtRules.makeEntry(
        debtId: debtId, kind: .borrowed, amountE4: money(20000), groupName: "Car"),
    ]
    let totals = DebtRules.groupTotals(entries: journal)
    #expect(totals.map(\.groupName) == ["Renovation", nil, "Car"])
    #expect(totals[0].totalE4 == money(70000))
    #expect(totals[0].count == 2)
    #expect(totals[1].totalE4 == money(50000))
    #expect(totals[2].totalE4 == money(20000))
    #expect(AmountE4.sum(totals.map(\.totalE4)) == DebtRules.balance(entries: journal))
  }

  /// «Техника» and «Техника » are one group, and a group of spaces is none:
  /// the card showed two identical headers with two subtotals.
  @Test func aGroupIsNamedWithoutTheSpacesAroundIt() {
    let debtId = id(200)
    let journal = [
      DebtRules.makeEntry(
        debtId: debtId, kind: .borrowed, amountE4: money(100), groupName: "Техника",
        description: " TV "),
      DebtRules.makeEntry(
        debtId: debtId, kind: .borrowed, amountE4: money(50), groupName: "Техника ",
        description: "  ", note: " \n"),
      DebtRules.makeEntry(debtId: debtId, kind: .borrowed, amountE4: money(20), groupName: "   "),
    ]
    #expect(journal.map(\.groupName) == ["Техника", "Техника", nil])
    #expect(journal.map(\.description) == ["TV", nil, nil])
    #expect(journal[1].note == nil)
    let totals = DebtRules.groupTotals(entries: journal)
    #expect(totals.map(\.groupName) == ["Техника", nil])
    #expect(totals.first?.totalE4 == money(150))
  }

  @Test func aShareOfTheFullAmount() throws {
    let half = try DebtRules.share(
      of: money(1_000_000), share: Decimal(string: "0.5") ?? 0)
    #expect(half == money(500_000))
    let third = try DebtRules.share(of: money(100), share: Decimal(1) / Decimal(3))
    #expect(third == money("33.3333"))

    let entry = try DebtRules.makeShareEntry(
      debtId: id(200), fullAmountE4: money(1_000_000),
      share: Decimal(string: "0.5") ?? 0, description: "joint loan")
    #expect(entry.amountE4 == money(500_000))
    #expect(entry.fullAmountE4 == money(1_000_000))
  }

  @Test func aShareHasToBeAboveZeroAndAtMostTheWhole() {
    #expect(throws: DebtError.shareOutOfRange) {
      try DebtRules.share(of: money(1000), share: 0)
    }
    #expect(throws: DebtError.shareOutOfRange) {
      try DebtRules.share(of: money(1000), share: Decimal(string: "1.5") ?? 0)
    }
  }

  @Test func aPaymentOnADebtIAlreadyHadIsAnExpenseAndReducesTheBalance() throws {
    let debt = existingDebt(subcategory: categories.loansCar)
    let outcome = try DebtRules.payment(
      on: debt, amountE4: money(25000), date: day("2026-03-05"), transactionId: id(1))

    #expect(outcome.entry.amountE4 == money(-25000))
    #expect(outcome.entry.kind == .payment)
    #expect(outcome.entry.transactionId == id(1))
    #expect(outcome.isExpense)
    let expense = try #require(outcome.expense)
    #expect(expense.amountE4 == money(25000))
    #expect(expense.systemRole == .loans)
    #expect(expense.subcategoryId == categories.loansCar)
    #expect(expense.quality == .neutral)
    #expect(outcome.reducesBalanceByE4 == money(25000))
  }

  @Test func aPaymentOnSomethingBoughtInInstalmentsOnlyReducesTheBalance() throws {
    let debt = purchaseDebt()
    let outcome = try DebtRules.payment(on: debt, amountE4: money(10000))
    #expect(outcome.entry.amountE4 == money(-10000))
    #expect(outcome.expense == nil)
    #expect(outcome.isExpense == false)
  }

  @Test func aPaymentNeedsAnAmountAboveZero() {
    #expect(throws: DebtError.negativeAmount) {
      try DebtRules.payment(on: existingDebt(), amountE4: .zero)
    }
  }

  @Test func somethingBoughtInInstalmentsIsNeverCountedTwice() throws {
    let debt = purchaseDebt()
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
    let total = MyExpensesRule.total(entries: [purchase] + payments, debts: [debt.id: debt])
    #expect(total == money(120_000))

    let journal =
      [
        try DebtRules.creditPurchaseOpening(
          on: debt, amountE4: money(120_000), transactionId: id(1))
      ]
      + (try payments.map {
        try DebtRules.payment(on: debt, amountE4: money(60000), transactionId: $0.id).entry
      })
    #expect(DebtRules.balance(entries: journal) == .zero)
    #expect(DebtRules.purchaseIsExpense(on: debt))
    #expect(DebtRules.paymentIsExpense(on: debt) == false)
  }

  @Test func aDebtIAlreadyHadCountsItsPaymentsAndNothingElse() throws {
    let debt = existingDebt(subcategory: categories.loansCar)
    let payments = [
      entry(
        id(2), on: "2026-02-10", debtId: debt.id,
        parts: [part(id(21), amount: money(25000), category: categories.loansCar)]),
      entry(
        id(3), on: "2026-03-10", debtId: debt.id,
        parts: [part(id(31), amount: money(25000), category: categories.loansCar)]),
    ]
    #expect(MyExpensesRule.total(entries: payments, debts: [debt.id: debt]) == money(50000))
    #expect(DebtRules.purchaseIsExpense(on: debt) == false)
    #expect(DebtRules.paymentIsExpense(on: debt))
  }

  @Test func moneyComingBackOnADebtOwedToMeIsNeverMyExpense() throws {
    // A debt somebody owes me is created with the defaults of the model, and they say
    // «payments are expenses». On this side of the Debts section a payment is money
    // coming back to me, so it reduces the balance and nothing else: counting it as
    // spending in Loans would invent an expense out of money I received.
    let friend = Debt(id: id(210), direction: .owedToMe, type: .personal, name: "Friend")
    #expect(friend.paymentsAreExpenses)
    #expect(DebtRules.paymentIsExpense(on: friend) == false)

    let outcome = try DebtRules.payment(
      on: friend, amountE4: money(5000), transactionId: id(1))
    #expect(outcome.entry.amountE4 == money(-5000))
    #expect(outcome.expense == nil)
    #expect(outcome.reducesBalanceByE4 == money(5000))

    let recorded = entry(
      id(1), debtId: friend.id,
      parts: [part(id(11), amount: money(5000), category: categories.loansCar)])
    #expect(MyExpensesRule.total(entries: [recorded], debts: [friend.id: friend]) == .zero)
  }

  @Test func theDefaultOfPaymentsAreExpensesFollowsTheOrigin() {
    #expect(DebtRules.defaultPaymentsAreExpenses(for: .existing))
    #expect(DebtRules.defaultPaymentsAreExpenses(for: .purchase) == false)
  }

  @Test func anOffsetReducesTheDebtWithoutAPayment() throws {
    let debt = existingDebt()
    let offset = try DebtRules.offset(on: debt, amountE4: money(5000), date: day("2026-03-01"))
    #expect(offset.amountE4 == money(-5000))
    #expect(offset.kind == .offset)
  }

  @Test func transferringADebtClosesTheFirstAndOpensALineInTheSecond() throws {
    let source = existingDebt(id(200))
    let destination = Debt(
      id: id(210), direction: .iOwe, type: .personal, name: "Friend",
      paymentsAreExpenses: true, origin: .existing)
    let transfer = try DebtRules.transfer(
      from: source, to: destination, amountE4: money(100_000),
      sourceBalanceE4: money(100_000), date: day("2026-03-15"))

    #expect(transfer.out.debtId == source.id)
    #expect(transfer.out.kind == .transferOut)
    #expect(transfer.out.amountE4 == money(-100_000))
    #expect(transfer.into.debtId == destination.id)
    #expect(transfer.into.kind == .transferIn)
    #expect(transfer.into.amountE4 == money(100_000))
    #expect(transfer.closesSource)
    #expect((transfer.out.amountE4 + transfer.into.amountE4).isZero)

    let sourceJournal = [
      DebtRules.makeEntry(debtId: source.id, kind: .borrowed, amountE4: money(100_000)),
      transfer.out,
    ]
    #expect(DebtRules.balance(entries: sourceJournal).isZero)
    #expect(DebtRules.balance(entries: [transfer.into]) == money(100_000))
  }

  @Test func aPartialTransferLeavesTheSourceOpen() throws {
    let transfer = try DebtRules.transfer(
      from: existingDebt(id(200)), to: existingDebt(id(210)), amountE4: money(40000),
      sourceBalanceE4: money(100_000))
    #expect(transfer.closesSource == false)
  }

  /// «Igor» has 30 000 left and 50 000 is typed: the source would close with −20 000 on it,
  /// a closed debt showing money nobody will pay.
  @Test func aTransferOfMoreThanTheSourceHasIsRefused() throws {
    #expect(throws: DebtError.exceedsBalance) {
      try DebtRules.transfer(
        from: existingDebt(id(200)), to: existingDebt(id(210)), amountE4: money(120_000),
        sourceBalanceE4: money(100_000))
    }
    #expect(throws: DebtError.exceedsBalance) {
      try DebtRules.transfer(
        from: existingDebt(id(200)), to: existingDebt(id(210)), amountE4: money(1),
        sourceBalanceE4: .zero)
    }
    let all = try DebtRules.transfer(
      from: existingDebt(id(200)), to: existingDebt(id(210)), amountE4: money(100_000),
      sourceBalanceE4: money(100_000))
    #expect(all.closesSource)
  }

  @Test func aDebtCannotBeTransferredIntoItself() {
    let debt = existingDebt(id(200))
    #expect(throws: DebtError.sameDebt) {
      try DebtRules.transfer(from: debt, to: debt, amountE4: money(1000))
    }
  }

  @Test func theTwoListsHaveTheirOwnTotals() {
    let iOwe = existingDebt(id(200))
    let owedToMe = Debt(
      id: id(210), direction: .owedToMe, type: .personal, name: "Friend",
      paymentsAreExpenses: false, origin: .existing)
    let closed = Debt(
      id: id(220), direction: .iOwe, type: .loan, name: "Old loan", closed: true)
    let journal = [
      DebtRules.makeEntry(debtId: iOwe.id, kind: .borrowed, amountE4: money(500_000)),
      DebtRules.makeEntry(debtId: iOwe.id, kind: .payment, amountE4: money(100_000)),
      DebtRules.makeEntry(debtId: owedToMe.id, kind: .borrowed, amountE4: money(30000)),
      DebtRules.makeEntry(debtId: closed.id, kind: .borrowed, amountE4: money(900_000)),
    ]
    let totals = DebtRules.balances(debts: [iOwe, owedToMe, closed], entries: journal)
    #expect(totals[.iOwe] == money(400_000))
    #expect(totals[.owedToMe] == money(30000))
  }
}
