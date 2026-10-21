import AppCore
import XCTest

@testable import OhMyMoney

/// The three blocks cards brought to an account's screen, at the level of their models: «Карты»,
/// «Кэшбэк · месяц» and «Платежи и подписки».
@MainActor
final class AccountBlocksModelTests: XCTestCase {
  private let tBank = UUID()
  private let sber = UUID()
  private let black = UUID()
  private let virtual = UUID()
  private let old = UUID()
  private let cafes = UUID()
  private let cashback = UUID()
  private let september = MonthKey(year: 2026, month: 9)
  private let calendar = CalendarContext.utc

  private var cards: [PaymentCard] {
    [
      PaymentCard(id: virtual, accountId: tBank, name: "Virtual", aliases: ["virt"]),
      PaymentCard(id: black, accountId: tBank, name: "Black"),
      PaymentCard(id: old, accountId: tBank, name: "Old", archived: true),
      PaymentCard(accountId: sber, name: "Sber"),
    ]
  }

  private var rules: [CashbackRule] {
    [
      CashbackRule(
        accountId: tBank, cardId: black, categoryId: cafes, month: september,
        percent: CashbackPercent(e4: 100_000)!),
      CashbackRule(accountId: tBank, cardId: black, percent: CashbackPercent(e4: 10_000)!),
      CashbackRule(
        accountId: tBank, cardId: black, categoryId: cafes,
        month: MonthKey(year: 2026, month: 8), percent: CashbackPercent(e4: 30_000)!),
    ]
  }

  func testTheCardsBlockListsLiveCardsInOrderAndTheArchivedApart() {
    let model = AccountCardsModel(
      accountId: tBank, cards: cards, rules: rules, locale: Locale(identifier: "en_US_POSIX"))
    XCTAssertEqual(model.live.map(\.card.name), ["Black", "Virtual"])
    XCTAssertEqual(model.archived.map(\.card.name), ["Old"])
    XCTAssertEqual(model.live.map(\.rules), [3, 0])
    XCTAssertEqual(model.live.last?.otherNames, "virt")
  }

  /// A coffee of 350 on Black in September: 10 % of the month's rule → 35.00 expected; 20
  /// received for September on Black. The line shows the rules of September and «always», not
  /// August's.
  func testTheCashbackBlockShowsExpectedAndReceived() throws {
    let at = calendar.noon(of: DateOnly(year: 2026, month: 9, day: 12))
    func operation(
      _ kind: TransactionKind, _ category: UUID, _ amount: Int64, card: UUID
    ) -> TransactionEntry {
      let transaction = Transaction(
        kind: kind, occurredAt: at, amountE4: AmountE4(whole: amount), paymentMethodId: tBank,
        createdAt: at, updatedAt: at, cardId: card)
      return TransactionEntry(
        transaction: transaction,
        parts: [
          TransactionPart(
            transactionId: transaction.id, categoryId: category,
            amountE4: AmountE4(whole: amount))
        ])
    }
    let dataset = Dataset(
      entries: [
        operation(.expense, cafes, 350, card: black),
        operation(.income, cashback, 20, card: black),
      ],
      categories: [
        CoreKit.Category(id: cafes, kind: .expense, name: "Cafes"),
        CoreKit.Category(id: cashback, kind: .income, name: "Cashback"),
      ],
      paymentMethods: [PaymentMethod(id: tBank, name: "T-Bank", kind: .card)],
      settings: AnalyticsSettings(cashbackCategoryId: cashback), cards: cards,
      cashbackRules: rules)
    let model = AccountCashbackModel.build(
      month: september, accountId: tBank, ledger: Ledger(dataset: dataset, calendar: calendar),
      today: DateOnly(year: 2026, month: 9, day: 20))
    // The account's own line first, then Black, which keeps rules of its own; Virtual keeps none
    // and was not named, so it has no line.
    XCTAssertEqual(model.lines.map(\.cardId), [nil, black])
    let line = try XCTUnwrap(model.lines.last)
    XCTAssertEqual(line.expected, [Money(amount: AmountE4(whole: 35), currency: .rub)])
    XCTAssertEqual(line.received, [Money(amount: AmountE4(whole: 20), currency: .rub)])
    XCTAssertEqual(line.rules.map(\.month), [september, nil], "the month's rule first")
    XCTAssertFalse(model.isEmpty)
    XCTAssertTrue(model.lines[0].expected.isEmpty && model.lines[0].rules.isEmpty)
  }

