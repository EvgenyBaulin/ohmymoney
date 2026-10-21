import AppCore
import Foundation
import XCTest

@testable import OhMyMoney

/// The rates the data step hands to the planning: today's for what is shown in rubles, and the
/// rates by day for what happened on a day in another currency — both in rubles for one unit.
final class SnapshotRatesTests: XCTestCase {
  private let today = DateOnly(year: 2026, month: 9, day: 19)
  private let tenge = CurrencyCode("KZT")

  private func day(_ number: Int) -> DateOnly { DateOnly(year: 2026, month: 9, day: number) }

  private func noon(_ number: Int) -> Date {
    CalendarContext.utc.startOfDay(day(number)).addingTimeInterval(12 * 3600)
  }

  /// The bank quotes 100 tenge: 18.5 ₽ on the 1st, 19 ₽ on the 10th.
  private var table: RateTable {
    RateTable(rates: [
      Rate(date: day(1), currency: tenge, rubPerUnit: Decimal(string: "18.5")!, nominal: 100),
      Rate(date: day(10), currency: tenge, rubPerUnit: 19, nominal: 100),
      Rate(date: day(10), currency: .usd, rubPerUnit: 95),
      Rate(date: day(10), currency: .eur, rubPerUnit: 105),
      Rate(date: day(10), currency: CurrencyCode("CNY"), rubPerUnit: 13),
    ])
  }

  private let goal = Goal(
    name: "Almaty", targetE4: AmountE4(whole: 100_000), currency: CurrencyCode("KZT"))

  /// A tenge rate is kept for one tenge, today's and each day's; the currencies of goals,
  /// accounts and transfers get today's rate too, and a currency nothing counts in is not
  /// carried by day.
  func testATengeRateIsKeptForOneTenge() {
    let dataset = Dataset(
      paymentMethods: [
        PaymentMethod(name: "Kaspi", currency: tenge, isDefault: true, otherCurrencies: [.usd])
      ],
      goals: [goal],
      transfers: [
        Transfer(
          occurredAt: noon(12), fromAccountId: UUID(), fromCurrency: .eur,
          fromAmountE4: AmountE4(whole: 1), toAccountId: UUID(), toCurrency: .eur,
          toAmountE4: AmountE4(whole: 1))
      ])
    let context = SnapshotContext(dataset: dataset, rates: table, today: today)

    XCTAssertEqual(context.rubPerUnit[tenge], Decimal(string: "0.19"))
    XCTAssertEqual(context.rubPerUnit[.usd], 95)
    XCTAssertEqual(context.rubPerUnit[.eur], 105)
    XCTAssertNil(context.rubPerUnit[CurrencyCode("CNY")])
    XCTAssertEqual(context.dayRates.perUnit(tenge, on: day(5)), Decimal(string: "0.185"))
    XCTAssertEqual(context.dayRates.perUnit(tenge, on: day(12)), Decimal(string: "0.19"))
    XCTAssertEqual(context.dayRates.perUnit(.usd, on: day(12)), 95)
    XCTAssertNil(context.dayRates.perUnit(CurrencyCode("CNY"), on: day(12)))
    // The enabled currencies are carried by day as well.
    let enabled = SnapshotContext(
      dataset: Dataset(), rates: table, today: today, also: [CurrencyCode("CNY")])
    XCTAssertEqual(enabled.dayRates.perUnit(CurrencyCode("CNY"), on: day(12)), 13)
  }

  /// The capital counts a debt and an asset at the rate of each past month end: their
  /// currencies are carried by day, not only today.
  func testTheCurrenciesOfDebtsAndAssetsAreCarriedByDay() {
    let yuan = CurrencyCode("CNY")
    let dataset = Dataset(
      debts: [Debt(direction: .iOwe, type: .loan, name: "Loan", currency: .usd)],
      assets: [Asset(name: "Car", kind: .vehicle, currency: yuan)])
    let context = SnapshotContext(dataset: dataset, rates: table, today: today)
    XCTAssertEqual(context.dayRates.perUnit(.usd, on: day(12)), 95)
    XCTAssertEqual(context.dayRates.perUnit(yuan, on: day(12)), 13)
    XCTAssertEqual(context.rubPerUnit[yuan], 13)
    XCTAssertNil(
      SnapshotContext(dataset: Dataset(), rates: table, today: today).dayRates.perUnit(
        .usd, on: day(12)),
      "a currency nothing counts in is not carried by day")
  }

