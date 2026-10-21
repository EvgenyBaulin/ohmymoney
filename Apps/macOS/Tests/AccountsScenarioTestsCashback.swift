import AppCore
import XCTest

@testable import OhMyMoney

/// Cashback as the owner sets it up for one account and lives through a few months with it: how
/// the bank rounds, when it pays («сразу», «до N-го» at the ends of months, in a leap February,
/// over New Year), what he types in the field «Кэшбэк», and points paid to another account.
final class AccountsScenarioCashbackPayoutTests: XCTestCase {
  private let calendar = CalendarContext.moscow

  private func dec(_ text: String) -> Decimal { Decimal(string: text)! }

  // MARK: Rounding

  func testWholeNearestRoundsAHalfAwayFromZeroBothWays() {
    let rounding = CashbackRounding.standard
    XCTAssertEqual(rounding.apply(dec("12.5")), 13)
    XCTAssertEqual(rounding.apply(dec("12.49")), 12)
    XCTAssertEqual(rounding.apply(dec("-12.5")), -13, "a refund takes back what it gave")
  }

  func testDownAndUpGoTowardAndAwayFromZero() {
    let down = CashbackRounding(precision: .whole, direction: .down)
    let up = CashbackRounding(precision: .whole, direction: .up)
    XCTAssertEqual(down.apply(dec("12.99")), 12)
    XCTAssertEqual(up.apply(dec("12.01")), 13)
    XCTAssertEqual(down.apply(dec("-12.99")), -12)
    XCTAssertEqual(up.apply(dec("-12.01")), -13)
  }

  func testCentsKeepKopecks() {
    XCTAssertEqual(CashbackRounding(precision: .cents).apply(dec("9.995")), dec("10.00"))
    XCTAssertEqual(
      CashbackRounding(precision: .cents, direction: .down).apply(dec("9.999")), dec("9.99"))
    XCTAssertEqual(
      CashbackRounding(precision: .cents, direction: .up).apply(dec("9.991")), dec("10.00"))
  }

  func testAnExactFigureIsLeftAloneEveryWay() {
    for precision in CashbackRounding.Precision.allCases {
      for direction in CashbackRounding.Direction.allCases {
        let rounding = CashbackRounding(precision: precision, direction: direction)
        XCTAssertEqual(rounding.apply(42), 42, "\(precision) \(direction)")
        XCTAssertEqual(rounding.apply(0), 0, "\(precision) \(direction)")
      }
    }
  }

  // MARK: The percent and the field

  func testAPercentIsKeptToFourPlacesOrRefused() {
    XCTAssertEqual(CashbackPercent(decimal: dec("1.5"))?.e4, 15_000)
    XCTAssertEqual(CashbackPercent(decimal: dec("0.0001"))?.e4, 1)
    XCTAssertNil(CashbackPercent(decimal: dec("0.00001")))
    XCTAssertEqual(CashbackPercent(decimal: 100)?.e4, CashbackPercent.maxE4)
    XCTAssertNil(CashbackPercent(decimal: dec("100.0001")))
    XCTAssertNil(CashbackPercent(decimal: -1))
    XCTAssertEqual(CashbackPercent(decimal: dec("1.5"))?.fraction, dec("0.015"))
  }

  func testTheFieldReadsAPercentWithACommaOrAFullWidthSign() {
    XCTAssertEqual(CashbackInput.read("1,5%"), .percent(CashbackPercent(e4: 15_000)!))
    XCTAssertEqual(CashbackInput.read(" 5 ％ "), .percent(CashbackPercent(e4: 50_000)!))
    XCTAssertEqual(CashbackInput.read("0%"), .percent(.zero))
  }

  func testTheFieldReadsAnAmount() {
    XCTAssertEqual(CashbackInput.read("45"), .amount(AmountE4(whole: 45)))
    XCTAssertEqual(CashbackInput.read("9.76"), .amount(AmountE4(raw: 97_600)))
  }

  func testTheFieldSaysWhyItCannotRead() {
    XCTAssertNil(CashbackInput.read("   "))
    XCTAssertEqual(CashbackInput.read("abc"), .unreadable(.malformed))
    XCTAssertEqual(CashbackInput.read("x%"), .unreadable(.malformed))
    XCTAssertEqual(CashbackInput.read("-5"), .unreadable(.negative))
    XCTAssertEqual(CashbackInput.read("-5%"), .unreadable(.negative))
    XCTAssertEqual(CashbackInput.read("101%"), .unreadable(.percentAboveHundred))
    XCTAssertEqual(CashbackInput.read("1.23456%"), .unreadable(.percentTooPrecise))
  }

  // MARK: When the bank pays

