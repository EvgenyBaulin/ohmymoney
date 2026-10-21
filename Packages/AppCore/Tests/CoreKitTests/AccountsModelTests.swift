import Foundation
import Testing

@testable import CoreKit

@Suite("An account holds an ordered set of currencies")
struct AccountCurrenciesTests {
  @Test func theMainCurrencyComesFirstAndEachCurrencyOnce() {
    let freedom = PaymentMethod(
      name: "Freedom", kind: .account, currency: .eur,
      otherCurrencies: [.usd, .rub, .eur, CurrencyCode("kzt"), .usd])
    #expect(freedom.mainCurrency == .eur)
    #expect(freedom.currencies == [.eur, .usd, .rub, CurrencyCode("KZT")])
    #expect(freedom.holds(CurrencyCode("KZT")))
    #expect(freedom.holds(.eur))
    #expect(!freedom.holds(CurrencyCode("GEL")))
  }

  /// An account saved without a currency counts as a ruble account.
  @Test func anAccountWithoutACurrencyHoldsRubles() {
    let card = PaymentMethod(name: "Card")
    #expect(card.currency == nil)
    #expect(card.mainCurrency == .rub)
    #expect(card.currencies == [.rub])
    #expect(card.holds(.rub))
    #expect(!card.holds(.usd))
  }

  @Test func theMainAccountIsTheDefaultOne() {
    #expect(PaymentMethod(name: "Card", isDefault: true).isMain)
    #expect(!PaymentMethod(name: "Cash").isMain)
  }
}

@Suite("Balances, transfers and legs")
struct AccountValuesTests {
  @Test func balanceKeysAreOrderedByAccountThenCurrency() throws {
    let first = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
    let second = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
    let keys = [
      BalanceKey(accountId: second, currency: .rub),
      BalanceKey(accountId: first, currency: .usd),
      BalanceKey(accountId: first, currency: .eur),
    ]
    #expect(
      keys.sorted() == [
        BalanceKey(accountId: first, currency: .eur),
        BalanceKey(accountId: first, currency: .usd),
        BalanceKey(accountId: second, currency: .rub),
      ])
  }

  @Test func anExchangeImpliesItsRate() {
    let account = UUID()
    let exchange = Transfer(
      occurredAt: Date(timeIntervalSince1970: 0), fromAccountId: account, fromCurrency: .rub,
      fromAmountE4: AmountE4(whole: 10_000), toAccountId: account,
      toCurrency: CurrencyCode("KZT"), toAmountE4: AmountE4(whole: 56_000))
    #expect(exchange.isExchange)
    #expect(exchange.impliedRate == Decimal(string: "5.6"))
    #expect(exchange.from == BalanceKey(accountId: account, currency: .rub))
    #expect(exchange.to == BalanceKey(accountId: account, currency: CurrencyCode("KZT")))

    let plain = Transfer(
      occurredAt: Date(timeIntervalSince1970: 0), fromAccountId: UUID(), fromCurrency: .rub,
      fromAmountE4: .zero, toAccountId: UUID(), toCurrency: .rub, toAmountE4: .zero)
    #expect(!plain.isExchange)
    #expect(plain.impliedRate == nil)
  }

  /// What moved on the account: its leg when the operation has one, its own amount otherwise.
  @Test func theMoneyMovedIsTheLegWhenThereIsOne() {
    var purchase = Transaction(
      kind: .expense, occurredAt: Date(timeIntervalSince1970: 0), currency: .usd,
      amountE4: AmountE4(whole: 10))
    #expect(purchase.movedMoney == Money(amount: AmountE4(whole: 10), currency: .usd))
    purchase.accountCurrency = .rub
    purchase.accountAmountE4 = AmountE4(whole: 950)
    #expect(purchase.movedMoney == Money(amount: AmountE4(whole: 950), currency: .rub))
  }

  @Test func aCountWithoutAnExpectedBalanceIsTheStartingPoint() {
    let start = ReconciledBalance(
      reconciliationId: UUID(), accountId: UUID(), currency: .rub, actualE4: AmountE4(whole: 1))
    #expect(start.isStartingPoint)
    #expect(start.key == BalanceKey(accountId: start.accountId, currency: .rub))
    let later = ReconciledBalance(
      reconciliationId: UUID(), accountId: UUID(), currency: .rub, actualE4: AmountE4(whole: 1),
      expectedE4: AmountE4(whole: 2), differenceE4: AmountE4(whole: -1))
    #expect(!later.isStartingPoint)
  }
}

