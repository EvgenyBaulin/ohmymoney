import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// A debt from its first line to its deletion through the actions of the Debts section: made,
/// paid, offset, grown, adjusted, moved to another debt, closed, reopened and deleted — each
/// write one step of ⌘Z, each refusal writing nothing, in rubles and in dollars.
@MainActor
final class DebtsScenarioTestsLifecycle: DebtsScenarioCase {
  // MARK: Made

  func testALoanWhosePaymentsAreExpensesGetsItsLoansSubcategoryAndUndoTakesBoth() async throws {
    let loan = try await makeLoan(name: "Mortgage")
    let sub = try XCTUnwrap(loan.loansSubcategoryId)
    let category = try XCTUnwrap(try categories().first { $0.id == sub })
    XCTAssertEqual(category.parentId, loans.id)
    XCTAssertEqual(category.name, "Mortgage")
    try await undo()
    XCTAssertTrue(try debts().isEmpty)
    XCTAssertFalse(try categories().contains { $0.id == sub && !$0.archived })
  }

  func testADebtOwedToMeGetsNoLoansSubcategory() async throws {
    let lent = try await makeOwedToMe()
    XCTAssertNil(lent.loansSubcategoryId)
    XCTAssertFalse(try categories().contains { $0.parentId == loans.id })
  }

  func testAnOldDebtStartsWithAnAdjustmentNotMoneyThatCameIn() async throws {
    let loan = try await makeLoan(owed: 70_000)
    let lines = try journal(loan.id)
    XCTAssertEqual(lines.map(\.kind), [.adjustment])
    XCTAssertEqual(lines.first?.amountE4, money(70_000))
    XCTAssertEqual(lines.first?.date, today.adding(days: -40))
    XCTAssertNil(lines.first?.paymentMethodId)
  }

  func testADebtOwingNothingIsWrittenWithoutALine() async throws {
    let debt = Debt(direction: .iOwe, type: .personal, name: "Nothing yet")
    XCTAssertTrue(actions.create(debt, balance: .zero, on: today, moneyMovedNow: false))
    try await show()
    XCTAssertEqual(try journal(debt.id), [])
    XCTAssertEqual(try line(debt.id)?.balance, .zero)
  }

  func testMoneyBorrowedNowIsALineOfCashOnTheChosenAccount() async throws {
    let debt = Debt(direction: .iOwe, type: .personal, name: "Brother")
    XCTAssertTrue(
      actions.create(
        debt, balance: money(3_000), on: today, moneyMovedNow: true, account: cash.id,
        at: noon(today)))
    let line = try XCTUnwrap(try journal(debt.id).first)
    XCTAssertEqual(line.kind, .borrowed)
    XCTAssertEqual(line.paymentMethodId, cash.id)
    XCTAssertEqual(line.occurredAt, noon(today))
    XCTAssertNil(line.accountCurrency, "rubles on a ruble account")
  }

  func testMoneyBorrowedOnAnArchivedAccountLandsOnTheMainOne() async throws {
    var old = PaymentMethod(name: "Old", currency: .rub)
    old.archived = true
    try XCTUnwrap(environment.references).save(old)
    try await show()
    let debt = Debt(direction: .iOwe, type: .personal, name: "Sister")
    XCTAssertTrue(
      actions.create(
        debt, balance: money(1_000), on: today, moneyMovedNow: true, account: old.id,
        at: noon(today)))
    XCTAssertEqual(try journal(debt.id).first?.paymentMethodId, card.id)
  }

  func testDollarsBorrowedOntoARubleCardCarryTheRublesOfTheDay() async throws {
    let debt = Debt(direction: .iOwe, type: .personal, name: "Friend", currency: .usd)
    XCTAssertTrue(
      actions.create(
        debt, balance: money(100), on: today, moneyMovedNow: true, account: card.id,
        at: noon(today)))
    let line = try XCTUnwrap(try journal(debt.id).first)
    XCTAssertEqual(line.amountE4, money(100), "the debt stays in dollars")
    XCTAssertEqual(line.accountCurrency, .rub)
    XCTAssertEqual(line.accountAmountE4, money(9_000))
  }

