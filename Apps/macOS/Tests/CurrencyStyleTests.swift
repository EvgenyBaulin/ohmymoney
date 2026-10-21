import AppCore
import XCTest

@testable import OhMyMoney

/// «Оформление → Валюта»: an amount names its currency by its sign (as always), by its code, or
/// by its short Russian name — only in Russian; in English «Название» writes the code. Every
/// amount `MoneyFormatter` writes follows it; the sign of a field and the mask of «Скрыть суммы»
/// do not change.
@MainActor
final class CurrencyStyleTests: XCTestCase {
  private let ru = Locale(identifier: "ru")
  private let en = Locale(identifier: "en")
  private let amount = AmountE4(whole: 1_250)

  func testTheSymbolIsTheDefaultAndWritesAsBefore() {
    let money = MoneyFormatter(locale: ru)
    XCTAssertEqual(money.currencyStyle, .symbol)
    XCTAssertEqual(money.exact(amount), "1,250\u{00A0}₽")
    XCTAssertEqual(money.exact(amount, currency: .usd), "1,250\u{00A0}$")
    XCTAssertEqual(money.rounded(amount, currency: CurrencyCode("EUR")), "1,250\u{00A0}€")
    XCTAssertEqual(money.rubles(1_250), "1,250\u{00A0}₽")
    XCTAssertEqual(money.axis(1_200_000), "1.2\u{00A0}млн\u{00A0}₽")
  }

  func testTheCodeStandsAfterEveryKindOfAmount() {
    for locale in [ru, en] {
      let money = MoneyFormatter(locale: locale, currencyStyle: .code)
      XCTAssertEqual(money.exact(amount), "1,250\u{00A0}RUB")
      XCTAssertEqual(money.exact(amount, currency: .usd), "1,250\u{00A0}USD")
      XCTAssertEqual(money.rounded(AmountE4(whole: -40), currency: .usd), "−40\u{00A0}USD")
      XCTAssertEqual(money.rubles(3_400), "3,400\u{00A0}RUB")
      XCTAssertEqual(money.signedRubles(3_400), "+3,400\u{00A0}RUB")
      XCTAssertEqual(money.signedRounded(AmountE4(whole: -1_200)), "−1,200\u{00A0}RUB")
      XCTAssertTrue(money.axis(2_000_000).hasSuffix("\u{00A0}RUB"), money.axis(2_000_000))
    }
  }

  func testTheNameIsRussianOnlyInRussian() {
    let russian = MoneyFormatter(locale: ru, currencyStyle: .name)
    XCTAssertEqual(russian.exact(amount), "1,250\u{00A0}руб.")
    XCTAssertEqual(russian.exact(amount, currency: .usd), "1,250\u{00A0}долл.")
    XCTAssertEqual(russian.rounded(amount, currency: CurrencyCode("EUR")), "1,250\u{00A0}евро")
    XCTAssertEqual(russian.rubles(10), "10\u{00A0}руб.")
    // A currency without a Russian word the app knows is written by its code.
    XCTAssertEqual(russian.exact(amount, currency: CurrencyCode("SEK")), "1,250\u{00A0}SEK")

    let english = MoneyFormatter(locale: en, currencyStyle: .name)
    XCTAssertEqual(english.exact(amount), "1,250\u{00A0}RUB")
    XCTAssertEqual(english.exact(amount, currency: .usd), "1,250\u{00A0}USD")
  }

  /// Every currency the settings offer has a short Russian name.
  func testEveryOfferedCurrencyHasARussianName() {
    let offered =
      CurrencyCode.defaultEnabled.map(\.code)
      + ["GBP", "JPY", "CHF", "PLN", "UAH", "BYN", "KGS", "UZS", "AZN", "RSD"]
    for code in offered {
      XCTAssertNotNil(CurrencyStyle.russianNames[code], "no Russian name for \(code)")
    }
  }

  /// The sign beside a field where an amount is typed, and the list of currencies, stay signs.
  func testTheSignOfAFieldIsTheSymbolWhateverTheStyle() {
    for style in CurrencyStyle.allCases {
      let money = MoneyFormatter(locale: ru, currencyStyle: style)
      XCTAssertEqual(money.symbol(for: .rub), "₽")
      XCTAssertEqual(money.symbol(for: .usd), "$")
    }
  }

  /// «Скрыть суммы» hides the figure and its currency whatever the style.
  func testHiddenAmountsStayTheMask() {
    for style in CurrencyStyle.allCases {
      let money = MoneyFormatter(locale: ru, hidesAmounts: true, currencyStyle: style)
      XCTAssertEqual(money.exact(amount), MoneyFormatter.mask)
      XCTAssertEqual(money.rounded(amount, currency: .usd), MoneyFormatter.mask)
      XCTAssertEqual(money.rubles(5), MoneyFormatter.mask)
      XCTAssertEqual(money.axis(5_000_000), MoneyFormatter.mask)
    }
  }

  /// The money of the app follows the choice at once.
  func testTheMoneyOfTheEnvironmentFollowsTheChoice() {
    let environment = AppEnvironment()
    environment.language.choice = .russian
    defer { environment.language.choice = .system }
    XCTAssertEqual(environment.money.exact(amount), "1,250\u{00A0}₽")
    environment.theme.currencyStyle = .code
    XCTAssertEqual(environment.money.exact(amount), "1,250\u{00A0}RUB")
    environment.theme.currencyStyle = .name
    XCTAssertEqual(environment.money.exact(amount), "1,250\u{00A0}руб.")
  }

  /// A word kept from another build reads as the default; the test host never keeps a choice.
  func testTheStoredStyleReadsSafelyAndTheTestHostKeepsNone() {
    let defaults = UserDefaults(suiteName: "ohmymoney.tests.currencyStyle.\(UUID().uuidString)")!
    XCTAssertEqual(CurrencyStyle.stored(in: defaults), .symbol)
    defaults.set("code", forKey: CurrencyStyle.key)
    XCTAssertEqual(CurrencyStyle.stored(in: defaults), .code)
    defaults.set("emoji", forKey: CurrencyStyle.key)
    XCTAssertEqual(CurrencyStyle.stored(in: defaults), .symbol)
    XCTAssertEqual(CurrencyStyle.stored(in: nil), .symbol)

    let before = UserDefaults.standard.object(forKey: CurrencyStyle.key)
    let theme = AppTheme()
    theme.currencyStyle = .name
    XCTAssertEqual(
      UserDefaults.standard.object(forKey: CurrencyStyle.key) as? String, before as? String,
      "the test host wrote the owner's choice")
    XCTAssertEqual(AppTheme().currencyStyle, .symbol)
  }

  /// The choices of the settings show what each writes.
  func testTheChoicesOfTheSettingsShowWhatTheyWrite() {
    let environment = AppEnvironment()
    environment.language.choice = .russian
    defer { environment.language.choice = .system }
    XCTAssertEqual(
      AppearanceSettingsView.currencyStyleTitle(.code, environment), "Код — 1,250\u{00A0}RUB")
    XCTAssertEqual(
      AppearanceSettingsView.currencyStyleTitle(.name, environment),
      "Название — 1,250\u{00A0}руб.")
    environment.language.choice = .english
    XCTAssertEqual(
      AppearanceSettingsView.currencyStyleTitle(.symbol, environment), "Symbol — 1,250\u{00A0}₽")
  }
}