  func testADayOutsideTheMonthIsNoPayout() {
    XCTAssertNil(CashbackPayout.later(day: 0))
    XCTAssertNil(CashbackPayout.later(day: 32))
    XCTAssertNotNil(CashbackPayout.later(day: 1))
    XCTAssertNotNil(CashbackPayout.later(day: 31))
  }

  func testAStoredPairMustBelongTogether() {
    XCTAssertNil(CashbackPayout(timing: .immediately, storedDay: 5))
    XCTAssertNil(CashbackPayout(timing: .later, storedDay: nil))
    XCTAssertNil(CashbackPayout(timing: .later, storedDay: 40))
    XCTAssertEqual(CashbackPayout(timing: .immediately, storedDay: nil), .immediately)
    XCTAssertEqual(CashbackPayout(timing: .later, storedDay: 10), .later(day: 10))
  }

  func testDecembersCashbackIsDueInJanuaryOfTheNextYear() {
    let due = CashbackPayout.later(day: 10)!.dueDate(
      forPurchasesOf: MonthKey(year: 2026, month: 12), calendar: calendar)
    XCTAssertEqual(due, DateOnly(year: 2027, month: 1, day: 10))
  }

  func testByTheEndOfTheMonthIsTheLastDayOfFebruaryInAnyYear() {
    let payout = CashbackPayout.later(day: 31)!
    XCTAssertEqual(
      payout.dueDate(forPurchasesOf: MonthKey(year: 2027, month: 1), calendar: calendar),
      DateOnly(year: 2027, month: 2, day: 28))
    XCTAssertEqual(
      payout.dueDate(forPurchasesOf: MonthKey(year: 2028, month: 1), calendar: calendar),
      DateOnly(year: 2028, month: 2, day: 29), "a leap year")
    XCTAssertEqual(
      payout.dueDate(forPurchasesOf: MonthKey(year: 2026, month: 3), calendar: calendar),
      DateOnly(year: 2026, month: 4, day: 30))
  }

  func testABankPayingWithThePurchaseHasNoDueDay() {
    XCTAssertNil(
      CashbackPayout.immediately.dueDate(
        forPurchasesOf: MonthKey(year: 2026, month: 9), calendar: calendar))
  }

  // MARK: Late or paid

  private let september = MonthKey(year: 2026, month: 9)

  private func status(
    _ payout: CashbackPayout?, today: DateOnly, expected: Int64 = 300, received: Int64 = 0
  ) -> CashbackPayoutStatus {
    CashbackSchedule.status(
      of: september, payout: payout, today: today, expectedRub: AmountE4(whole: expected),
      receivedRub: AmountE4(whole: received), calendar: calendar)
  }

  func testNothingIsToldForAnAccountThatHasNotSaid() {
    XCTAssertEqual(status(nil, today: DateOnly(year: 2026, month: 12, day: 1)), .unknown)
  }

  func testABankPayingWithThePurchaseIsNeverLate() {
    XCTAssertEqual(
      status(.immediately, today: DateOnly(year: 2026, month: 12, day: 1)), .immediately)
  }

  func testTheDueDayItselfIsNotLateYet() {
    let due = DateOnly(year: 2026, month: 10, day: 10)
    XCTAssertEqual(status(.later(day: 10), today: due), .due(due))
  }

  func testTheDayAfterWithNothingReceivedIsLateWithWhatWasExpected() {
    let due = DateOnly(year: 2026, month: 10, day: 10)
    XCTAssertEqual(
      status(.later(day: 10), today: DateOnly(year: 2026, month: 10, day: 11)),
      .late(since: due, expectedRub: AmountE4(whole: 300)))
  }

  func testAnyCashbackReceivedIsPaidEvenIfLessThanExpected() {
    let due = DateOnly(year: 2026, month: 10, day: 10)
    XCTAssertEqual(
      status(.later(day: 10), today: DateOnly(year: 2026, month: 11, day: 1), received: 1),
      .paid(due))
  }

  func testAMonthThatEarnedNothingIsNeverLate() {
    let due = DateOnly(year: 2026, month: 10, day: 10)
    XCTAssertEqual(
      status(.later(day: 10), today: DateOnly(year: 2026, month: 11, day: 1), expected: 0),
      .due(due))
  }

  // MARK: Points

  func testPointsCannotGoToTheAccountItselfOrToAMissingOrArchivedOne() {
    let account = PaymentMethod(name: "Т-Банк")
    let old = PaymentMethod(name: "Бонусы", archived: true)
    XCTAssertEqual(
      CashbackPoints.issues(for: account.id, pointsAccountId: account.id, accounts: [account]),
      [.isItself])
    XCTAssertEqual(
      CashbackPoints.issues(for: account.id, pointsAccountId: UUID(), accounts: [account]),
      [.notFound])
    XCTAssertEqual(
      CashbackPoints.issues(for: account.id, pointsAccountId: old.id, accounts: [account, old]),
      [.archived])
    XCTAssertTrue(
      CashbackPoints.issues(for: account.id, pointsAccountId: nil, accounts: []).isEmpty)
  }