  func testDollarsBorrowedOntoTheDollarWalletNeedNoRubles() async throws {
    let debt = Debt(direction: .iOwe, type: .personal, name: "Friend", currency: .usd)
    XCTAssertTrue(
      actions.create(
        debt, balance: money(100), on: today, moneyMovedNow: true, account: wallet.id,
        at: noon(today)))
    let line = try XCTUnwrap(try journal(debt.id).first)
    XCTAssertEqual(line.paymentMethodId, wallet.id)
    XCTAssertNil(line.accountCurrency)
    XCTAssertNil(line.accountAmountE4)
  }

  func testDollarsTypedByHandWinOverTheRateOfTheDay() async throws {
    let debt = Debt(direction: .iOwe, type: .personal, name: "Friend", currency: .usd)
    XCTAssertTrue(
      actions.create(
        debt, balance: money(100), on: today, moneyMovedNow: true, account: card.id,
        charged: Money(amount: money(9_250), currency: .rub), at: noon(today)))
    XCTAssertEqual(try journal(debt.id).first?.accountAmountE4, money(9_250))
  }

  func testANewDebtIsMadeWithItsTermsSeen() async throws {
    let loan = try await makeLoan()
    XCTAssertTrue(loan.termsReviewed)
    XCTAssertEqual(try snapshot.planning.debtReview, [])
  }

  // MARK: Paid

  func testAPaymentOfALoanIsAnExpenseInItsOwnSubcategory() async throws {
    let loan = try await makeLoan()
    let done = try await pay(loan, 10_000)
    XCTAssertTrue(done)
    let payment = try XCTUnwrap(try payments(of: loan.id).first)
    XCTAssertEqual(payment.transaction.kind, .expense)
    XCTAssertEqual(payment.parts.first?.categoryId, loan.loansSubcategoryId)
    XCTAssertEqual(payment.transaction.paymentMethodId, card.id)
    XCTAssertEqual(try balance(loan.id), money(90_000))
    try await undo()
    XCTAssertEqual(try payments(of: loan.id), [])
    XCTAssertEqual(try balance(loan.id), money(100_000))
  }

  func testTwoPaymentsOfOneDayAreTwoLinesAndTwoSteps() async throws {
    let loan = try await makeLoan()
    try await pay(loan, 4_000)
    try await pay(loan, 6_000)
    XCTAssertEqual(try payments(of: loan.id).count, 2)
    XCTAssertEqual(try balance(loan.id), money(90_000))
    try await undo()
    XCTAssertEqual(try balance(loan.id), money(96_000))
    try await undo()
    XCTAssertEqual(try balance(loan.id), money(100_000))
  }

  func testAPaymentOfNothingWritesNothing() async throws {
    let loan = try await makeLoan()
    let done = try await pay(loan, 0)
    XCTAssertFalse(done)
    XCTAssertEqual(try payments(of: loan.id), [])
    XCTAssertEqual(try journal(loan.id).count, 1)
  }

  func testAPaymentFromAnArchivedAccountIsTakenFromTheMainOne() async throws {
    var old = PaymentMethod(name: "Old", currency: .rub)
    old.archived = true
    try XCTUnwrap(environment.references).save(old)
    let loan = try await makeLoan()
    try await pay(loan, 1_000, account: old.id)
    XCTAssertEqual(try payments(of: loan.id).first?.transaction.paymentMethodId, card.id)
  }

  func testAPaymentOfADebtNotSpentLowersItWithoutMyExpense() async throws {
    let loan = try await makeLoan(expenses: false)
    XCTAssertNil(loan.loansSubcategoryId)
    try await pay(loan, 10_000)
    let payment = try XCTUnwrap(try payments(of: loan.id).first)
    XCTAssertEqual(payment.transaction.kind, .expense, "money left the card all the same")
    XCTAssertFalse(DebtRules.paymentIsExpense(on: loan))
    XCTAssertEqual(try balance(loan.id), money(90_000))
  }

  func testADollarLoanPaidFromTheDollarWallet() async throws {
    let loan = try await makeLoan(owed: 1_000, monthly: 100, currency: .usd)
    try await pay(loan, 100, account: wallet.id)
    let payment = try XCTUnwrap(try payments(of: loan.id).first)
    XCTAssertEqual(payment.transaction.currency, .usd)
    XCTAssertEqual(payment.transaction.paymentMethodId, wallet.id)
    XCTAssertEqual(try balance(loan.id), money(900))
  }