  // MARK: The rules of the account, when the bank pays, the points

  private let bonus = UUID()

  /// Purchases in September that name no card on an account that keeps the rules: the cafes
  /// 1,000 at 5 % and a coffee 350 with 40 typed over it.
  private func septemberOfAnAccount(
    payout: CashbackPayout?, points: UUID? = nil, receivedInOctober: Int64? = nil
  ) -> Dataset {
    func operation(
      _ kind: TransactionKind, on day: DateOnly, _ category: UUID, _ amount: Int64,
      account: UUID, period: MonthKey? = nil, cashback: Int64? = nil
    ) -> TransactionEntry {
      let at = calendar.noon(of: day)
      let transaction = Transaction(
        kind: kind, occurredAt: at, amountE4: AmountE4(whole: amount), paymentMethodId: account,
        periodMonth: period, createdAt: at, updatedAt: at,
        cashback: cashback.map { Money(amount: AmountE4(whole: $0), currency: .rub) })
      return TransactionEntry(
        transaction: transaction,
        parts: [
          TransactionPart(
            transactionId: transaction.id, categoryId: category,
            amountE4: AmountE4(whole: amount))
        ])
    }
    var entries = [
      operation(
        .expense, on: DateOnly(year: 2026, month: 9, day: 12), cafes, 1_000, account: tBank),
      operation(
        .expense, on: DateOnly(year: 2026, month: 9, day: 13), cafes, 350, account: tBank,
        cashback: 40),
    ]
    if let received = receivedInOctober {
      entries.append(
        operation(
          .income, on: DateOnly(year: 2026, month: 10, day: 8), cashback, received,
          account: points ?? tBank, period: september))
    }
    return Dataset(
      entries: entries,
      categories: [
        CoreKit.Category(id: cafes, kind: .expense, name: "Cafes"),
        CoreKit.Category(id: cashback, kind: .income, name: "Cashback"),
      ],
      paymentMethods: [
        PaymentMethod(
          id: tBank, name: "T-Bank", kind: .card, cashbackPayout: payout,
          cashbackPointsAccountId: points),
        PaymentMethod(id: bonus, name: "Bonus", kind: .other),
      ],
      settings: AnalyticsSettings(cashbackCategoryId: cashback), cards: cards,
      cashbackRules: [
        CashbackRule(
          accountId: tBank, categoryId: cafes, percent: CashbackPercent(e4: 50_000)!)
      ])
  }

  private func block(
    _ dataset: Dataset, month: MonthKey, today: DateOnly
  ) -> AccountCashbackModel {
    AccountCashbackModel.build(
      month: month, accountId: tBank, ledger: Ledger(dataset: dataset, calendar: calendar),
      today: today)
  }

  /// The rules of the account price the purchases that name no card, on the account's own line;
  /// what only the rules gave is the part nobody has confirmed, and it still counts.
  func testThePurchasesWithoutACardAreTheAccountsLineAndTheRulesPartIsUnconfirmed() throws {
    let model = block(
      septemberOfAnAccount(payout: nil), month: september,
      today: DateOnly(year: 2026, month: 9, day: 20))
    XCTAssertEqual(model.lines.map(\.cardId), [nil], "no card keeps rules of its own")
    let line = try XCTUnwrap(model.lines.first)
    // 5 % of 1,000 = 50 by the rules, and the 40 typed for the coffee.
    XCTAssertEqual(line.expected, [Money(amount: AmountE4(whole: 90), currency: .rub)])
    XCTAssertEqual(line.rules.map(\.percent.e4), [50_000])
    XCTAssertEqual(model.expectedRub, AmountE4(whole: 90))
    XCTAssertEqual(model.unconfirmedRub, AmountE4(whole: 50), "the rules' part, no figure typed")
    XCTAssertEqual(model.status, .unknown, "the account has not said when its bank pays")
    XCTAssertNil(model.late)
    XCTAssertNil(model.pointsAccountName)
  }