  func testAPointsAccountNamedByTwoAccountsHasNoOwner() {
    let points = PaymentMethod(name: "Спасибо")
    let one = PaymentMethod(name: "Сбер 1", cashbackPointsAccountId: points.id)
    let two = PaymentMethod(name: "Сбер 2", cashbackPointsAccountId: points.id)
    let three = PaymentMethod(name: "Бонусы")
    let four = PaymentMethod(name: "Альфа", cashbackPointsAccountId: three.id)
    let owners = CashbackPoints.owners(among: [points, one, two, three, four])
    XCTAssertNil(owners[points.id])
    XCTAssertEqual(owners[three.id], four.id)
  }

  func testAnAccountNamingItselfOwnsNothing() {
    let id = UUID()
    let itself = PaymentMethod(id: id, name: "Сам", cashbackPointsAccountId: id)
    XCTAssertTrue(CashbackPoints.owners(among: [itself]).isEmpty)
  }

  func testThePointsChoicesAreTheOtherLiveAccounts() {
    let account = PaymentMethod(name: "Т-Банк")
    let live = PaymentMethod(name: "Бонусы")
    let old = PaymentMethod(name: "Старый", archived: true)
    XCTAssertEqual(
      CashbackPoints.choices(for: account.id, among: [account, live, old]).map(\.id), [live.id])
  }

  // MARK: The settings of the sheet

  func testTheSheetSettingsRoundTripThroughTheAccount() {
    let points = UUID()
    let settings = CashbackAccountSettings(
      rounding: CashbackRounding(precision: .cents, direction: .down),
      payout: .later(day: 15), pointsAccountId: points)
    let account = PaymentMethod(name: "Т-Банк")
    XCTAssertTrue(settings.differs(from: account))
    let applied = settings.applied(to: account)
    XCTAssertEqual(CashbackAccountSettings(applied), settings)
    XCTAssertFalse(settings.differs(from: applied))
    XCTAssertEqual(applied.name, "Т-Банк", "nothing else of the account changes")
  }

  func testTheDefaultSettingsDoNotDifferFromANewAccount() {
    XCTAssertFalse(CashbackAccountSettings().differs(from: PaymentMethod(name: "Новый")))
  }
}

/// The month a cashback income counts for, as it comes on different days around the bank's
/// payout day: before, on and after it, across New Year, by the end of February, to a points
/// account, and for income that is not cashback at all.
final class AccountsScenarioCashbackMonthTests: XCTestCase {
  private let calendar = CalendarContext.moscow
  private let cashback = CoreKit.Category(kind: .income, name: "Кэшбэк")
  private lazy var miles = CoreKit.Category(parentId: cashback.id, kind: .income, name: "Мили")
  private let salary = CoreKit.Category(kind: .income, name: "Зарплата")
  private lazy var tree = CategoryTree([cashback, miles, salary])

  private func month(
    _ day: DateOnly, categories: [UUID?]? = nil, account: PaymentMethod,
    accounts: [PaymentMethod]? = nil
  ) -> MonthKey {
    CashbackIncomeMonth.month(
      forIncomeOn: day, categoryIds: categories ?? [cashback.id], accountId: account.id,
      cashbackCategoryId: cashback.id, tree: tree, accounts: accounts ?? [account],
      calendar: calendar)
  }

  private let byTenth = PaymentMethod(name: "Т-Банк", cashbackPayout: .later(day: 10))

  func testCashbackBeforeThePayoutDayIsLastMonths() {
    XCTAssertEqual(
      month(DateOnly(year: 2026, month: 10, day: 5), account: byTenth),
      MonthKey(year: 2026, month: 9))
  }

  func testCashbackOnThePayoutDayIsStillLastMonths() {
    XCTAssertEqual(
      month(DateOnly(year: 2026, month: 10, day: 10), account: byTenth),
      MonthKey(year: 2026, month: 9))
  }

  func testCashbackTheDayAfterIsItsOwnMonths() {
    XCTAssertEqual(
      month(DateOnly(year: 2026, month: 10, day: 11), account: byTenth),
      MonthKey(year: 2026, month: 10))
  }

  func testJanuaryCashbackIsDecembersOfTheYearBefore() {
    XCTAssertEqual(
      month(DateOnly(year: 2027, month: 1, day: 3), account: byTenth),
      MonthKey(year: 2026, month: 12))
  }

