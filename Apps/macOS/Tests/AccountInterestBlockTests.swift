import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// «Проценты» of an account's screen: the words the block shows in both languages for a
/// deposit, a savings account, one never counted and one that has ended; the payouts it asks
/// about and what «Записать…» starts with; the grey line of the forecast; and that recording a
/// payout writes the ordinary income in the category of interest, one step of ⌘Z.
@MainActor
final class AccountInterestBlockTests: XCTestCase {
  private let today = DateOnly(year: 2026, month: 10, day: 11)
  private let depositId = UUID()
  private let cardId = UUID()

  private func environment(_ choice: AppLanguage.Choice) -> AppEnvironment {
    let environment = AppEnvironment()
    environment.language.choice = choice
    return environment
  }

  private func amount(_ text: String) -> AmountE4 {
    (try? AmountE4(decimal: Decimal(string: text)!)) ?? .zero
  }

  private func payout(
    _ payDate: DateOnly, from start: DateOnly, accrued: String, expected: String,
    state: DepositPayout.State, to target: UUID? = nil
  ) -> DepositPayout {
    DepositPayout(
      accountId: depositId,
      target: BalanceKey(accountId: target ?? depositId, currency: .rub), periodStart: start,
      payDate: payDate, accruedE4: amount(accrued), expectedE4: amount(expected),
      capitalized: target == nil, state: state)
  }

  /// A deposit at 16 % paid on the last day of each month, to the end of March: September's
  /// interest did not come, October's is earning.
  private var deposit: DepositOutlook {
    DepositOutlook(
      accountId: depositId,
      terms: DepositTerms(
        rate: 16, period: .monthly, day: 31, openedOn: DateOnly(year: 2026, month: 3, day: 31),
        endsOn: DateOnly(year: 2027, month: 3, day: 31)),
      key: BalanceKey(accountId: depositId, currency: .rub), counted: true,
      payouts: [
        payout(
          DateOnly(year: 2026, month: 9, day: 30), from: DateOnly(year: 2026, month: 8, day: 31),
          accrued: "2345.67", expected: "2345.67", state: .missing),
        payout(
          DateOnly(year: 2026, month: 10, day: 31), from: DateOnly(year: 2026, month: 9, day: 30),
          accrued: "1000", expected: "3100.5", state: .accruing),
      ],
      toEndE4: amount("15000"))
  }

  /// Every line of a deposit, in Russian and in English: the rate and the next payout, the kind,
  /// what is earned so far, what is to be paid and where, what is still to come to the end, and
  /// the payout that did not come. Every sum of interest is «≈».
  func testTheLinesOfADepositInBothLanguages() {
    let ru = environment(.russian)
    let money = ru.money
    let lines = InterestText.lines(deposit, names: [:], today: today, ru)
    XCTAssertEqual(lines.headline, "Ставка 16\u{00A0}% · выплата 31 октября")
    XCTAssertTrue(lines.kind.hasPrefix("Вклад до 31 марта 2027"), lines.kind)
    XCTAssertFalse(lines.ended)
    XCTAssertNil(lines.notCounted)
    XCTAssertEqual(
      lines.accrued, "Начислено с 30 сентября ≈\u{00A0}\(money.exact(amount("1000")))")
    XCTAssertEqual(
      lines.payout,
      "К выплате 31 октября ≈\u{00A0}\(money.exact(amount("3100.5"))) → на этот счёт")
    XCTAssertEqual(lines.toEnd, "К концу срока ≈\u{00A0}\(money.exact(amount("15000")))")
    XCTAssertEqual(lines.asks.count, 1)
    XCTAssertEqual(
      lines.asks.first?.text,
      "Проценты ≈\u{00A0}\(money.exact(amount("2345.67"))) за 30 сентября не пришли?")
    XCTAssertEqual(lines.asks.first?.isMissing, true)

    let en = environment(.english)
    let english = InterestText.lines(deposit, names: [:], today: today, en)
    XCTAssertEqual(english.headline, "Rate 16% · payout on October 31")
    XCTAssertTrue(english.kind.hasPrefix("Deposit until"), english.kind)
    XCTAssertTrue(english.accrued?.hasPrefix("Earned since September 30 ≈") == true)
    XCTAssertTrue(english.payout?.hasSuffix("→ to this account") == true)
    XCTAssertTrue(english.asks.first?.text.hasSuffix("for September 30 did not come?") == true)
    ru.language.choice = .russian
  }