  func testAPaymentThatPaysOffExactlyClosesTheDebtAndUndoOpensIt() async throws {
    let loan = try await makeLoan(owed: 10_000)
    try await pay(loan, 10_000, closing: true)
    XCTAssertTrue(try debt(loan.id).closed)
    XCTAssertEqual(try balance(loan.id), .zero)
    XCTAssertTrue(try snapshot.planning.debts.closed.contains { $0.id == loan.id })
    try await undo()
    XCTAssertFalse(try debt(loan.id).closed)
    XCTAssertEqual(try balance(loan.id), money(10_000))
  }

  func testAPaymentAboveWhatIsLeftClosesAtZeroNotBelow() async throws {
    let loan = try await makeLoan(owed: 10_000)
    try await pay(loan, 12_000, closing: true)
    XCTAssertTrue(try debt(loan.id).closed)
    XCTAssertEqual(try balance(loan.id), .zero, "what was paid over is written off")
    XCTAssertEqual(try payments(of: loan.id).first?.transaction.amountE4, money(12_000))
  }

  func testAClosedDebtTakesNoPaymentAtAll() async throws {
    let loan = try await makeLoan(owed: 10_000)
    try await pay(loan, 10_000, closing: true)
    let done = try await pay(loan, 1_000)
    XCTAssertFalse(done)
    XCTAssertEqual(try payments(of: loan.id).count, 1)
  }

  // MARK: Grown, offset, adjusted

  func testTheDebtGrowsWithoutMoneyAndUndoTakesItBack() async throws {
    let loan = try await makeLoan()
    XCTAssertTrue(
      actions.addEntry(
        loan, amount: money(1_500), fullAmount: nil, share: nil, on: today, group: nil,
        description: "Fine", moneyMoved: false))
    let line = try XCTUnwrap(try journal(loan.id).last)
    XCTAssertEqual(line.kind, .adjustment)
    XCTAssertEqual(line.description, "Fine")
    XCTAssertEqual(try balance(loan.id), money(101_500))
    try await undo()
    XCTAssertEqual(try balance(loan.id), money(100_000))
  }

  func testHalfOfACommonBillIsHalfOfIt() async throws {
    let debt = try await makeOwedToMe(owed: 1_000)
    XCTAssertTrue(
      actions.addEntry(
        debt, amount: .zero, fullAmount: money(1_000_000), share: Decimal(1) / 2, on: today,
        group: "Flat", description: nil, moneyMoved: false))
    let line = try XCTUnwrap(try journal(debt.id).last)
    XCTAssertEqual(line.amountE4, money(500_000))
    XCTAssertEqual(line.groupName, "Flat")
    XCTAssertEqual(try balance(debt.id), money(501_000))
  }

  func testMoneyBorrowedLaterIsALineOnTheAccount() async throws {
    let debt = try await makeOwedToMe(owed: 1_000)
    XCTAssertTrue(
      actions.addEntry(
        debt, amount: money(2_000), fullAmount: nil, share: nil, on: today, group: nil,
        description: nil, moneyMoved: true, account: cash.id))
    let line = try XCTUnwrap(try journal(debt.id).last)
    XCTAssertEqual(line.kind, .borrowed)
    XCTAssertEqual(line.paymentMethodId, cash.id)
    XCTAssertEqual(line.occurredAt, noon(today))
  }

  func testAGrowthOfNothingIsRefused() async throws {
    let loan = try await makeLoan()
    XCTAssertFalse(
      actions.addEntry(
        loan, amount: .zero, fullAmount: nil, share: nil, on: today, group: nil,
        description: nil, moneyMoved: false))
    XCTAssertFalse(
      actions.addEntry(
        loan, amount: .zero, fullAmount: nil, share: nil, on: today, group: nil,
        description: nil, moneyMoved: true))
    XCTAssertEqual(try journal(loan.id).count, 1)
  }

  func testAnOffsetIsMyOperationAndLowersTheDebt() async throws {
    let loan = try await makeLoan()
    XCTAssertTrue(
      actions.offset(loan, amount: money(2_000), on: noon(today), description: "Paid his bill"))
    let operation = try XCTUnwrap(try payments(of: loan.id).first)
    XCTAssertEqual(operation.transaction.note, "Paid his bill")
    XCTAssertEqual(try journal(loan.id).last?.kind, .offset)
    XCTAssertEqual(try balance(loan.id), money(98_000))
    try await undo()
    XCTAssertEqual(try payments(of: loan.id), [])
    XCTAssertEqual(try balance(loan.id), money(100_000))
  }