  func testByTheEndOfTheMonthTheLastDayOfFebruaryIsJanuarys() {
    let byEnd = PaymentMethod(name: "Альфа", cashbackPayout: .later(day: 31))
    XCTAssertEqual(
      month(DateOnly(year: 2028, month: 2, day: 29), account: byEnd),
      MonthKey(year: 2028, month: 1))
  }

  func testAMonthlyPayoutByTheEndCoversTheWholeMonth() {
    let byEnd = PaymentMethod(name: "Альфа", cashbackPayout: .later(day: 31))
    XCTAssertEqual(
      month(DateOnly(year: 2026, month: 11, day: 30), account: byEnd),
      MonthKey(year: 2026, month: 10))
  }

  func testAPayoutWithThePurchaseOrUnsaidKeepsTheMonthOfTheDate() {
    let now = PaymentMethod(name: "Сбер", cashbackPayout: .immediately)
    let unsaid = PaymentMethod(name: "ВТБ")
    let day = DateOnly(year: 2026, month: 10, day: 2)
    XCTAssertEqual(month(day, account: now), day.monthKey)
    XCTAssertEqual(month(day, account: unsaid), day.monthKey)
  }

  func testASubcategoryOfCashbackIsCashback() {
    XCTAssertEqual(
      month(DateOnly(year: 2026, month: 10, day: 5), categories: [miles.id], account: byTenth),
      MonthKey(year: 2026, month: 9))
  }

  func testIncomeThatIsNotAllCashbackKeepsItsMonth() {
    let day = DateOnly(year: 2026, month: 10, day: 5)
    XCTAssertEqual(month(day, categories: [salary.id], account: byTenth), day.monthKey)
    XCTAssertEqual(
      month(day, categories: [cashback.id, salary.id], account: byTenth), day.monthKey)
    XCTAssertEqual(month(day, categories: [nil], account: byTenth), day.monthKey)
    XCTAssertEqual(month(day, categories: [], account: byTenth), day.monthKey)
  }

  func testOnAPointsAccountTheEarningAccountsBankDecides() {
    let points = PaymentMethod(name: "Бонусы")
    let earner = PaymentMethod(
      name: "Т-Банк", cashbackPayout: .later(day: 10), cashbackPointsAccountId: points.id)
    XCTAssertEqual(
      month(
        DateOnly(year: 2026, month: 10, day: 7), account: points, accounts: [points, earner]),
      MonthKey(year: 2026, month: 9))
  }

  func testAPointsAccountOfTwoEarnersDecidesForItself() {
    let points = PaymentMethod(name: "Бонусы")
    let one = PaymentMethod(
      name: "Т-Банк", cashbackPayout: .later(day: 10), cashbackPointsAccountId: points.id)
    let two = PaymentMethod(
      name: "Альфа", cashbackPayout: .later(day: 10), cashbackPointsAccountId: points.id)
    let day = DateOnly(year: 2026, month: 10, day: 7)
    XCTAssertEqual(month(day, account: points, accounts: [points, one, two]), day.monthKey)
  }

  func testWithoutACashbackCategoryNothingIsCashback() {
    let day = DateOnly(year: 2026, month: 10, day: 5)
    XCTAssertFalse(
      CashbackIncomeMonth.isCashback(cashback.id, cashbackCategoryId: nil, tree: tree))
    XCTAssertFalse(
      CashbackIncomeMonth.isCashback(nil, cashbackCategoryId: cashback.id, tree: tree))
    XCTAssertEqual(
      CashbackIncomeMonth.month(
        forIncomeOn: day, categoryIds: [cashback.id], accountId: nil,
        cashbackCategoryId: cashback.id, tree: tree, accounts: [byTenth], calendar: calendar),
      day.monthKey, "an income on no account")
  }
}

/// The rules that price a purchase as the owner keeps them for a bank that has standing rates,
/// categories of the month and a card that differs: which rule wins at each step, how a sheet's
/// save writes them, what may not have a rule, and «Как в прошлом месяце».
final class AccountsScenarioCashbackRuleBookTests: XCTestCase {
  private let food = CoreKit.Category(kind: .expense, name: "Продукты")
  private lazy var coffee = CoreKit.Category(parentId: food.id, kind: .expense, name: "Кофе")
  private let fun = CoreKit.Category(kind: .expense, name: "Развлечения")
  private let goals = CoreKit.Category(kind: .expense, name: "Цели", systemRole: .goals)
  private let loans = CoreKit.Category(kind: .expense, name: "Кредиты", systemRole: .loans)
  private lazy var mortgage = CoreKit.Category(
    parentId: loans.id, kind: .expense, name: "Ипотека")
  private let reconcile = CoreKit.Category(kind: .expense, name: "Сверка")
  private lazy var reconcileChild = CoreKit.Category(
    parentId: reconcile.id, kind: .expense, name: "Недостача")
  private let salary = CoreKit.Category(kind: .income, name: "Зарплата")
  private let oldFood = CoreKit.Category(kind: .expense, name: "Архив", archived: true)