  /// The default currency always has today's rate, even when nothing else counts in it and the
  /// enabled currencies could not be read: «≈ N» of another currency is written in it.
  func testTheDefaultCurrencyIsInTheRateSet() {
    let yuan = CurrencyCode("CNY")
    let dataset = Dataset(accountSettings: AccountSettings(defaultCurrency: yuan))
    let context = SnapshotContext(dataset: dataset, rates: table, today: today)
    XCTAssertEqual(context.rubPerUnit[yuan], 13)
    XCTAssertNil(
      SnapshotContext(dataset: Dataset(), rates: table, today: today).rubPerUnit[yuan],
      "a currency nothing counts in gets no rate")
  }

  /// 1 000 ₽ put into the tenge goal on the 5th are 1 000 ÷ 0.185 = 5 405.4054 ₸; the
  /// snapshot shows them in rubles at today's 0.19 ₽ and carries the accounts and the rates.
  func testTheSnapshotCountsAGoalInTengeAtTheRateOfItsDay() throws {
    let goalsRoot = CoreKit.Category(kind: .expense, name: "Goals", systemRole: .goals)
    let id = UUID()
    let entry = TransactionEntry(
      transaction: Transaction(
        id: id, kind: .expense, occurredAt: noon(5), currency: .rub,
        amountE4: AmountE4(whole: 1000), amountRubE4: AmountE4(whole: 1000), createdAt: noon(5),
        updatedAt: noon(5)),
      parts: [
        TransactionPart(
          transactionId: id, categoryId: goalsRoot.id, quality: .good, qualitySource: .system,
          amountE4: AmountE4(whole: 1000), amountRubE4: AmountE4(whole: 1000), goalId: goal.id)
      ])
    let kaspi = PaymentMethod(name: "Kaspi", currency: tenge, isDefault: true)
    let dataset = Dataset(
      entries: [entry], categories: [goalsRoot], paymentMethods: [kaspi], goals: [goal])
    let context = SnapshotContext(
      dataset: dataset, rates: table, today: today, localeIdentifier: "ru")
    let snapshot = DataSnapshot.build(
      dataset: dataset, calendar: .utc, today: today, context: context,
      version: DataVersion(load: 0), now: noon(19))

    let status = try XCTUnwrap(snapshot.planning.goals.first)
    XCTAssertEqual(status.currency, tenge)
    XCTAssertEqual(status.saved, try AmountE4(decimal: Decimal(string: "5405.4054")!))
    XCTAssertEqual(status.savedRubToday, try AmountE4(decimal: Decimal(string: "1027.027")!))
    XCTAssertEqual(snapshot.planning.dayRates, context.dayRates)
    XCTAssertEqual(snapshot.planning.accounts.sections.first?.accounts.first?.account.id, kaspi.id)
    XCTAssertEqual(snapshot.context.localeIdentifier, "ru")
  }

  /// The language the names are ordered in is read where the choice is stored.
  func testTheLanguageIsReadWhereTheChoiceIsStored() throws {
    let name = "SnapshotRatesTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    defaults.set("ru", forKey: "app.language")
    XCTAssertEqual(ComputeSources.interfaceLanguage(defaults), "ru")
    defaults.set("en", forKey: "app.language")
    XCTAssertEqual(ComputeSources.interfaceLanguage(defaults), "en")
    defaults.set("system", forKey: "app.language")
    XCTAssertTrue(["ru", "en"].contains(ComputeSources.interfaceLanguage(defaults)))
  }

  /// Read off the main thread, the language is the one the interface resolves from the same
  /// stored choice, so the accounts are ordered as the menus order them.
  @MainActor
  func testTheLanguageIsTheOneOfTheInterface() {
    XCTAssertEqual(ComputeSources.interfaceLanguage(), AppLanguage().resolvedCode)
  }
}
