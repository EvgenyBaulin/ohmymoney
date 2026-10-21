import CoreAccounting
import CoreKit
import Foundation
import Testing

@testable import CoreAnalytics

/// September 2026 of three card accounts, the rules of their cards (T-Bank's cards keep rules of
/// their own, Sber's and Kaspi's rules are the accounts') and a cashback received in October for
/// September. All round to the kopeck, as 1.2 did. Synthetic names only; rubles unless said.
struct CashbackBook {
  static let tBank = id(1)
  static let sber = id(2)
  static let kaspi = id(3)
  static let black = id(11)
  static let virtual = id(12)
  static let sberCard = id(21)
  static let kaspiCard = id(31)

  static let cafes = id(200)
  static let coffee = id(201)
  static let supermarkets = id(202)
  static let health = id(203)
  static let pharmacy = id(204)
  static let home = id(205)
  static let subscriptions = id(206)
  static let clothes = id(207)
  static let loans = id(208)
  static let cinema = id(209)
  static let cashback = id(213)
  static let place = id(400)

  static let september = MonthKey(year: 2026, month: 9)
  static let october = MonthKey(year: 2026, month: 10)
  static let kzt = CurrencyCode("KZT")

  static let categories: [CoreKit.Category] = [
    CoreKit.Category(id: cafes, kind: .expense, name: "Cafes"),
    CoreKit.Category(id: coffee, parentId: cafes, kind: .expense, name: "Coffee"),
    CoreKit.Category(id: supermarkets, kind: .expense, name: "Supermarkets"),
    CoreKit.Category(id: health, kind: .expense, name: "Health"),
    CoreKit.Category(id: pharmacy, parentId: health, kind: .expense, name: "Pharmacy"),
    CoreKit.Category(id: home, kind: .expense, name: "Home"),
    CoreKit.Category(id: subscriptions, kind: .expense, name: "Subscriptions"),
    CoreKit.Category(id: clothes, kind: .expense, name: "Clothes"),
    CoreKit.Category(id: loans, kind: .expense, name: "Loans", systemRole: .loans),
    CoreKit.Category(id: cinema, kind: .expense, name: "Cinema"),
    CoreKit.Category(id: cashback, kind: .income, name: "Cashback"),
  ]

  static let kopecks = CashbackRounding(precision: .cents)

  static let accounts = [
    PaymentMethod(id: tBank, name: "T-Bank", kind: .card, cashbackRounding: kopecks),
    PaymentMethod(
      id: sber, name: "Sber", kind: .card, isDefault: true, cashbackRounding: kopecks),
    PaymentMethod(id: kaspi, name: "Kaspi", kind: .card, currency: kzt, cashbackRounding: kopecks),
  ]

  static let cards = [
    PaymentCard(id: black, accountId: tBank, name: "Black"),
    PaymentCard(id: virtual, accountId: tBank, name: "Virtual"),
    PaymentCard(id: sberCard, accountId: sber, name: "Sber"),
    PaymentCard(id: kaspiCard, accountId: kaspi, name: "Kaspi"),
  ]

  static func rule(
    _ number: Int, _ account: UUID, _ card: UUID?, _ category: UUID?, _ month: MonthKey?,
    _ e4: Int64
  ) -> CashbackRule {
    CashbackRule(
      id: id(number), accountId: account, cardId: card, categoryId: category, month: month,
      percent: CashbackPercent(e4: e4)!)
  }

  static let rules = [
    rule(301, tBank, black, cafes, nil, 50_000),
    rule(302, tBank, black, coffee, nil, 30_000),
    rule(303, tBank, black, cafes, september, 100_000),
    rule(304, tBank, black, supermarkets, september, 30_000),
    rule(305, tBank, black, loans, nil, 0),
    rule(306, tBank, black, nil, nil, 10_000),
    rule(311, tBank, virtual, pharmacy, nil, 70_000),
    rule(312, tBank, virtual, nil, september, 30_000),
    rule(313, tBank, virtual, nil, nil, 15_000),
    rule(321, sber, nil, nil, nil, 5_000),
    rule(331, kaspi, nil, nil, nil, 20_000),
  ]

  static func at(_ dayAndMonth: String) -> Date {
    CalendarContext.utc.noon(of: DateOnly(iso: "2026-" + dayAndMonth)!)
  }

  static func operation(
    _ number: Int, _ kind: TransactionKind = .expense, on dayAndMonth: String,
    currency: CurrencyCode = .rub, parts: [(UUID?, String)], account: UUID?, card: UUID? = nil,
    leg: String? = nil, rubles: String? = nil, cashback: String? = nil,
    refundOf: UUID? = nil, period: MonthKey? = nil, place: UUID? = nil
  ) -> TransactionEntry {
    let transactionId = id(number)
    let amounts = parts.map { money($0.1) }
    let total = AmountE4.sum(amounts)
    let rub = rubles.map(money) ?? leg.map(money) ?? total
    let transaction = Transaction(
      id: transactionId, kind: kind, occurredAt: at(dayAndMonth), currency: currency,
      amountE4: total, amountRubE4: rub, placeId: place, paymentMethodId: account,
      accountCurrency: leg == nil ? nil : .rub, accountAmountE4: leg.map(money),
      periodMonth: period, createdAt: at(dayAndMonth), updatedAt: at(dayAndMonth), cardId: card,
      cashback: cashback.map { Money(amount: money($0), currency: .rub) })
    let shares = rub.allocated(proportionallyTo: amounts, outOf: total)
    let built = parts.indices.map { index in
      TransactionPart(
        id: id(number * 10 + index), transactionId: transactionId, categoryId: parts[index].0,
        amountE4: amounts[index], amountRubE4: shares[index],
        refundOfPartId: index == 0 ? refundOf : nil)
    }
    return TransactionEntry(transaction: transaction, parts: built)
  }