  private lazy var all = [
    food, coffee, fun, goals, loans, mortgage, reconcile, reconcileChild, salary, oldFood,
  ]
  private lazy var tree = CategoryTree(all)

  private let account = PaymentMethod(name: "Т-Банк")
  private lazy var black = PaymentCard(accountId: account.id, name: "Black")
  private let september = MonthKey(year: 2026, month: 9)

  private func pct(_ value: Int64) -> CashbackPercent { CashbackPercent(e4: value * 10_000)! }

  private func rule(
    card: Bool = false, category: UUID?, month: MonthKey? = nil, _ percent: Int64
  ) -> CashbackRule {
    CashbackRule(
      accountId: account.id, cardId: card ? black.id : nil, categoryId: category, month: month,
      percent: pct(percent))
  }

  private func book(_ rules: [CashbackRule]) -> CashbackRuleBook {
    CashbackRuleBook(rules: rules, tree: tree, cards: [black], accounts: [account])
  }

  private func percent(
    _ rules: [CashbackRule], card: Bool = false, category: UUID?
  ) -> Int64? {
    let holder: CashbackHolder = card ? .card(black.id) : .account(account.id)
    return book(rules).rule(for: holder, categoryId: category, month: september)
      .map { $0.percent.e4 / 10_000 }
  }

  func testTheMonthsSubcategoryRuleIsTheFirstStep() {
    let rules = [
      rule(category: coffee.id, month: september, 10), rule(category: food.id, month: september, 7),
      rule(category: coffee.id, 5), rule(category: nil, month: september, 2),
    ]
    XCTAssertEqual(percent(rules, category: coffee.id), 10)
  }

  func testTheMonthsCategoryRuleBeatsAStandingSubcategoryRule() {
    let rules = [rule(category: food.id, month: september, 7), rule(category: coffee.id, 5)]
    XCTAssertEqual(percent(rules, category: coffee.id), 7)
  }

  func testAStandingCategoryRuleBeatsTheMonthsEverythingElse() {
    let rules = [rule(category: food.id, 3), rule(category: nil, month: september, 2)]
    XCTAssertEqual(percent(rules, category: coffee.id), 3)
  }

  func testTheMonthsEverythingElseBeatsTheStandingOne() {
    let rules = [rule(category: nil, 1), rule(category: nil, month: september, 2)]
    XCTAssertEqual(percent(rules, category: fun.id), 2)
  }

  func testARuleOfAnotherMonthDoesNotPrice() {
    let rules = [rule(category: fun.id, month: MonthKey(year: 2026, month: 8), 15)]
    XCTAssertNil(percent(rules, category: fun.id))
  }

  func testAPurchaseWithoutACategoryTakesOnlyEverythingElse() {
    XCTAssertEqual(percent([rule(category: food.id, 5), rule(category: nil, 1)], category: nil), 1)
    XCTAssertNil(percent([rule(category: food.id, 5)], category: nil))
  }

  func testTheCardsRuleWinsWhereBothHaveTheStep() {
    let rules = [rule(category: food.id, 5), rule(card: true, category: food.id, 8)]
    XCTAssertEqual(percent(rules, card: true, category: food.id), 8)
    XCTAssertEqual(percent(rules, card: false, category: food.id), 5, "the account keeps its own")
  }

  func testTheAccountsMonthRuleBeatsTheCardsStandingRule() {
    let rules = [
      rule(category: food.id, month: september, 7), rule(card: true, category: food.id, 9),
    ]
    XCTAssertEqual(percent(rules, card: true, category: food.id), 7)
  }

  func testACardWithoutRulesFollowsItsAccount() {
    XCTAssertEqual(percent([rule(category: nil, 1)], card: true, category: fun.id), 1)
  }

  func testAHolderWithNoRulesAnywhereHasNone() {
    XCTAssertNil(
      book([]).rule(for: .account(UUID()), categoryId: food.id, month: september))
    XCTAssertTrue(book([]).isEmpty)
  }

  func testOfTwoRulesOfOneKeyTheFirstStays() {
    let first = rule(category: food.id, 5)
    let second = rule(category: food.id, 9)
    XCTAssertEqual(book([first, second]).rules(of: .account(account.id)).map(\.id), [first.id])
  }

