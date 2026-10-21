import AppCore
import XCTest

@testable import OhMyMoney

/// The field «Кэшбэк» of the ↓ panel at the level of its state: what a typed amount or percent
/// saves, that an unreadable figure saves nothing and stops nothing, and what «Запомнить» may
/// write.
@MainActor
final class CashbackFieldStateTests: XCTestCase {
  private let account = UUID()
  private let black = UUID()
  private let pharmacy = UUID()
  private let september = MonthKey(year: 2026, month: 9)

  private func draft(amount: Int64 = 1_000) -> TransactionDraft {
    TransactionDraft(
      amount: AmountE4(whole: amount), paymentMethodId: account,
      parts: [PartDraft(categoryId: pharmacy, amount: AmountE4(whole: amount))], cardId: black)
  }

  private func context(
    holder: CashbackHolder? = nil, category: UUID? = nil, mixed: Bool = false,
    own: [CashbackRule] = []
  ) -> CashbackFieldContext {
    CashbackFieldContext(
      holder: holder ?? .card(black), holderName: "Black", month: september,
      categoryId: category ?? pharmacy, accountId: account, movedCurrency: .rub,
      mixedCategories: mixed, ownRules: own)
  }

  private func ownRule(month: MonthKey?) -> CashbackRule {
    CashbackRule(
      accountId: account, cardId: black, categoryId: pharmacy, month: month,
      percent: CashbackPercent(e4: 30_000)!)
  }

  func testATypedAmountIsSavedInTheMovedCurrency() {
    let state = CashbackFieldState(text: "40")
    XCTAssertEqual(
      state.value(on: draft()), Money(amount: AmountE4(whole: 40), currency: .rub))
    var dollars = draft(amount: 20)
    dollars.currency = .usd
    dollars.accountCurrency = .rub
    dollars.accountAmount = AmountE4(whole: 1_850)
    XCTAssertEqual(
      state.value(on: dollars), Money(amount: AmountE4(whole: 40), currency: .rub),
      "the figure is in the money the account moved")
  }

  /// «7%» on 1,000.00 ₽ saves 70.00 ₽ for this operation.
  func testATypedPercentIsSavedAsAnAmount() throws {
    let state = CashbackFieldState(text: "7%")
    XCTAssertEqual(state.value(on: draft()), Money(amount: AmountE4(whole: 70), currency: .rub))
    XCTAssertEqual(state.typedPercent, CashbackPercent(e4: 70_000))
  }

  /// A typed percent is turned into money the way the account's bank rounds: 7 % of 1,000.50 is
  /// 70.035.
  func testATypedPercentFollowsTheRoundingOfTheAccount() {
    let state = CashbackFieldState(text: "7%")
    var cheque = draft()
    cheque.amount = AmountE4(raw: 10_005_000)
    cheque.parts[0].amount = cheque.amount
    XCTAssertEqual(
      state.value(on: cheque), Money(amount: AmountE4(whole: 70), currency: .rub),
      "a new account rounds to whole rubles")
    XCTAssertEqual(
      state.value(on: cheque, rounding: CashbackRounding(precision: .cents)),
      Money(amount: AmountE4(raw: 700_400), currency: .rub))
    XCTAssertEqual(
      state.value(on: cheque, rounding: CashbackRounding(precision: .whole, direction: .up)),
      Money(amount: AmountE4(whole: 71), currency: .rub))
  }

  func testAnUnreadableFieldSavesNothingAndAnEmptyOneToo() {
    for text in ["abc", "150%", "1.23456%", "-3", "", "  "] {
      XCTAssertNil(CashbackFieldState(text: text).value(on: draft()), text)
    }
    XCTAssertEqual(CashbackFieldState(text: "abc").input, .unreadable(.malformed))
  }