  /// The bank pays by the 10th of the next month: until then it is due; the month after, with
  /// nothing received for September, the block says September's cashback is late.
  func testTheBlockSaysWhenTheBankPaysAndWhatIsLate() throws {
    let dataset = septemberOfAnAccount(payout: CashbackPayout.later(day: 10))
    let inSeptember = block(
      dataset, month: september, today: DateOnly(year: 2026, month: 9, day: 20))
    XCTAssertEqual(inSeptember.status, .due(DateOnly(year: 2026, month: 10, day: 10)))
    XCTAssertNil(inSeptember.late)

    let inOctober = block(
      dataset, month: MonthKey(year: 2026, month: 10),
      today: DateOnly(year: 2026, month: 10, day: 12))
    XCTAssertEqual(inOctober.status, .due(DateOnly(year: 2026, month: 11, day: 10)))
    let late = try XCTUnwrap(inOctober.late)
    XCTAssertEqual(late.month, september)
    XCTAssertEqual(late.since, DateOnly(year: 2026, month: 10, day: 10))
    XCTAssertEqual(late.expectedRub, AmountE4(whole: 90))

    // Before the day it is not late yet.
    let early = block(
      dataset, month: MonthKey(year: 2026, month: 10),
      today: DateOnly(year: 2026, month: 10, day: 9))
    XCTAssertNil(early.late)
  }

  /// Anything that came for September, on the account or on its points account, ends the delay.
  func testWhatCameEndsTheDelay() {
    let october = MonthKey(year: 2026, month: 10)
    let today = DateOnly(year: 2026, month: 10, day: 12)
    let onTheAccount = septemberOfAnAccount(
      payout: CashbackPayout.later(day: 10), receivedInOctober: 85)
    XCTAssertNil(block(onTheAccount, month: october, today: today).late)
    let asPoints = septemberOfAnAccount(
      payout: CashbackPayout.later(day: 10), points: bonus, receivedInOctober: 85)
    let model = block(asPoints, month: october, today: today)
    XCTAssertNil(model.late, "the points on «Bonus» are T-Bank's cashback")
    XCTAssertEqual(model.pointsAccountName, "Bonus")
  }

  func testAnImmediateBankIsToldAsSuch() {
    let model = block(
      septemberOfAnAccount(payout: .immediately), month: september,
      today: DateOnly(year: 2026, month: 9, day: 20))
    XCTAssertEqual(model.status, .immediately)
    XCTAssertNil(model.late, "a bank that pays at once has no day to be late by")
  }

  /// A quiet month of a tenge account: the empty sides are printed in tenge, not rubles.
  func testTheCashbackBlockSpeaksInTheAccountsCurrency() {
    let kaspi = UUID()
    let tenge = CurrencyCode("KZT")
    let dataset = Dataset(
      entries: [],
      paymentMethods: [PaymentMethod(id: kaspi, name: "Kaspi", kind: .card, currency: tenge)],
      cards: [PaymentCard(accountId: kaspi, name: "Gold")])
    let model = AccountCashbackModel.build(
      month: september, accountId: kaspi, ledger: Ledger(dataset: dataset, calendar: calendar),
      today: DateOnly(year: 2026, month: 9, day: 20))
    XCTAssertEqual(model.currency, tenge)
    let rubles = Dataset(
      entries: [], paymentMethods: [PaymentMethod(id: kaspi, name: "Cash", kind: .cash)])
    XCTAssertEqual(
      AccountCashbackModel.build(
        month: september, accountId: kaspi, ledger: Ledger(dataset: rubles, calendar: calendar),
        today: DateOnly(year: 2026, month: 9, day: 20)
      ).currency, .rub, "an account saved without a currency counts in rubles")
  }