  func testTheEffectiveRulesOfACardAreItsOwnAndTheAccountsRest() {
    let own = rule(card: true, category: food.id, 8)
    let shadowed = rule(category: food.id, 5)
    let rest = rule(category: fun.id, 3)
    let effective = book([own, shadowed, rest]).effectiveRules(of: .card(black.id))
    XCTAssertEqual(Set(effective.map(\.id)), [own.id, rest.id])
  }

  func testACardRoundsAsItsAccountDoes() {
    var down = account
    down.cashbackRounding = CashbackRounding(precision: .cents, direction: .down)
    let book = CashbackRuleBook(rules: [], tree: tree, cards: [black], accounts: [down])
    XCTAssertEqual(book.rounding(for: .card(black.id)), down.cashbackRounding)
    XCTAssertEqual(book.rounding(for: .card(UUID())), .standard)
    XCTAssertEqual(book.rounding(for: nil), .standard)
  }

  func testTheHolderIsTheNamedCardElseTheAccountElseTheMainOne() {
    let main = UUID()
    XCTAssertEqual(
      CashbackHolders.holder(accountId: account.id, cardId: black.id, mainAccountId: main),
      .card(black.id))
    XCTAssertEqual(
      CashbackHolders.holder(accountId: nil, cardId: nil, mainAccountId: main), .account(main))
    XCTAssertNil(CashbackHolders.holder(accountId: nil, cardId: nil, mainAccountId: nil))
  }

  func testTheSheetEditsTheAccountFirstThenItsLiveCards() {
    let old = PaymentCard(accountId: account.id, name: "Old", archived: true)
    let alpha = PaymentCard(accountId: account.id, name: "Alpha")
    XCTAssertEqual(
      CashbackHolders.editableHolders(of: account.id, cards: [black, old, alpha]),
      [.account(account.id), .card(alpha.id), .card(black.id)])
    XCTAssertEqual(CashbackHolders.account(of: .card(black.id), cards: [black]), account.id)
    XCTAssertNil(CashbackHolders.account(of: .card(UUID()), cards: [black]))
  }

  // MARK: Saving the sheet

  func testASaveWithNothingChangedWritesNothing() {
    let rules = [rule(category: food.id, 5), rule(category: nil, 1)]
    let diff = CashbackRules.diff(old: rules, new: rules)
    XCTAssertTrue(diff.upserts.isEmpty)
    XCTAssertTrue(diff.deletions.isEmpty)
  }

  func testANewPercentKeepsTheRowOfItsKey() {
    let old = rule(category: food.id, 5)
    var new = rule(category: food.id, 7)
    new.id = UUID()
    let diff = CashbackRules.diff(old: [old], new: [new])
    XCTAssertEqual(diff.upserts.map(\.id), [old.id])
    XCTAssertEqual(diff.upserts.first?.percent, pct(7))
    XCTAssertTrue(diff.deletions.isEmpty)
  }

  func testARowMovedToAnotherCategoryGetsANewIdAndTheOldKeyGoes() {
    let old = rule(category: food.id, 5)
    var moved = old
    moved.categoryId = fun.id
    let diff = CashbackRules.diff(old: [old], new: [moved])
    XCTAssertEqual(diff.deletions, [old.id])
    XCTAssertEqual(diff.upserts.count, 1)
    XCTAssertNotEqual(diff.upserts.first?.id, old.id)
    XCTAssertEqual(diff.upserts.first?.categoryId, fun.id)
  }

  func testTwoRowsSwappedKeepTheirKeysAndChangeOnlyPercents() {
    let a = rule(category: food.id, 5)
    let b = rule(category: fun.id, 3)
    var newA = a
    newA.categoryId = fun.id
    var newB = b
    newB.categoryId = food.id
    let diff = CashbackRules.diff(old: [a, b], new: [newA, newB])
    XCTAssertTrue(diff.deletions.isEmpty)
    XCTAssertEqual(Set(diff.upserts.map(\.id)), [a.id, b.id])
    XCTAssertEqual(diff.upserts.first { $0.id == a.id }?.percent, pct(3))
  }

  func testATwiceTypedKeyIsWrittenOnce() {
    let a = rule(category: food.id, 5)
    let b = rule(category: food.id, 9)
    XCTAssertEqual(CashbackRules.diff(old: [], new: [a, b]).upserts.map(\.id), [a.id])
  }

  func testRememberingTakesTheIdOfTheKeptRule() {
    let kept = rule(category: food.id, 5)
    let typed = rule(category: food.id, 8)
    XCTAssertEqual(CashbackRules.upserting(typed, into: [kept]).id, kept.id)
    let other = rule(category: fun.id, 8)
    XCTAssertEqual(CashbackRules.upserting(other, into: [kept]).id, other.id)
  }