  /// The rule written is the account's: the card follows it.
  func testRememberWritesAlwaysOrTheMonthOnTheAccount() throws {
    let seven = try XCTUnwrap(CashbackPercent(e4: 70_000))
    let always = try XCTUnwrap(context().rule(seven, onlyThisMonth: false))
    XCTAssertNil(always.cardId, "Black keeps no rule of its own here")
    XCTAssertEqual(always.accountId, account)
    XCTAssertEqual(always.categoryId, pharmacy)
    XCTAssertNil(always.month)
    let month = try XCTUnwrap(context().rule(seven, onlyThisMonth: true))
    XCTAssertEqual(month.month, september)
    XCTAssertNil(month.cardId)
    let own = try XCTUnwrap(
      context(holder: .account(account)).rule(seven, onlyThisMonth: false))
    XCTAssertNil(own.cardId)
  }

  /// Where the card already differs from its account for the month and category, its own rule
  /// is the one that changes: the account's would be hidden behind it. Only for that key.
  func testRememberChangesTheCardsOwnRuleWhereItDiffers() throws {
    let seven = try XCTUnwrap(CashbackPercent(e4: 70_000))
    let withMonth = context(own: [ownRule(month: september)])
    XCTAssertEqual(try XCTUnwrap(withMonth.rule(seven, onlyThisMonth: true)).cardId, black)
    XCTAssertNil(
      try XCTUnwrap(withMonth.rule(seven, onlyThisMonth: false)).cardId,
      "its rule is of the month only: «always» is the account's")
    let always = context(own: [ownRule(month: nil)])
    XCTAssertEqual(try XCTUnwrap(always.rule(seven, onlyThisMonth: false)).cardId, black)
    XCTAssertNil(try XCTUnwrap(always.rule(seven, onlyThisMonth: true)).cardId)
  }

  func testRememberIsOffForMixedCategoriesNoCategoryOrNoAccount() {
    let seven = CashbackPercent(e4: 70_000)!
    XCTAssertNil(context().rememberRefusalKey)
    XCTAssertEqual(context(mixed: true).rememberRefusalKey, "entry.cashback.rememberSplit")
    XCTAssertNil(context(mixed: true).rule(seven, onlyThisMonth: false))
    var noCategory = context()
    noCategory.categoryId = nil
    XCTAssertEqual(noCategory.rememberRefusalKey, "entry.cashback.rememberNoCategory")
  }

  /// A card whose account the context does not know: no rule can be written for it, so
  /// «Запомнить» is off and says why instead of doing nothing.
  func testRememberIsOffWhenTheCardHasNoAccount() {
    var noAccount = context()
    noAccount.accountId = nil
    XCTAssertNil(noAccount.rule(CashbackPercent(e4: 70_000)!, onlyThisMonth: false))
    XCTAssertEqual(noAccount.rememberRefusalKey, "entry.cashback.noAccount")
    var ownRules = context(holder: .account(account))
    ownRules.accountId = nil
    XCTAssertNil(ownRules.rememberRefusalKey, "an account's own rule names its account")
    XCTAssertNotNil(ownRules.rule(CashbackPercent(e4: 70_000)!, onlyThisMonth: false))
  }

  /// An operation opened again with the 120 ₽ the owner typed: the field shows the figure, and a
  /// save of any other change keeps it.
  func testAKeptFigureIsSavedAgain() {
    let typed = Money(amount: AmountE4(whole: 120), currency: .rub)
    var opened = draft()
    opened.cashback = typed
    let state = CashbackFieldState(kept: opened.cashback, on: opened)
    XCTAssertEqual(state.input, .amount(AmountE4(whole: 120)))
    XCTAssertEqual(state.value(on: opened), typed)
    let exact = Money(amount: AmountE4(raw: 123_456), currency: .rub)
    XCTAssertEqual(CashbackFieldState(kept: exact).value(on: opened), exact, "every digit kept")
    XCTAssertEqual(
      CashbackFieldState(kept: Money(amount: AmountE4(whole: 1_500), currency: .rub))
        .value(on: opened), Money(amount: AmountE4(whole: 1_500), currency: .rub))
    XCTAssertEqual(CashbackFieldState(kept: nil).text, "")
    XCTAssertNil(CashbackFieldState(kept: nil).value(on: opened))
    // A figure in money the account no longer moves says nothing about the operation.
    let tenge = Money(amount: AmountE4(whole: 100), currency: CurrencyCode("KZT"))
    XCTAssertEqual(CashbackFieldState(kept: tenge, on: opened).text, "")
  }
}