  /// Black: 35.00 + 89.70 + 12.35 + 70.00 + 18.50 + 60.00 − 5.00 + 0.00 = 280.55;
  /// Virtual: 70.00 + 30.00 = 100.00; Sber's account: 0.30; Kaspi's: 100 ₸ = 18.00 ₽.
  static let entries: [TransactionEntry] = [
    operation(1001, on: "09-12", parts: [(coffee, "350")], account: tBank, card: black),
    operation(1002, on: "09-13", parts: [(supermarkets, "2990")], account: tBank, card: black),
    operation(1003, on: "09-14", parts: [(pharmacy, "1234.56")], account: tBank, card: black),
    operation(
      1004, on: "09-15", parts: [(supermarkets, "2000"), (home, "1000")], account: tBank,
      card: black),
    operation(
      1005, on: "09-16", currency: .usd, parts: [(subscriptions, "20")], account: tBank,
      card: black, leg: "1850"),
    operation(
      1006, on: "09-20", parts: [(clothes, "10000")], account: tBank, card: black, place: place),
    operation(
      1007, .refund, on: "10-05", parts: [(clothes, "4000")], account: tBank, card: black,
      refundOf: id(10060), place: place),
    operation(1008, .refund, on: "09-22", parts: [(clothes, "500")], account: tBank, card: black),
    operation(1009, on: "09-25", parts: [(loans, "15000")], account: tBank, card: black),
    operation(1010, on: "09-14", parts: [(pharmacy, "1000")], account: tBank, card: virtual),
    operation(1011, on: "09-14", parts: [(cinema, "1000")], account: tBank, card: virtual),
    operation(1012, on: "09-12", parts: [(home, "60")], account: sber),
    operation(
      1013, on: "09-17", currency: kzt, parts: [(cinema, "5000")], account: kaspi,
      rubles: "900"),
    operation(
      1014, .income, on: "10-05", parts: [(cashback, "250")], account: tBank, card: black,
      period: september),
    operation(1015, .income, on: "09-28", parts: [(cashback, "40")], account: sber),
  ]

  static func dataset(
    entries: [TransactionEntry] = entries, rules: [CashbackRule] = rules
  ) -> Dataset {
    Dataset(
      entries: entries, categories: categories, places: [Place(id: place, name: "Shop")],
      paymentMethods: accounts, settings: AnalyticsSettings(cashbackCategoryId: cashback),
      cards: cards, cashbackRules: rules)
  }

  static func ledger(
    entries: [TransactionEntry] = entries, rules: [CashbackRule] = rules
  ) -> Ledger {
    Ledger(dataset: dataset(entries: entries, rules: rules), calendar: .utc)
  }
}

/// Expected cashback by card and month next to what was received, as the account's screen and
/// Analytics «Оборот и кэшбэк» show them.
@Suite("Cashback by card and month")
struct CashbackReportTests {
  let report = CashbackReport(
    ledger: CashbackBook.ledger(), period: .month(CashbackBook.september))

  func line(_ account: UUID, _ card: UUID? = nil) -> CashbackReport.Cell? {
    report.byHolder().first { $0.holder == CashbackHolderKey(accountId: account, cardId: card) }
  }

  @Test func expectedByHolderAndMonth() throws {
    let black = try #require(line(CashbackBook.tBank, CashbackBook.black))
    #expect(black.expectedRub == money("280.55"))
    #expect(black.expected == [.rub: money("280.55")])
    let virtual = try #require(line(CashbackBook.tBank, CashbackBook.virtual))
    #expect(virtual.expectedRub == money("100"))
    // Analytics shows whole rubles: 380.55 → 381.
    #expect(report.expectedRub(ofAccount: CashbackBook.tBank) == money("380.55"))
    // The purchases that name no card are the account's own line: Kaspi's rule is the account's.
    let kaspi = try #require(line(CashbackBook.kaspi))
    #expect(kaspi.expected == [CashbackBook.kzt: money("100")] && kaspi.expectedRub == money("18"))
    #expect(line(CashbackBook.kaspi, CashbackBook.kaspiCard) == nil)
    #expect(report.hasRules)
  }

  @Test func receivedByTheCardTheIncomeNames() throws {
    let black = try #require(line(CashbackBook.tBank, CashbackBook.black))
    #expect(black.receivedRub == money("250") && black.received == [.rub: money("250")])
    #expect(line(CashbackBook.tBank, CashbackBook.virtual)?.receivedRub == .zero)
  }

