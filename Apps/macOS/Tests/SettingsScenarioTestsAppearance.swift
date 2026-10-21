import AppCore
import SwiftUI
import XCTest

@testable import OhMyMoney

/// How an amount reads in both languages and in each of the three styles of its currency:
/// thousands with a comma, a dot before the fraction, the typographic minus, rounding half
/// away from zero, the compact axis of a chart at the edges of a million and a billion.
final class SettingsScenarioMoneyTextTests: XCTestCase {
  private let nbsp = "\u{00A0}"
  private let ru = MoneyFormatter(locale: Locale(identifier: "ru"))
  private let en = MoneyFormatter(locale: Locale(identifier: "en"))

  func testAWholeAmountHasNoFraction() {
    XCTAssertEqual(ru.exact(AmountE4(whole: 250)), "250\(nbsp)₽")
    XCTAssertEqual(en.exact(AmountE4(whole: 250)), "250\(nbsp)₽")
  }

  func testAFractionHasAtLeastTwoDigitsAndAtMostFour() {
    XCTAssertEqual(en.exact(AmountE4(raw: 12_345_000)), "1,234.50\(nbsp)₽")
    XCTAssertEqual(en.exact(AmountE4(raw: 46_250)), "4.625\(nbsp)₽")
    XCTAssertEqual(en.exact(AmountE4(raw: 1)), "0.0001\(nbsp)₽")
    XCTAssertEqual(en.exact(AmountE4(raw: 10_100)), "1.01\(nbsp)₽")
  }

  func testNumbersAreWrittenOneWayInBothLanguages() {
    let amount = AmountE4(raw: 98_765_432_100)
    XCTAssertEqual(ru.exact(amount), en.exact(amount))
    XCTAssertEqual(ru.exact(amount), "9,876,543.21\(nbsp)₽")
  }

  func testTheMinusIsTypographic() {
    XCTAssertEqual(en.exact(AmountE4(whole: -1_500)), "\u{2212}1,500\(nbsp)₽")
    XCTAssertEqual(en.signedRubles(-1_200), "\u{2212}1,200\(nbsp)₽")
    XCTAssertFalse(en.exact(AmountE4(whole: -5)).contains("-"))
  }

  func testASignedDifferenceHasItsSignAndZeroNone() {
    XCTAssertEqual(en.signedRubles(3_400), "+3,400\(nbsp)₽")
    XCTAssertEqual(en.signedRubles(0), "0\(nbsp)₽")
    XCTAssertEqual(en.signedRounded(AmountE4(raw: -4_000)), "0\(nbsp)₽", "−0.40 is no minus")
    XCTAssertEqual(en.signedRounded(AmountE4(raw: -5_000)), "\u{2212}1\(nbsp)₽")
  }

  /// Half a ruble goes away from zero, on both sides of it.
  func testRoundingIsHalfAwayFromZero() {
    XCTAssertEqual(en.rounded(AmountE4(raw: 25_000)), "3\(nbsp)₽")
    XCTAssertEqual(en.rounded(AmountE4(raw: 24_999)), "2\(nbsp)₽")
    XCTAssertEqual(en.rounded(AmountE4(raw: -25_000)), "\u{2212}3\(nbsp)₽")
    XCTAssertEqual(en.rounded(AmountE4(raw: 9_999_995_000)), "1,000,000\(nbsp)₽")
  }

  func testTheAxisBelowAMillionIsWholeRubles() {
    XCTAssertEqual(en.axis(999_999), "999,999\(nbsp)₽")
    XCTAssertEqual(en.axis(-999_999), "\u{2212}999,999\(nbsp)₽")
  }

  func testTheAxisFromAMillionIsCompactInTheWordsOfTheLanguage() {
    XCTAssertEqual(en.axis(1_000_000), "1M\(nbsp)₽")
    XCTAssertEqual(ru.axis(1_000_000), "1\(nbsp)млн\(nbsp)₽")
    XCTAssertEqual(en.axis(1_250_000), "1.3M\(nbsp)₽")
    XCTAssertEqual(ru.axis(2_500_000_000), "2.5\(nbsp)млрд\(nbsp)₽")
  }

