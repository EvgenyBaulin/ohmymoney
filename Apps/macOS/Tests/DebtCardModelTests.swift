import AppCore
import XCTest

@testable import OhMyMoney

/// The facts a card of the debts overview shows, worked out without a window.
final class DebtCardModelTests: XCTestCase {
  private func line(_ debt: Debt, borrowed: Int64, balance: Int64) -> DebtLine {
    let entry = DebtEntry(
      debtId: debt.id, amountE4: AmountE4(raw: borrowed * 10_000), kind: .borrowed)
    return DebtLine(
      debt: debt, balance: AmountE4(raw: balance * 10_000), balanceRub: nil, groups: [],
      nextPayment: nil, paidThisMonth: false, entries: [entry])
  }

  func testBadgeNamesTheKindOfDebt() {
    let existing = Debt(direction: .iOwe, type: .loan, name: "Mortgage")
    let purchase = Debt(direction: .iOwe, type: .loan, name: "TV", origin: .purchase)
    let plan = Debt(
      direction: .iOwe, type: .installment, name: "Laptop", origin: .purchase, parts: 10)
    let closed = Debt(direction: .iOwe, type: .loan, name: "Old", closed: true)
    XCTAssertEqual(DebtCardModel.badge(of: existing), .existing)
    XCTAssertEqual(DebtCardModel.badge(of: purchase), .purchase)
    XCTAssertEqual(DebtCardModel.badge(of: plan), .instalment)
    XCTAssertEqual(DebtCardModel.badge(of: closed), .closed)
  }

  func testEveryBadgeHasASymbolAndAKeyOfItsOwn() {
    let badges: [DebtCardModel.Badge] = [.existing, .purchase, .instalment, .closed]
    XCTAssertEqual(Set(badges.map(\.symbol)).count, 4)
    XCTAssertEqual(Set(badges.map(\.key)).count, 4)
  }

  func testProgressIsThePaidShareOfWhatWasBorrowed() throws {
    let debt = Debt(direction: .iOwe, type: .loan, name: "Loan")
    let half = try XCTUnwrap(DebtCardModel.progress(of: line(debt, borrowed: 1_000, balance: 500)))
    XCTAssertEqual(half, 0.5, accuracy: 0.0001)
    let done = try XCTUnwrap(DebtCardModel.progress(of: line(debt, borrowed: 1_000, balance: 0)))
    XCTAssertEqual(done, 1, accuracy: 0.0001)
  }

  func testProgressIsClampedAndAbsentWithoutBorrowing() throws {
    let debt = Debt(direction: .iOwe, type: .loan, name: "Loan")
    let over = try XCTUnwrap(DebtCardModel.progress(of: line(debt, borrowed: 100, balance: 300)))
    XCTAssertEqual(over, 0, accuracy: 0.0001)
    let empty = DebtLine(
      debt: debt, balance: .zero, balanceRub: nil, groups: [], nextPayment: nil,
      paidThisMonth: false, entries: [])
    XCTAssertNil(DebtCardModel.progress(of: empty))
  }

  func testCardShowsRublesWhenThereAreSome() {
    let debt = Debt(direction: .iOwe, type: .loan, name: "USD loan", currency: .usd)
    var usd = line(debt, borrowed: 100, balance: 100)
    usd.balanceRub = AmountE4(raw: 9_000 * 10_000)
    let model = DebtCardModel(usd)
    XCTAssertEqual(model.currency, .rub)
    XCTAssertEqual(model.balance, AmountE4(raw: 9_000 * 10_000))
  }
}