  // MARK: What may not have a rule

  func testEachForbiddenCategoryIsToldItsWay() {
    let issues = CashbackRules.issues(
      [
        rule(category: salary.id, 1), rule(category: goals.id, 1), rule(category: mortgage.id, 1),
        rule(category: reconcileChild.id, 1), rule(category: food.id, 1),
      ], tree: tree, reconcileCategoryIds: [reconcile.id])
    XCTAssertEqual(
      issues,
      [
        .categoryNotExpense(salary.id), .categoryIsGoal(goals.id), .categoryIsLoan(mortgage.id),
        .categoryIsReconciliation(reconcileChild.id),
      ])
  }

  func testADuplicateKeyIsTold() {
    let a = rule(category: food.id, 5)
    XCTAssertEqual(
      CashbackRules.issues([a, rule(category: food.id, 2)], tree: tree), [.duplicate(a.key)])
  }

  func testTheSameCategoryOnTheCardAndTheAccountIsNoDuplicate() {
    XCTAssertTrue(
      CashbackRules.issues(
        [rule(category: food.id, 5), rule(card: true, category: food.id, 2)], tree: tree
      ).isEmpty)
  }

  func testTheChoicesAreLiveExpensesParentsFirstWithoutSystemTrees() {
    let choices = CashbackRules.categoryChoices(
      tree: tree, categories: all, reconcileCategoryIds: [reconcile.id])
    XCTAssertEqual(choices.map(\.name), ["Продукты", "Кофе", "Развлечения"])
  }

  // MARK: «Как в прошлом месяце»

  func testLastMonthsRulesAreCopiedWithNewIdsExceptTakenKeys() {
    let august = MonthKey(year: 2026, month: 8)
    let a = rule(category: food.id, month: august, 5)
    let b = rule(category: fun.id, month: august, 3)
    let standing = rule(category: nil, 1)
    let taken = rule(category: fun.id, month: september, 10)
    let copied = CashbackRules.copied(
      month: august, to: september, holder: .account(account.id), rules: [a, b, standing, taken])
    XCTAssertEqual(copied.map(\.categoryId), [food.id])
    XCTAssertEqual(copied.first?.month, september)
    XCTAssertNotEqual(copied.first?.id, a.id)
  }

  func testCopyingLeavesTheCardsRulesOutOfTheAccounts() {
    let august = MonthKey(year: 2026, month: 8)
    let cards = rule(card: true, category: food.id, month: august, 5)
    XCTAssertTrue(
      CashbackRules.copied(
        month: august, to: september, holder: .account(account.id), rules: [cards]
      ).isEmpty)
    XCTAssertEqual(
      CashbackRules.copied(
        month: august, to: september, holder: .card(black.id), rules: [cards]
      ).first?.cardId, black.id)
  }
}

/// What one purchase is expected to earn, from the rules of its account and its card: whole
/// rubles and kopecks, a split with a part paying a debt, a figure the owner typed, a refund of
/// no purchase, a charge in another currency, and the kinds of operations that earn nothing.
final class AccountsScenarioCashbackMathTests: XCTestCase {
  private let calendar = CalendarContext.moscow
  private let food = CoreKit.Category(kind: .expense, name: "Продукты")
  private let loans = CoreKit.Category(kind: .expense, name: "Кредиты", systemRole: .loans)
  private let goals = CoreKit.Category(kind: .expense, name: "Цели", systemRole: .goals)
  private let salary = CoreKit.Category(kind: .income, name: "Зарплата")
  private lazy var tree = CategoryTree([food, loans, goals, salary])
  private var account = PaymentMethod(name: "Т-Банк")
  private let day = Date(timeIntervalSince1970: 1_789_000_000)  // September 2026

  private func book(_ percentE4: Int64, rounding: CashbackRounding = .standard) -> CashbackRuleBook
  {
    var account = account
    account.cashbackRounding = rounding
    return CashbackRuleBook(
      rules: [
        CashbackRule(accountId: account.id, categoryId: nil, percent: .init(e4: percentE4)!)
      ], tree: tree, accounts: [account])
  }

  private func draft(
    _ raw: Int64, kind: TransactionKind = .expense, category: UUID? = nil,
    parts: [PartDraft] = []
  ) -> TransactionDraft {
    var draft = TransactionDraft(
      kind: kind, occurredAt: day, amount: AmountE4(raw: raw), paymentMethodId: account.id,
      parts: parts)
    if parts.isEmpty {
      draft.parts = [PartDraft(categoryId: category ?? food.id, amount: AmountE4(raw: raw))]
    }
    return draft
  }