  /// 999 950 000 rounds to a thousand millions: it is written as one billion.
  func testTheUnitOfTheAxisFollowsTheRoundedFigure() {
    XCTAssertEqual(en.axis(999_950_000), "1B\(nbsp)₽")
    XCTAssertEqual(en.axis(999_940_000), "999.9M\(nbsp)₽")
  }

  func testAPercentHasASpaceInRussianOnly() {
    XCTAssertEqual(ru.percent(basisPoints: 1_250), "12.5\(nbsp)%")
    XCTAssertEqual(en.percent(basisPoints: 1_250), "12.5%")
    XCTAssertEqual(en.signedPercent(basisPoints: -534), "\u{2212}5.3%")
    XCTAssertEqual(en.signedPercent(basisPoints: 0), "0.0%")
  }

  func testEachStyleWritesItsUnit() {
    let amount = AmountE4(whole: 100)
    let symbol = MoneyFormatter(locale: Locale(identifier: "ru"), currencyStyle: .symbol)
    let code = MoneyFormatter(locale: Locale(identifier: "ru"), currencyStyle: .code)
    let name = MoneyFormatter(locale: Locale(identifier: "ru"), currencyStyle: .name)
    XCTAssertEqual(symbol.exact(amount, currency: .usd), "100\(nbsp)$")
    XCTAssertEqual(code.exact(amount, currency: .usd), "100\(nbsp)USD")
    XCTAssertEqual(name.exact(amount, currency: .usd), "100\(nbsp)долл.")
    XCTAssertEqual(name.exact(amount, currency: .eur), "100\(nbsp)евро")
  }

  /// English writes the code where Russian writes a name.
  func testTheNameStyleInEnglishWritesTheCode() {
    let name = MoneyFormatter(locale: Locale(identifier: "en"), currencyStyle: .name)
    XCTAssertEqual(name.exact(AmountE4(whole: 5), currency: .rub), "5\(nbsp)RUB")
    XCTAssertEqual(name.exact(AmountE4(whole: 5), currency: CurrencyCode("KZT")), "5\(nbsp)KZT")
  }

  /// A currency without a sign of its own is written by its code in the symbol style, and one
  /// without a Russian name by its code in the name style.
  func testACurrencyWithoutASignOrANameIsWrittenByItsCode() {
    XCTAssertEqual(CurrencyStyle.symbol(for: CurrencyCode("SEK")), "SEK")
    XCTAssertEqual(CurrencyStyle.name.unit(for: CurrencyCode("SEK"), russian: true), "SEK")
    XCTAssertEqual(CurrencyStyle.symbol(for: CurrencyCode("GEL")), "₾")
    XCTAssertEqual(CurrencyStyle.symbol(for: CurrencyCode("AMD")), "֏")
  }

  /// Names of two words never break across a line.
  func testNamesOfTwoWordsHoldTogether() {
    for code in ["GBP", "CHF", "BYN"] {
      let name = CurrencyStyle.name.unit(for: CurrencyCode(code), russian: true)
      XCTAssertFalse(name.contains(" "), code)
      XCTAssertTrue(name.contains(nbsp), code)
    }
  }

  /// The sign beside a field is the symbol whatever the style.
  func testTheSignOfAFieldIsAlwaysTheSymbol() {
    for style in CurrencyStyle.allCases {
      let money = MoneyFormatter(locale: Locale(identifier: "ru"), currencyStyle: style)
      XCTAssertEqual(money.symbol(for: .eur), "€", "\(style)")
    }
  }

  func testCountsAndRatesHaveNoUnit() {
    XCTAssertEqual(en.count(1_234_567), "1,234,567")
    XCTAssertEqual(en.count(-1_000), "\u{2212}1,000")
    XCTAssertEqual(en.rate(Decimal(string: "81.43215")!), "81.4322")
    XCTAssertEqual(en.number(Decimal(string: "0.5")!), "0.5")
  }

  func testTheStoredStyleReadsSafely() throws {
    let suite = "ohmymoney.tests.f.style.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    XCTAssertEqual(CurrencyStyle.stored(in: defaults), .symbol)
    XCTAssertEqual(CurrencyStyle.stored(in: nil), .symbol)
    defaults.set("name", forKey: CurrencyStyle.key)
    XCTAssertEqual(CurrencyStyle.stored(in: defaults), .name)
    defaults.set("Name", forKey: CurrencyStyle.key)
    XCTAssertEqual(CurrencyStyle.stored(in: defaults), .symbol)
    defaults.set(3, forKey: CurrencyStyle.key)
    XCTAssertEqual(CurrencyStyle.stored(in: defaults), .symbol)
  }
}