  /// Neither the purchases nor the income name a card: both are the account's own line, though
  /// the account has a card — a card is only what paid.
  @Test func receivedWithoutACardGoesToTheAccountsLine() throws {
    let sber = try #require(line(CashbackBook.sber))
    #expect(sber.receivedRub == money("40"))
    #expect(sber.expectedRub == money("0.3"))
    #expect(line(CashbackBook.sber, CashbackBook.sberCard) == nil)
  }

  /// The lines of an account add up to its row of «Оборот и кэшбэк», and the expected column
  /// there is the sum of its lines.
  @Test func turnoverByCardsAddsUpToTheAccount() throws {
    let methods = PaymentMethodsReport(
      ledger: CashbackBook.ledger(), period: .month(CashbackBook.september))
    let tBank = try #require(
      methods.methods.first { $0.key == .paymentMethod(CashbackBook.tBank) })
    let lines = report.byHolder().filter { $0.holder.accountId == CashbackBook.tBank }
    #expect(AmountE4.sum(lines.map(\.turnover)) == tBank.turnover)
    #expect(AmountE4.sum(lines.map(\.mySpending)) == tBank.mySpending)
    #expect(tBank.expectedCashback == money("380.55"))
    #expect(tBank.cashback == money("250"))
  }

  /// The jacket of 10,000 with 4,000 returned on 05.10 earns 60.00 in September, on Black.
  @Test func refundFoldedIntoThePurchasesMonthAndCard() throws {
    let october = CashbackReport(
      ledger: CashbackBook.ledger(), period: .month(CashbackBook.october))
    // The refund of October earns and takes nothing on its own day.
    #expect(october.cells.allSatisfy { $0.expected.isEmpty })
    let jacketOnly = CashbackBook.entries.filter {
      [id(1006), id(1007)].contains($0.id)
    }
    let alone = CashbackReport(
      ledger: CashbackBook.ledger(entries: jacketOnly), period: .month(CashbackBook.september))
    #expect(alone.cells.map(\.expectedRub) == [money("60")])
    #expect(
      alone.cells.first?.holder
        == CashbackHolderKey(accountId: CashbackBook.tBank, cardId: CashbackBook.black))
  }

  /// The cashback of September arrives in October and is filed under September: received by
  /// the month it is for, expected by the month of the purchase. Difference = received −
  /// expected: 250 − 380.55 = −130.55.
  @Test func receivedByPeriodMonthExpectedByPurchaseMonth() {
    let months = report.byMonth(accountId: CashbackBook.tBank)
    #expect(months.count == 1)
    #expect(months.first?.month == CashbackBook.september)
    #expect(months.first?.expectedRub == money("380.55"))
    #expect(months.first?.receivedRub == money("250"))
    let all = report.byMonth()
    #expect(all.first?.expectedRub == money("398.85") && all.first?.receivedRub == money("290"))
    let black = report.byMonth(cardId: CashbackBook.black)
    #expect(black.first?.expectedRub == money("280.55"))
  }

  @Test func noRulesMeansNoExpectedButReceivedStays() throws {
    let bare = CashbackReport(
      ledger: CashbackBook.ledger(rules: []), period: .month(CashbackBook.september))
    #expect(!bare.hasRules)
    #expect(bare.cells.allSatisfy { $0.expected.isEmpty && $0.expectedRub.isZero })
    #expect(AmountE4.sum(bare.cells.map(\.receivedRub)) == money("290"))
  }

  /// The block of T-Bank's screen: the account's own line first — its rules are the ones every
  /// card follows —, then a line for each live card that keeps rules of its own.
  @Test func theAccountScreensLinesAreTheAccountThenItsCardsWithRulesOfTheirOwn() {
    let lines = AccountCashbackSummary.month(
      CashbackBook.september, accountId: CashbackBook.tBank, ledger: CashbackBook.ledger())
    #expect(lines.map(\.holder.cardId) == [nil, CashbackBook.black, CashbackBook.virtual])
    #expect(lines.map(\.expectedRub) == [.zero, money("280.55"), money("100")])
    // A purchase naming no card on an account with two cards is the account's own line.
    let plain = CashbackBook.operation(
      1020, on: "09-18", parts: [(CashbackBook.home, "300")], account: CashbackBook.tBank)
    let more = AccountCashbackSummary.month(
      CashbackBook.september, accountId: CashbackBook.tBank,
      ledger: CashbackBook.ledger(entries: CashbackBook.entries + [plain]))
    #expect(more.map(\.holder.cardId) == [nil, CashbackBook.black, CashbackBook.virtual])
    #expect(more[0].turnover == money("300") && more[0].expected.isEmpty)
    // A month with nothing in it still shows the line of the account — and not its card, which
    // holds no rules of its own and was not named.
    let quiet = AccountCashbackSummary.month(
      CashbackBook.october, accountId: CashbackBook.kaspi, ledger: CashbackBook.ledger())
    #expect(quiet.map(\.holder.cardId) == [nil])
  }
}