  /// A savings account paying onto a card says where; a payout due days ago but within the
  /// days the bank may take is waited for, not called missing; there is no «к концу срока».
  func testASavingsAccountPayingToACardAndAPayoutStillDue() {
    let ru = environment(.russian)
    let outlook = DepositOutlook(
      accountId: depositId,
      terms: DepositTerms(
        rate: Decimal(string: "12.5")!, period: .monthly, payoutAccountId: cardId),
      key: BalanceKey(accountId: depositId, currency: .rub), counted: true,
      payouts: [
        payout(
          DateOnly(year: 2026, month: 10, day: 9), from: DateOnly(year: 2026, month: 9, day: 9),
          accrued: "500", expected: "500", state: .due, to: cardId),
        payout(
          DateOnly(year: 2026, month: 11, day: 9), from: DateOnly(year: 2026, month: 10, day: 9),
          accrued: "41.1", expected: "520", state: .accruing, to: cardId),
      ],
      toEndE4: nil)
    let lines = InterestText.lines(outlook, names: [cardId: "Карта"], today: today, ru)
    XCTAssertEqual(lines.headline, "Ставка 12.5\u{00A0}% · выплата 9 ноября")
    XCTAssertEqual(lines.kind, "Накопительный счёт")
    XCTAssertTrue(lines.payout?.hasSuffix("→ на «Карта»") == true, lines.payout ?? "")
    XCTAssertNil(lines.toEnd)
    XCTAssertEqual(lines.asks.map(\.isMissing), [false])
    XCTAssertTrue(lines.asks.first?.text.hasPrefix("Ждём проценты ≈") == true)

    // «Записать…» starts on the card, with the sum expected, on the pay date.
    let prefill = try? XCTUnwrap(lines.asks.first?.prefill)
    XCTAssertEqual(prefill?.accountId, cardId)
    XCTAssertEqual(prefill?.depositId, depositId)
    XCTAssertEqual(prefill?.amount, amount("500"))
    XCTAssertEqual(prefill?.day, DateOnly(year: 2026, month: 10, day: 9))
    XCTAssertEqual(prefill?.currency, .rub)
  }

  /// Never counted: no interest to work out, and the block says why; ended: the deposit says
  /// so and promises nothing more.
  func testAnAccountNeverCountedAndADepositThatEnded() {
    let ru = environment(.russian)
    var uncounted = deposit
    uncounted.counted = false
    uncounted.payouts = []
    let lines = InterestText.lines(uncounted, names: [:], today: today, ru)
    XCTAssertEqual(lines.notCounted, "Сверьте счёт — без остатка проценты не посчитать")
    XCTAssertNil(lines.accrued)
    XCTAssertNil(lines.payout)
    XCTAssertEqual(lines.headline, "Ставка 16\u{00A0}% · ежемесячно")

    var ended = deposit
    ended.terms.endsOn = DateOnly(year: 2026, month: 10, day: 1)
    ended.payouts = []
    let after = InterestText.lines(ended, names: [:], today: today, ru)
    XCTAssertTrue(after.ended)
    XCTAssertTrue(after.kind.hasPrefix("Вклад закрылся 1 октября 2026"), after.kind)
    XCTAssertTrue(after.kind.hasSuffix("проценты больше не начисляются"))
    XCTAssertEqual(after.headline, "Ставка 16\u{00A0}%")
    XCTAssertNil(after.payout)
    XCTAssertNil(after.toEnd)
  }

  /// A day gone by is dated at noon, so the month is right; today — now.
  func testThePrefilledMomentIsNoonOfAPastDay() {
    let calendar = CalendarContext.moscow
    let past = DateOnly(year: 2026, month: 9, day: 30)
    XCTAssertEqual(
      DepositIncomePrefill.moment(of: past, today: today, calendar: calendar),
      calendar.noon(of: past))
    let now = DepositIncomePrefill.moment(of: today, today: today, calendar: calendar)
    XCTAssertLessThan(abs(now.timeIntervalSinceNow), 5)
  }