  func testAnAdjustmentDownAndUpEachOneStep() async throws {
    let loan = try await makeLoan()
    XCTAssertTrue(
      actions.adjust(loan, from: money(100_000), to: money(95_000), on: today, note: nil))
    XCTAssertEqual(try balance(loan.id), money(95_000))
    XCTAssertTrue(
      actions.adjust(loan, from: money(95_000), to: money(97_500), on: today, note: "x"))
    XCTAssertEqual(try balance(loan.id), money(97_500))
    try await undo()
    XCTAssertEqual(try balance(loan.id), money(95_000))
    try await undo()
    XCTAssertEqual(try balance(loan.id), money(100_000))
  }

  func testAnAdjustmentToTheSameBalanceWritesNothing() async throws {
    let loan = try await makeLoan()
    XCTAssertFalse(
      actions.adjust(loan, from: money(100_000), to: money(100_000), on: today, note: nil))
    XCTAssertEqual(try journal(loan.id).count, 1)
  }

  func testAnAdjustmentToZeroLeavesTheDebtOpen() async throws {
    let loan = try await makeLoan()
    XCTAssertTrue(actions.adjust(loan, from: money(100_000), to: .zero, on: today, note: nil))
    XCTAssertEqual(try balance(loan.id), .zero)
    XCTAssertFalse(try debt(loan.id).closed, "only «Закрыть» closes")
  }

  // MARK: Moved, closed, reopened

  func testAPartOfADebtMovedToAnotherLeavesTheFirstOpen() async throws {
    let first = try await makeLoan(name: "First", owed: 10_000)
    let second = try await makeLoan(name: "Second", owed: 5_000)
    XCTAssertTrue(
      actions.transfer(first, balance: money(10_000), to: second, amount: money(4_000), on: today))
    XCTAssertEqual(try balance(first.id), money(6_000))
    XCTAssertEqual(try balance(second.id), money(9_000))
    XCTAssertFalse(try debt(first.id).closed)
    try await undo()
    XCTAssertEqual(try balance(first.id), money(10_000))
    XCTAssertEqual(try balance(second.id), money(5_000))
  }

  func testNothingMovesIntoAClosedDebt() async throws {
    let first = try await makeLoan(name: "First", owed: 10_000)
    let second = try await makeLoan(name: "Second", owed: 5_000)
    XCTAssertTrue(actions.close(second, balance: money(5_000), writeOff: true, on: today))
    try await show()
    XCTAssertFalse(
      actions.transfer(
        first, balance: money(10_000), to: try debt(second.id), amount: money(1_000), on: today))
    XCTAssertEqual(try balance(first.id), money(10_000))
  }

  func testClosingWithoutAWriteOffKeepsTheMoneyInTheJournal() async throws {
    let loan = try await makeLoan(owed: 8_000)
    XCTAssertTrue(actions.close(loan, balance: money(8_000), writeOff: false, on: today))
    XCTAssertTrue(try debt(loan.id).closed)
    XCTAssertEqual(try balance(loan.id), money(8_000))
    try await show()
    XCTAssertFalse(try snapshot.planning.debts.iOwe.contains { $0.id == loan.id })
  }

  func testAClosedDebtIsNotClosedTwice() async throws {
    let loan = try await makeLoan(owed: 8_000)
    XCTAssertTrue(actions.close(loan, balance: money(8_000), writeOff: true, on: today))
    XCTAssertFalse(actions.close(try debt(loan.id), balance: .zero, writeOff: true, on: today))
    XCTAssertEqual(try journal(loan.id).count, 2)
  }

  func testReopeningKeepsTheWriteOffAndUndoClosesAgain() async throws {
    let loan = try await makeLoan(owed: 8_000)
    XCTAssertTrue(actions.close(loan, balance: money(8_000), writeOff: true, on: today))
    XCTAssertTrue(actions.reopen(try debt(loan.id)))
    XCTAssertFalse(try debt(loan.id).closed)
    XCTAssertEqual(try balance(loan.id), .zero, "the write-off stays in the journal")
    try await undo()
    XCTAssertTrue(try debt(loan.id).closed)
  }