/// The size of the text: the table of points of every style at every size, sizes written in
/// points for «Обычный» grown with the body and never below nine, and a stored size read safely.
final class SettingsScenarioFontSizeTests: XCTestCase {
  func testTheBodyAtEverySize() {
    XCTAssertEqual(AppFontSize.allCases.map { $0.points(of: .body) }, [11, 13, 15, 17])
    XCTAssertEqual(AppFontSize.allCases.map { $0.points(of: .headline) }, [11, 13, 15, 17])
  }

  func testTheSmallerStylesAtEverySize() {
    XCTAssertEqual(AppFontSize.allCases.map { $0.points(of: .callout) }, [10, 12, 14, 16])
    XCTAssertEqual(AppFontSize.allCases.map { $0.points(of: .subheadline) }, [10, 11, 13, 15])
    XCTAssertEqual(AppFontSize.allCases.map { $0.points(of: .footnote) }, [9, 10, 12, 14])
    XCTAssertEqual(AppFontSize.allCases.map { $0.points(of: .caption) }, [9, 10, 12, 14])
    XCTAssertEqual(AppFontSize.allCases.map { $0.points(of: .caption2) }, [9, 10, 12, 14])
  }

  /// No style of any size is smaller than nine points, and every style grows with the size.
  func testEveryStyleGrowsAndNoneIsBelowNine() {
    let styles: [Font.TextStyle] = [
      .largeTitle, .title, .title2, .title3, .headline, .subheadline, .body, .callout, .footnote,
      .caption, .caption2,
    ]
    for style in styles {
      let row = AppFontSize.allCases.map { $0.points(of: style) }
      XCTAssertGreaterThanOrEqual(row.min() ?? 0, 9, "\(style)")
      XCTAssertEqual(row, row.sorted(), "\(style)")
      XCTAssertLessThan(row[0], row[3], "\(style)")
    }
  }

  func testAFixedSizeGrowsWithTheBody() {
    XCTAssertEqual(AppFontSize.regular.points(fromRegular: 20), 20)
    XCTAssertEqual(AppFontSize.xlarge.points(fromRegular: 13), 17)
    XCTAssertEqual(AppFontSize.large.points(fromRegular: 26), 30)
    XCTAssertEqual(AppFontSize.small.points(fromRegular: 9), 9, "never below nine")
    XCTAssertEqual(AppFontSize.small.points(fromRegular: 26), 22)
  }

  func testRegularIsTheSystemsOwn() {
    XCTAssertNil(AppFontSize.regular.bodyPoints)
    XCTAssertNil(AppFontSize.regular.bodyFont)
    XCTAssertEqual(AppFontSize.regular.scale, 1)
    XCTAssertGreaterThan(AppFontSize.xlarge.scale, AppFontSize.large.scale)
    XCTAssertLessThan(AppFontSize.small.scale, 1)
  }

  func testTheStoredSizeReadsSafely() throws {
    let suite = "ohmymoney.tests.f.font.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    XCTAssertEqual(AppFontSize.stored(in: defaults), .regular)
    for size in AppFontSize.allCases {
      defaults.set(size.rawValue, forKey: AppFontSize.key)
      XCTAssertEqual(AppFontSize.stored(in: defaults), size)
    }
    defaults.set("huge", forKey: AppFontSize.key)
    XCTAssertEqual(AppFontSize.stored(in: defaults), .regular)
  }

  func testEveryChoiceHasItsOwnKey() {
    XCTAssertEqual(
      Set(AppFontSize.allCases.map(\.settingsKey)).count, AppFontSize.allCases.count)
    XCTAssertEqual(
      Set(CurrencyStyle.allCases.map(\.settingsKey)).count, CurrencyStyle.allCases.count)
  }
}

/// The search of the settings, run on words a test hands it: a query of either language finds
/// the same section, case, accents, «ё» and the guillemets do not matter, and the order is
/// that of the sidebar.
final class SettingsScenarioSearchTests: XCTestCase {
  /// The words of the real catalogs.
  @MainActor private var words: SettingsSearch.Words { SettingsSearch.catalogWords() }

