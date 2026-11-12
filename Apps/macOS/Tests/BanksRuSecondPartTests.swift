import AppCore
import XCTest

@testable import OhMyMoney

// Synthetic data only.

/// The second part of the Russian banks: the announced rate and the base of the interest in the
/// editor of an account, the digital ruble, the piggy bank and the burning points, and the report
/// of bank subscriptions on the Subscriptions page.
@MainActor
final class BanksRuSecondPartTests: XCTestCase {
  private let today = DateOnly(year: 2026, month: 11, day: 12)

  // MARK: Interest draft

  func testTheDraftReadsTheNextRateAndTheBaseAndRefusesAHalfTypedOne() throws {
    let id = UUID()
    var draft = InterestDraft(nil)
    draft.isOn = true
    draft.rateText = "16"
    XCTAssertEqual(try draft.terms(accountId: id).get()?.base, .daily)
    XCTAssertNil(try draft.terms(accountId: id).get()?.nextRate)

    draft.base = .minBalance
    draft.nextRateText = "12,5 %"
    XCTAssertEqual(draft.terms(accountId: id).failure, .nextRateNeedsDay)
    draft.nextRateOn = DateOnly(year: 2026, month: 12, day: 1)
    let terms = try XCTUnwrap(try draft.terms(accountId: id).get())
    XCTAssertEqual(terms.base, .minBalance)
    XCTAssertEqual(terms.nextRate, Decimal(string: "12.5"))
    XCTAssertEqual(terms.nextRateOn, DateOnly(year: 2026, month: 12, day: 1))

    for bad in ["abc", "0", "-1", "101"] {
      draft.nextRateText = bad
      XCTAssertEqual(draft.terms(accountId: id).failure, .nextRate, bad)
    }
    // An empty field is no announcement, whatever day is left in the draft.
    draft.nextRateText = "  "
    let none = try XCTUnwrap(try draft.terms(accountId: id).get())
    XCTAssertNil(none.nextRate)
    XCTAssertNil(none.nextRateOn)

    let back = InterestDraft(terms)
    XCTAssertEqual(back.base, .minBalance)
    XCTAssertEqual(back.nextRateOn, terms.nextRateOn)
    XCTAssertEqual(back.nextRateText, "12.5")
  }

  /// The block of interest says the announced rate while it is ahead, and the base when it is
  /// the lowest balance of the month, in both languages.
  func testTheInterestBlockSaysTheAnnouncedRateWhileItIsAheadAndTheBase() {
    let account = UUID()
    let terms = DepositTerms(
      rate: 16, period: .monthly, base: .minBalance, nextRate: 12,
      nextRateOn: DateOnly(year: 2026, month: 12, day: 1))
    let outlook = DepositOutlook(
      accountId: account, terms: terms, key: BalanceKey(accountId: account, currency: .rub),
      counted: false, payouts: [], toEndE4: nil)
    for choice in [AppLanguage.Choice.english, .russian] {
      let environment = AppEnvironment()
      environment.language.choice = choice
      let lines = InterestText.lines(outlook, names: [:], today: today, environment)
      let next = lines.nextRate ?? ""
      XCTAssertTrue(next.contains("12") && next.contains("16"), next)
      XCTAssertNotNil(lines.base)
      let started = InterestText.lines(
        outlook, names: [:], today: DateOnly(year: 2026, month: 12, day: 2), environment)
      XCTAssertNil(started.nextRate, "a rate that started is the rate itself")
    }
    let plain = DepositOutlook(
      accountId: account, terms: DepositTerms(rate: 16, period: .monthly),
      key: BalanceKey(accountId: account, currency: .rub), counted: false, payouts: [],
      toEndE4: nil)
    let lines = InterestText.lines(plain, names: [:], today: today, AppEnvironment())
    XCTAssertNil(lines.nextRate)
    XCTAssertNil(lines.base)
  }

  func testEveryRefusalOfTheInterestHasAnEnglishAndARussianLine() {
    for issue in [InterestIssue.nextRate, .nextRateNeedsDay] {
      for language in ["en", "ru"] {
        let environment = AppEnvironment()
        environment.language.choice = language == "ru" ? .russian : .english
        let text = environment.language(InterestText.issueKey(issue), table: "Accounts")
        XCTAssertNotEqual(text, InterestText.issueKey(issue), "\(issue) in \(language)")
      }
    }
  }

  // MARK: The editor of an account