  func testThePaymentsBlockNamesTheCardOrSaysItIsArchived() {
    func status(_ name: String, card: UUID?, account: UUID?) -> ScheduledStatus {
      let day = DateOnly(year: 2026, month: 9, day: 20)
      return ScheduledStatus(
        payment: ScheduledPayment(
          name: name, amountE4: AmountE4(whole: 299), paymentMethodId: account, nextDate: day,
          cardId: card),
        dueDates: [day], nextDue: day, isOverdue: false, amountNext: AmountE4(whole: 299),
        monthly: AmountE4(whole: 299), yearly: AmountE4(whole: 3_588),
        myShareRubNext: AmountE4(whole: 299), expectedReturnRubNext: nil, lastCharge: nil,
        chargedDifferently: false)
    }
    let model = AccountPaymentsModel(
      accountId: tBank,
      statuses: [
        status("Music", card: black, account: tBank), status("Cloud", card: old, account: tBank),
        status("Gym", card: nil, account: sber),
      ],
      cards: cards, mainAccountId: sber)
    XCTAssertEqual(model.rows.map(\.status.payment.name), ["Cloud", "Music"])
    XCTAssertEqual(model.rows.map(\.cardName), ["Old", "Black"])
    XCTAssertEqual(model.rows.map(\.cardArchived), [true, false])
    XCTAssertTrue(model.opensByItself)
  }

  /// «Добавить платёж…» on the Kaspi (₸) screen starts a payment in tenge, due today, paid from
  /// Kaspi — not 5,000 ₽ typed as 5,000 ₸. The tenge only follows the account: another account
  /// picked in the form moves the currency, as with a new payment of Planning. A candidate's
  /// currency stays the owner's.
  func testANewPaymentOfATengeAccountIsInTenge() throws {
    let kzt = CurrencyCode("KZT")
    let kaspi = PaymentMethod(name: "Kaspi", kind: .card, currency: kzt)
    let main = PaymentMethod(id: sber, name: "Сбер", kind: .card, currency: .rub, isDefault: true)
    let today = DateOnly(year: 2026, month: 9, day: 27)
    let sheet = AccountPaymentsBlock.newPaymentSheet(
      on: kaspi.id, accounts: [main, kaspi], defaultCurrency: .usd, today: today)
    XCTAssertNil(sheet.editedPayment, "a new payment")
    let start = try XCTUnwrap(sheet.startingPayment)
    XCTAssertEqual(start.paymentMethodId, kaspi.id)
    XCTAssertEqual(start.currency, kzt, "the account's main currency")
    XCTAssertEqual(start.nextDate, today)
    XCTAssertFalse(sheet.startCurrencyChosen)

    let moved = ScheduledPaymentForm.choosing(
      sber, for: start, methods: [main, kaspi], cards: [],
      currencyChosen: sheet.startCurrencyChosen, defaultCurrency: .usd)
    XCTAssertEqual(moved.paymentMethodId, sber)
    XCTAssertEqual(moved.currency, .rub, "the currency follows the account picked")

    let unseen = UUID()
    let early = AccountPaymentsBlock.newPaymentSheet(
      on: unseen, accounts: [main], defaultCurrency: .usd, today: today)
    XCTAssertEqual(early.startingPayment?.paymentMethodId, unseen)
    XCTAssertEqual(
      early.startingPayment?.currency, .usd, "an account the data has not brought yet: the default")

    XCTAssertTrue(
      PlanningSheet.newPayment(ScheduledPayment(name: "Music", amountE4: .zero))
        .startCurrencyChosen, "a candidate's currency is the owner's")
  }
}