  func testAnOpenDebtIsNotReopened() async throws {
    let loan = try await makeLoan()
    XCTAssertFalse(actions.reopen(loan))
  }

  // MARK: Deleted

  func testADeletedDebtLeavesEveryListAndItsSubcategoryGoesToTheArchive() async throws {
    let loan = try await makeLoan(name: "Car")
    try await pay(loan, 10_000)
    XCTAssertTrue(actions.delete(try debt(loan.id), at: noon(today)))
    try await show()
    XCTAssertNil(try line(loan.id))
    XCTAssertNotNil(try debt(loan.id).deletedAt)
    let sub = try XCTUnwrap(try categories().first { $0.id == loan.loansSubcategoryId })
    XCTAssertTrue(sub.archived)
    XCTAssertEqual(try payments(of: loan.id).count, 1, "its payment counts as it did")
    try await undo()
    XCTAssertNotNil(try line(loan.id))
    XCTAssertFalse(try categories().first { $0.id == loan.loansSubcategoryId }?.archived ?? true)
  }

  func testADeletedDebtIsNotDeletedTwice() async throws {
    let loan = try await makeLoan()
    XCTAssertTrue(actions.delete(loan, at: noon(today)))
    try await show()
    XCTAssertFalse(actions.delete(try debt(loan.id), at: noon(today)))
  }

  func testDeletingADebtOwedToMeWithMoneyLeftWarnsOfIncomeLater() async throws {
    let lent = try await makeOwedToMe(owed: 2_000)
    let deletion = DebtActions.deletion(of: lent, snapshot: try snapshot, at: noon(today))
    XCTAssertTrue(deletion.warnsOfIncomeLater)
    XCTAssertEqual(deletion.balance, money(2_000))
    let loan = try await makeLoan()
    XCTAssertFalse(
      DebtActions.deletion(of: loan, snapshot: try snapshot, at: noon(today)).warnsOfIncomeLater)
  }

  // MARK: Owed to me

  func testMoneyBackOnADebtOwedToMeIsAReimbursementOfMine() async throws {
    let lent = try await makeOwedToMe(owed: 5_000)
    try await pay(lent, 2_000)
    let back = try XCTUnwrap(try payments(of: lent.id).first)
    XCTAssertEqual(back.transaction.kind, .reimbursement)
    XCTAssertEqual(try balance(lent.id), money(3_000))
    XCTAssertFalse(try debt(lent.id).closed)
  }

  func testMoneyBackAboveTheDebtIsIncomeInSurchargesAndUndoTakesBoth() async throws {
    let lent = try await makeOwedToMe(owed: 5_000)
    try await pay(lent, 6_000, closing: true)
    XCTAssertTrue(try debt(lent.id).closed)
    XCTAssertEqual(try balance(lent.id), .zero)
    let income = try entries().filter { $0.transaction.kind == .income }
    XCTAssertEqual(income.map(\.transaction.amountE4), [money(1_000)])
    try await undo()
    XCTAssertEqual(try entries(), [])
    XCTAssertFalse(try debt(lent.id).closed)
  }

  func testAllOfItBackClosesADebtOwedToMe() async throws {
    let lent = try await makeOwedToMe(owed: 5_000)
    try await pay(lent, 5_000, closing: true)
    XCTAssertTrue(try debt(lent.id).closed)
    XCTAssertTrue(try entries().allSatisfy { $0.transaction.kind == .reimbursement })
  }

  // MARK: The totals of the section

  func testTheTotalsCountDollarsAtTheRateOfToday() async throws {
    try await makeLoan(name: "Rubles", owed: 10_000, monthly: 1_000)
    try await makeLoan(name: "Dollars", owed: 100, monthly: 10, currency: .usd)
    let overview = try snapshot.planning.debts
    XCTAssertEqual(overview.totalIOweRub, money(19_000))
    XCTAssertEqual(overview.monthlyPaymentsRub, money(1_900))
    XCTAssertEqual(overview.withoutRate, [])
  }

  func testADebtInACurrencyWithoutARateIsNamedNotGuessed() async throws {
    let euros = try await makeLoan(name: "Euros", owed: 100, monthly: 10, currency: .eur)
    let overview = try snapshot.planning.debts
    XCTAssertEqual(overview.withoutRate, [euros.id])
    XCTAssertEqual(overview.totalIOweRub, .zero)
  }
}