  func testTheDraftOfAnAccountCarriesTheDigitalRubleThePiggyBankAndThePointsThatBurn() throws {
    var draft = AccountDraft(newIn: .usd)
    draft.name = "Wallet"
    draft.piggy = true
    draft.pointsBurnOn = DateOnly(year: 2026, month: 12, day: 31)
    draft.pointsBurnText = "1 200,5"
    let piggy = draft.account(over: nil)
    XCTAssertTrue(piggy.piggy)
    XCTAssertFalse(piggy.digitalRuble)
    XCTAssertEqual(piggy.pointsBurn?.on, DateOnly(year: 2026, month: 12, day: 31))
    XCTAssertEqual(piggy.pointsBurn?.amountE4, AmountE4(raw: 12_005_000))
    draft.pointsBurnText = "abc"
    XCTAssertNil(draft.pointsBurn?.amountE4, "what does not read burns as all of them")
    draft.pointsBurnText = "0"
    XCTAssertNil(draft.pointsBurn?.amountE4)
    draft.pointsBurnText = "1200,5"
    XCTAssertEqual(draft.pointsBurn?.amountE4, AmountE4(raw: 12_005_000))
    draft.pointsBurnText = ""
    XCTAssertNil(draft.pointsBurn?.amountE4)
    draft.pointsBurnOn = nil
    XCTAssertNil(draft.pointsBurn)

    draft.digitalRuble = true
    let wallet = draft.account(over: nil)
    XCTAssertTrue(wallet.digitalRuble)
    XCTAssertEqual(wallet.currency, .rub)
    XCTAssertTrue(wallet.otherCurrencies.isEmpty)
    XCTAssertNil(wallet.interest)
    XCTAssertTrue(DigitalRuble.issues(for: wallet).isEmpty)

    // What an account has comes back into the draft.
    let back = AccountDraft(wallet)
    XCTAssertTrue(back.digitalRuble)
    var burning = PaymentMethod(
      name: "Points", pointsBurn: PointsBurn(on: today, amountE4: AmountE4(whole: 300)))
    burning.piggy = true
    let read = AccountDraft(burning)
    XCTAssertEqual(read.pointsBurnOn, today)
    XCTAssertEqual(read.pointsBurn?.amountE4, AmountE4(whole: 300))
    XCTAssertTrue(read.piggy)
  }

  // MARK: Bank subscriptions on the page

  func testTheSubscriptionsPageReportsABankSubscriptionThatStatesABenefit() throws {
    let bank = UUID()
    let account = PaymentMethod(name: "Card", bankId: bank)
    let pro = ScheduledPayment(
      name: "Pro", kind: .subscription, amountE4: AmountE4(whole: 300),
      paymentMethodId: account.id, freq: .monthly, day: 20,
      nextDate: DateOnly(year: 2026, month: 11, day: 20))
    let plain = ScheduledPayment(
      name: "Plain", kind: .subscription, amountE4: AmountE4(whole: 100),
      paymentMethodId: account.id, freq: .monthly, day: 21,
      nextDate: DateOnly(year: 2026, month: 11, day: 21))
    let terms = SubscriptionTerms(paymentId: pro.id, bankBenefitE4: AmountE4(whole: 400))
    let book = PlanningBook(scheduled: [pro, plain])
    let ledger = Ledger(
      dataset: Dataset(paymentMethods: [account], planning: book), calendar: .utc)
    let page = SubscriptionsPage.build(
      book: book, subscriptions: SubscriptionBook(terms: [terms]), ledger: ledger, rates: .empty,
      rubPerUnit: [:], today: today)
    let line = try XCTUnwrap(page.bankPaybacks.first)
    XCTAssertEqual(page.bankPaybacks.count, 1, "only the one that states a benefit")
    XCTAssertEqual(line.paymentId, pro.id)
    XCTAssertEqual(line.costRub, AmountE4(whole: 300))
    XCTAssertEqual(line.netRub, AmountE4(whole: 100))
    XCTAssertEqual(line.verdict, .paysBack)
    XCTAssertEqual(SubscriptionsPage.bankCashback(ledger: ledger, today: today), [:])

    // Hidden accounts covered: the line goes with its subscription.
    XCTAssertEqual(SubscriptionsScreen.bankKey(.costsMore), "subs.bank.costsMore")
  }

  // MARK: The words

  func testTheWordsOfTheNewScreensExistInEnglishAndRussian() {
    let keys: [(String, String)] = [
      ("account.interest.base.daily", "Accounts"), ("account.interest.nextRate", "Accounts"),
      ("account.interest.nextRateLine", "Accounts"), ("account.editor.piggy", "Accounts"),
      ("account.editor.digitalRuble", "Accounts"), ("account.editor.pointsBurn", "Accounts"),
      ("account.savings.title", "Accounts"), ("account.points.compare", "Accounts"),
      ("account.points.verdictPoints", "Accounts"), ("subs.bank", "Subscriptions"),
      ("subs.bank.line", "Subscriptions"), ("subs.terms.bankBenefit", "Subscriptions"),
      ("pause.action", "Debts"), ("pause.termShift", "Debts"), ("pause.kind.holiday", "Debts"),
      ("reminders.rateChange", "Planning"),
    ]
    for language in ["en", "ru"] {
      let environment = AppEnvironment()
      environment.language.choice = language == "ru" ? .russian : .english
      for (key, table) in keys {
        XCTAssertNotEqual(environment.language(key, table: table), key, "\(key) in \(language)")
      }
    }
  }
}

extension Result {
  /// The error of a failure; `nil` for a success.
  fileprivate var failure: Failure? {
    if case .failure(let error) = self { return error }
    return nil
  }
}