  private func expected(
    _ draft: TransactionDraft, _ book: CashbackRuleBook
  ) -> CashbackExpectation? {
    CashbackMath.expected(
      draft, holder: .account(account.id), book: book, tree: tree, calendar: calendar)
  }

  func testFivePercentOfAThousandIsFifty() {
    let result = expected(draft(10_000_000), book(50_000))
    XCTAssertEqual(result?.money, Money(amount: AmountE4(whole: 50), currency: .rub))
    XCTAssertEqual(result?.rubles, AmountE4(whole: 50))
  }

  func testOnePercentOf999IsRoundedTheAccountsWay() {
    let purchase = draft(9_990_000)
    XCTAssertEqual(expected(purchase, book(10_000))?.money.amount, AmountE4(whole: 10))
    XCTAssertEqual(
      expected(purchase, book(10_000, rounding: .init(direction: .down)))?.money.amount,
      AmountE4(whole: 9))
    XCTAssertEqual(
      expected(purchase, book(10_000, rounding: .init(precision: .cents)))?.money.amount,
      AmountE4(raw: 99_900))
  }

  func testAPartPayingADebtEarnsNothingAndTheRestEarns() {
    let split = draft(
      20_000_000,
      parts: [
        PartDraft(categoryId: food.id, amount: AmountE4(whole: 1_000)),
        PartDraft(categoryId: loans.id, amount: AmountE4(whole: 1_000)),
      ])
    XCTAssertEqual(expected(split, book(100_000))?.money.amount, AmountE4(whole: 100))
  }

  func testAPaymentAllOnLoansEarnsNothing() {
    XCTAssertNil(expected(draft(10_000_000, category: loans.id), book(100_000)))
  }

  func testAContributionToAGoalEarnsNothing() {
    XCTAssertNil(expected(draft(10_000_000, category: goals.id), book(100_000)))
  }

  func testIncomeAndMoneyBackEarnNothing() {
    XCTAssertNil(expected(draft(10_000_000, kind: .income, category: salary.id), book(100_000)))
    XCTAssertNil(expected(draft(10_000_000, kind: .reimbursement), book(100_000)))
  }

  func testAPurchaseOnCreditEarnsNothing() {
    var purchase = draft(10_000_000)
    purchase.creditDebtId = UUID()
    XCTAssertNil(expected(purchase, book(100_000)))
  }

  func testARefundOfNoPurchaseTakesCashbackBack() {
    let result = expected(draft(10_000_000, kind: .refund), book(50_000))
    XCTAssertEqual(result?.money.amount, AmountE4(whole: -50))
  }

  func testATypedFigureWinsOverTheRulesToTheKopeck() {
    var purchase = draft(10_000_000)
    purchase.cashback = Money(amount: AmountE4(raw: 97_600), currency: .rub)
    let result = expected(purchase, book(50_000))
    XCTAssertEqual(result?.money.amount, AmountE4(raw: 97_600))
    XCTAssertEqual(result?.source, .override)
  }

  func testATypedFigureInAnotherCurrencyThanTheChargeIsIgnored() {
    var purchase = draft(10_000_000)
    purchase.cashback = Money(amount: AmountE4(whole: 5), currency: .usd)
    XCTAssertEqual(expected(purchase, book(50_000))?.source.isRules, true)
  }

  func testNoRuleNoExpectation() {
    XCTAssertNil(expected(draft(10_000_000), CashbackRuleBook(rules: [], tree: tree)))
  }

  func testTheBaseIsWhatTheAccountWasCharged() {
    var purchase = draft(1_000_000)  // 100 $
    purchase.currency = .usd
    purchase.rate = 90
    purchase.parts[0].amount = AmountE4(whole: 100)
    purchase.accountCurrency = .rub
    purchase.accountAmount = AmountE4(whole: 9_500)
    let result = expected(purchase, book(10_000))
    XCTAssertEqual(result?.money, Money(amount: AmountE4(whole: 95), currency: .rub))
  }

  func testATypedPercentBecomesAnAmountRoundedAsTheBankDoes() {
    let purchase = draft(1_234_500)  // 123.45
    let percent = CashbackPercent(e4: 30_000)!  // 3 %
    XCTAssertEqual(
      CashbackMath.amount(of: percent, on: purchase)?.amount, AmountE4(whole: 4))
    XCTAssertEqual(
      CashbackMath.amount(of: percent, on: purchase, rounding: .init(precision: .cents))?.amount,
      AmountE4(raw: 37_000))
  }
}

extension CashbackExpectation.Source {
  fileprivate var isRules: Bool {
    if case .rules = self { return true }
    return false
  }
}
