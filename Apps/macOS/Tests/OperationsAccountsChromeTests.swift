import AppCore
import XCTest

@testable import OhMyMoney

/// The pure parts of the redesigned «Операции» and account screens: what the quick filters
/// choose, the sign of an amount, the marks of the rows, and the words of an account's hero.
@MainActor
final class OperationsAccountsChromeTests: XCTestCase {
  private let today = DateOnly(year: 2026, month: 10, day: 22)
  private let money = MoneyFormatter(locale: Locale(identifier: "ru"))

  // MARK: Quick filters

  func testTheTypeChipsChooseTheTypeAndAllClearsIt() {
    var filters = TransactionFilters(today: today)
    XCTAssertTrue(OperationsQuickFilter.all.isActive(in: filters, today: today))

    OperationsQuickFilter.expenses.apply(to: &filters, tree: [], today: today)
    XCTAssertTrue(OperationsQuickFilter.expenses.isActive(in: filters, today: today))
    XCTAssertFalse(OperationsQuickFilter.all.isActive(in: filters, today: today))
    XCTAssertEqual(filters.entryFilter(today: today).kind, .expense)

    OperationsQuickFilter.income.apply(to: &filters, tree: [], today: today)
    XCTAssertEqual(filters.entryFilter(today: today).kind, .income)

    OperationsQuickFilter.all.apply(to: &filters, tree: [], today: today)
    XCTAssertNil(filters.entryFilter(today: today).kind)
    XCTAssertFalse(filters.canReset, "«Все» leaves nothing for «Сбросить»")
  }

  func testTodayTurnsTheDayOnAndOff() {
    var filters = TransactionFilters(today: today)
    OperationsQuickFilter.today.apply(to: &filters, tree: [], today: today)
    XCTAssertTrue(OperationsQuickFilter.today.isActive(in: filters, today: today))
    XCTAssertEqual(filters.period(today: today), .days(DayRange(today, today)))
    XCTAssertEqual(filters.activeCount, 1)

    OperationsQuickFilter.today.apply(to: &filters, tree: [], today: today)
    XCTAssertFalse(OperationsQuickFilter.today.isActive(in: filters, today: today))
    XCTAssertNil(filters.period(today: today), "pressed again: the whole history")
  }

  func testTodayAndATypeWorkTogether() {
    var filters = TransactionFilters(today: today)
    OperationsQuickFilter.income.apply(to: &filters, tree: [], today: today)
    OperationsQuickFilter.today.apply(to: &filters, tree: [], today: today)
    XCTAssertTrue(OperationsQuickFilter.income.isActive(in: filters, today: today))
    XCTAssertTrue(OperationsQuickFilter.today.isActive(in: filters, today: today))
    XCTAssertEqual(filters.activeCount, 2)
  }

  func testEveryChipHasAWordInBothLanguages() {
    let language = AppLanguage()
    for choice in [AppLanguage.Choice.english, .russian] {
      language.choice = choice
      for chip in OperationsQuickFilter.allCases {
        XCTAssertNotEqual(
          language(chip.titleKey, table: "Transactions"), chip.titleKey,
          "\(chip) has no text in \(choice)")
      }
    }
  }

  // MARK: Rows

  func testTheSignOfAnAmountSaysTheDirection() {
    func sign(_ kind: TransactionKind, transfer: Bool = false, part: Bool = false) -> String {
      OperationAmountSign.prefix(kind: kind, isTransfer: transfer, isPart: part)
    }
    XCTAssertEqual(sign(.expense), "\u{2212}")
    XCTAssertEqual(sign(.income), "+")
    XCTAssertEqual(sign(.refund), "+")
    XCTAssertEqual(sign(.reimbursement), "+")
    XCTAssertEqual(sign(.expense, transfer: true), "", "a transfer is neither")
    XCTAssertEqual(sign(.expense, part: true), "", "a part has no sign of its own")
  }

  func testEveryKindOfRowHasItsOwnSymbol() {
    let kinds: [OperationBadgeKind] = [.income, .expense, .refund, .moneyBack, .transfer]
    XCTAssertEqual(Set(kinds.map(\.symbol)).count, kinds.count)
  }

  func testTheSecondLineOfARowNamesCategoryAndAccountOrTheTwoAccounts() {
    XCTAssertEqual(
      OperationRowCaption.text(category: "Кафе", account: "Т-Банк", transfer: nil),
      "Кафе \u{00B7} Т-Банк")
    XCTAssertEqual(
      OperationRowCaption.text(category: nil, account: "Т-Банк", transfer: nil), "Т-Банк")
    XCTAssertEqual(
      OperationRowCaption.text(category: "Кафе", account: "Сбер", transfer: "Сбер → Kaspi"),
      "Сбер → Kaspi", "a transfer says its two accounts, not a category")
    XCTAssertNil(OperationRowCaption.text(category: nil, account: nil, transfer: nil))
  }

  // MARK: The hero of an account

  private var words: AccountHero.Words {
    AccountHero.Words(
      kind: "card", countedAt: { _ in "counted" }, notCounted: "not counted yet",
      main: "main", cushion: "cushion")
  }

  private func line(
    _ account: PaymentMethod, _ keys: [AccountsSnapshot.KeyLine], total: AmountE4? = nil
  ) -> AccountsSnapshot.AccountLine {
    AccountsSnapshot.AccountLine(account: account, keys: keys, totalRub: total, unknown: 0)
  }

  private func key(
    _ account: PaymentMethod, _ currency: CurrencyCode, _ whole: Int64?, at: Date? = nil
  ) -> AccountsSnapshot.KeyLine {
    AccountsSnapshot.KeyLine(
      key: BalanceKey(accountId: account.id, currency: currency),
      balance: whole.map { AmountE4(whole: $0) }, rub: whole.map { AmountE4(whole: $0) },
      anchorAt: at, isHeld: true)
  }

  func testTheHeroOfOneCurrencyShowsItsExactBalanceAndWhenItWasCounted() {
    let account = PaymentMethod(name: "Т-Банк Black", currency: .rub, isDefault: true)
    let hero = AccountHero.make(
      line: line(account, [key(account, .rub, 342_800, at: Date())]), words: words, money: money)
    XCTAssertEqual(hero.caption, "Т-Банк Black \u{00B7} card")
    XCTAssertEqual(hero.figure, money.exact(AmountE4(whole: 342_800), currency: .rub))
    XCTAssertEqual(hero.lines, ["counted", "main"])
  }

  func testTheHeroOfSeveralCurrenciesShowsTheTotalInRubles() {
    let account = PaymentMethod(name: "Freedom", currency: .rub)
    let hero = AccountHero.make(
      line: line(
        account, [key(account, .rub, 1_000), key(account, CurrencyCode("KZT"), 5_000)],
        total: AmountE4(whole: 1_500)),
      words: words, money: money)
    XCTAssertEqual(hero.figure, "\u{2248}\u{00A0}" + money.rounded(AmountE4(whole: 1_500)))
  }

  func testTheHeroOfAnAccountNeverCountedSaysSo() {
    let account = PaymentMethod(name: "Наличные", currency: .rub)
    let hero = AccountHero.make(
      line: line(account, [key(account, .rub, nil)]), words: words, money: money)
    XCTAssertEqual(hero.figure, "\u{2014}")
    XCTAssertEqual(hero.lines, ["not counted yet"])
  }
}