  /// The forecast card shows the interest right after the income, grey and «≈»: an estimate.
  func testTheForecastCardHasAGreyLineOfInterest() {
    let ru = environment(.russian)
    let main = PaymentMethod(name: "Вклад", currency: .rub, isDefault: true)
    let line = AccountForecast.Line(
      flows: AccountMonthPlan.Flows(
        key: BalanceKey(accountId: main.id, currency: .rub), account: main,
        now: AmountE4(whole: 100_000), income: AmountE4(whole: 5_000),
        interest: AmountE4(whole: 1_234)),
      status: .ready, spending: nil, balance: nil, balanceRub: nil, shareBp: nil)
    let pair = AccountForecastText.pair(line, showsCurrency: false, ru)
    XCTAssertEqual(
      pair.breakdown.map(\.label), ["Сейчас", "Ожидаемые поступления", "Проценты"])
    XCTAssertEqual(pair.breakdown.last?.value, "≈\u{00A0}+1,234\u{00A0}₽")
    XCTAssertEqual(pair.breakdown.map(\.isEstimate), [false, false, true])
  }

  // MARK: Recording

  /// «Записать» writes the ordinary income on the account, in the category of interest it
  /// makes at the first payout, in one step of ⌘Z with it.
  func testRecordingAPayoutWritesTheIncomeInTheCategoryOfInterest() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-interest-record-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let before = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    setenv("OHMYMONEY_DATA_DIR", directory.path, 1)
    let environment = AppEnvironment()
    await environment.start(preparing: {
      try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    })
    defer {
      if let before {
        setenv("OHMYMONEY_DATA_DIR", before, 1)
      } else {
        unsetenv("OHMYMONEY_DATA_DIR")
      }
      try? FileManager.default.removeItem(at: directory)
    }
    let store = TransactionsStore()
    store.attach(
      try XCTUnwrap(environment.transactions), references: environment.references,
      planning: environment.planning)
    let references = try XCTUnwrap(environment.references)
    try references.save(PaymentMethod(name: "Сбер", currency: .rub, isDefault: true))
    let savings = PaymentMethod(
      name: "Копилка", kind: .account, currency: .rub,
      interest: DepositTerms(rate: 16, period: .monthly))
    try references.save(savings)
    let actions = AccountActions(environment: environment, store: store)
    let categoriesBefore = try references.categories(includeArchived: true).count

    let books = await actions.books()
    let day = DateOnly(year: 2026, month: 9, day: 30)
    let at = environment.calendar.noon(of: day)
    XCTAssertEqual(
      actions.recordInterest(
        amount: amount("2345.67"), currency: .rub, accountId: savings.id, at: at,
        dataset: books?.dataset), .done)

    let categoryId = try XCTUnwrap(
      try environment.settings?.string(AccountSettings.interestCategoryKey)
        .flatMap { UUID(uuidString: $0) })
    XCTAssertEqual(try references.categories(includeArchived: true).count, categoriesBefore + 1)
    let written = try XCTUnwrap(environment.transactions).entries(
      from: environment.calendar.startOfDay(day),
      to: environment.calendar.startOfDay(day.adding(days: 1)))
    XCTAssertEqual(written.count, 1)
    let entry = try XCTUnwrap(written.first)
    XCTAssertEqual(entry.transaction.kind, .income)
    XCTAssertEqual(entry.transaction.paymentMethodId, savings.id)
    XCTAssertEqual(entry.transaction.amountE4, amount("2345.67"))
    XCTAssertEqual(entry.parts.map(\.categoryId), [categoryId])

    store.undo()
    XCTAssertTrue(
      try XCTUnwrap(environment.transactions).entries(
        from: environment.calendar.startOfDay(day),
        to: environment.calendar.startOfDay(day.adding(days: 1))
      ).isEmpty)
    XCTAssertEqual(try references.categories(includeArchived: true).count, categoriesBefore)
    XCTAssertNil(try environment.settings?.string(AccountSettings.interestCategoryKey))
    await environment.close()
  }
}