  private func sections(_ query: String, _ words: SettingsSearch.Words) -> [SettingsSection] {
    SettingsSearch.find(query, words: words).map(\.section)
  }

  /// Every section is found by its own name in Russian and in English.
  @MainActor
  func testEverySectionIsFoundByItsNameInBothLanguages() {
    let words = self.words
    for section in SettingsSection.allCases {
      for code in SettingsSearch.languages {
        let name = words(.settings(section.titleKey), code)
        XCTAssertTrue(sections(name, words).contains(section), "\(section) \(code): \(name)")
      }
    }
  }

  /// Every caption of every section finds that section, in both languages.
  @MainActor
  func testEveryCaptionFindsItsSection() {
    let words = self.words
    for section in SettingsSection.allCases {
      for caption in section.index {
        for code in SettingsSearch.languages {
          let found = SettingsSearch.find(words(caption, code), words: words)
          let hit = found.first { $0.section == section }
          XCTAssertNotNil(hit, "\(caption.key) \(code)")
        }
      }
    }
  }

  @MainActor
  func testTheSameSettingIsFoundInEitherLanguage() {
    let words = self.words
    let caption = SettingsCaption.settings("settings.appearance.fontSize")
    let ru = sections(words(caption, "ru"), words)
    let en = sections(words(caption, "en"), words)
    XCTAssertTrue(ru.contains(.appearance))
    XCTAssertTrue(en.contains(.appearance))
  }

  /// A query in the middle of a word, in capitals, with spaces around and guillemets.
  func testAQueryIsFoldedLikeTheWords() {
    let words: SettingsSearch.Words = { caption, code in
      guard caption.key == "settings.tab.backups" else { return "" }
      return code == "ru" ? "Резервные «копии»" : "Backups"
    }
    for query in ["копии", "КОПИИ", "  копии ", "«копии»", "ЕРВНЫЕ", "backUPS", "kup"] {
      XCTAssertEqual(sections(query, words), [.backups], query)
    }
  }

  func testYoIsYeAndAccentsDoNotMatter() {
    let words: SettingsSearch.Words = { caption, _ in
      caption.key == "settings.planning.cushion" ? "Подушка ещё" : ""
    }
    XCTAssertEqual(sections("ещё", words), [.planning])
    XCTAssertEqual(sections("еще", words), [.planning])
    XCTAssertEqual(SettingsSearch.fold("Café Ёлка…"), "cafe елка")
  }

  func testASectionFoundByItsNameAlsoListsTheCaptionsThatMatch() {
    let words: SettingsSearch.Words = { caption, _ in
      caption.key == "settings.tab.currencies" ? "Валюты" : "валюты где-то"
    }
    let found = SettingsSearch.find("валюты", words: words)
    let currencies = found.first { $0.section == .currencies }
    XCTAssertEqual(currencies?.captions.count, SettingsSection.currencies.index.count)
  }

  /// Found sections stand in the order of the sidebar, whatever matched first.
  func testFoundSectionsKeepTheOrderOfTheSidebar() {
    let words: SettingsSearch.Words = { _, _ in "общее слово" }
    XCTAssertEqual(sections("слово", words), SettingsSection.allCases)
  }

  func testNothingMatchesNothing() {
    let words: SettingsSearch.Words = { _, _ in "что-то" }
    XCTAssertEqual(SettingsSearch.find("xyz", words: words), [])
  }

  func testAQueryOfSpacesShowsEverySection() {
    let words: SettingsSearch.Words = { _, _ in "" }
    let found = SettingsSearch.find("   ", words: words)
    XCTAssertEqual(found.map(\.section), SettingsSection.allCases)
    XCTAssertTrue(found.allSatisfy { $0.captions.isEmpty })
  }

  /// Every section has a name, a symbol of its own and something to be found by.
  func testEverySectionHasANameASymbolAndAnIndex() {
    let symbols = SettingsSection.allCases.map(\.symbol)
    XCTAssertEqual(Set(symbols).count, symbols.count)
    for section in SettingsSection.allCases {
      XCTAssertFalse(section.index.isEmpty, "\(section)")
      XCTAssertFalse(section.titleKey.isEmpty)
    }
    let keys = SettingsSection.allCases.flatMap(\.index).map(\.key)
    XCTAssertEqual(Set(keys).count, keys.count, "a caption is listed in two sections")
  }
}