@Suite("The settings of the accounts read from their rows")
struct AccountSettingsTests {
  @Test func nothingStoredMeansTheDefaults() {
    let settings = AccountSettings(storedValues: [:])
    #expect(settings.defaultCurrency == .rub)
    #expect(settings.setup == nil)
    #expect(settings.transferFeeCategoryId == nil)
    #expect(settings == AccountSettings())
  }

  @Test func storedValuesAreRead() {
    let category = UUID()
    let interest = UUID()
    let settings = AccountSettings(storedValues: [
      AccountSettings.defaultCurrencyKey: "kzt",
      AccountSettings.setupKey: "done",
      AccountSettings.transferFeeCategoryKey: category.uuidString,
      AccountSettings.interestCategoryKey: " \(interest.uuidString) ",
    ])
    #expect(settings.defaultCurrency == CurrencyCode("KZT"))
    #expect(settings.setup == .done)
    #expect(settings.transferFeeCategoryId == category)
    #expect(settings.interestCategoryId == interest)
    #expect(AccountSettings(storedValues: [AccountSettings.setupKey: "later"]).setup == .later)
  }

  /// A damaged value keeps its default rather than stopping anything.
  @Test func anUnreadableValueKeepsItsDefault() {
    let settings = AccountSettings(storedValues: [
      AccountSettings.defaultCurrencyKey: "rubles",
      AccountSettings.setupKey: "maybe",
      AccountSettings.transferFeeCategoryKey: "fees",
      AccountSettings.interestCategoryKey: "interest",
    ])
    #expect(settings == AccountSettings())
    #expect(
      AccountSettings(storedValues: [AccountSettings.defaultCurrencyKey: "U$D"]).defaultCurrency
        == .rub)
  }

  @Test func theKeysAreTheOnesOfTheSettingsTable() {
    #expect(
      AccountSettings.storageKeys == [
        "currencies.default", "accounts.setup", "transfers.feeCategory",
        "accounts.interestCategory",
      ])
  }
}

@Suite("Rates of a day, for one unit")
struct DayRatesTests {
  private let rates = DayRates(series: [
    .usd: [
      DayRate(day: DateOnly(year: 2026, month: 9, day: 16), perUnit: Decimal(string: "81.2")!),
      DayRate(day: DateOnly(year: 2026, month: 9, day: 10), perUnit: Decimal(string: "80.1")!),
      DayRate(day: DateOnly(year: 2026, month: 9, day: 12), perUnit: Decimal(string: "80.5")!),
    ],
    // A rate quoted for 100 tenge is kept for one.
    CurrencyCode("KZT"): [
      DayRate(day: DateOnly(year: 2026, month: 9, day: 12), perUnit: Decimal(string: "0.1563")!)
    ],
  ])

  @Test func theRubleIsOne() {
    #expect(rates.perUnit(.rub, on: DateOnly(year: 2000, month: 1, day: 1)) == 1)
    #expect(DayRates.empty.perUnit(.rub, on: DateOnly(year: 2026, month: 1, day: 1)) == 1)
  }

  private func september(_ day: Int) -> DateOnly { DateOnly(year: 2026, month: 9, day: day) }

  @Test func theNearestDayOnOrBeforeIsTaken() {
    #expect(rates.perUnit(.usd, on: september(12)) == Decimal(string: "80.5"))
    #expect(rates.perUnit(.usd, on: september(14)) == Decimal(string: "80.5"))
    #expect(rates.perUnit(.usd, on: september(30)) == Decimal(string: "81.2"))
    #expect(rates.perUnit(CurrencyCode("KZT"), on: september(20)) == Decimal(string: "0.1563"))
  }

  /// A day earlier than every rate known takes the first one.
  @Test func aDayBeforeEveryRateTakesTheFirst() {
    #expect(rates.perUnit(.usd, on: september(1)) == Decimal(string: "80.1"))
  }

  @Test func aCurrencyWithoutRatesHasNone() {
    #expect(rates.perUnit(.eur, on: DateOnly(year: 2026, month: 9, day: 16)) == nil)
    #expect(DayRates.empty.perUnit(.usd, on: DateOnly(year: 2026, month: 9, day: 16)) == nil)
  }
}
