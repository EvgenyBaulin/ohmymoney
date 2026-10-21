import AppKit
import SwiftUI
import XCTest

@testable import OhMyMoney

/// «Оформление → Размер шрифта»: Мелкий, Обычный, Крупный, Очень крупный for every window — the
/// main one, the secondary ones, the settings — and every sheet the app hands its dependencies
/// to. «Обычный» leaves everything exactly as the system draws it; amounts keep their digits of
/// one width at any size.
@MainActor
final class AppFontSizeTests: XCTestCase {
  private func width(of view: some View) -> CGFloat {
    // dependencies: none — plain text measured for its width, nothing reads the environment.
    NSHostingView(rootView: view.fixedSize()).fittingSize.width
  }

  private func deps(_ size: AppFontSize) -> AppDependencies {
    let environment = AppEnvironment()
    environment.theme.fontSize = size
    return AppDependencies.forTests(environment)
  }

  func testTheSizesGrowInOrderAndRegularIsTheSystems() {
    XCTAssertNil(AppFontSize.regular.bodyPoints, "«Обычный» set a font of its own")
    XCTAssertEqual(AppFontSize.regular.scale, 1)
    let points = AppFontSize.allCases.map { $0.bodyPoints ?? AppFontSize.regularBodyPoints }
    XCTAssertEqual(points, points.sorted(), "the sizes are not in order")
    XCTAssertEqual(Set(points).count, AppFontSize.allCases.count, "two sizes are the same")
    XCTAssertEqual(AppFontSize.allCases.map(\.rawValue), ["small", "regular", "large", "xlarge"])
  }

  /// What a window shows grows with the choice, and «Обычный» is the window as it was.
  func testEveryWindowRootTakesTheSize() {
    let text = Text(verbatim: "Можно тратить сейчас")
    let plain = width(of: text)
    var widths: [AppFontSize: CGFloat] = [:]
    for size in AppFontSize.allCases {
      widths[size] = width(
        of: AppScenes.root(deps(size), window: .settings, launches: false) {
          _ in text
        })
    }
    XCTAssertEqual(widths[.regular] ?? 0, plain, accuracy: 0.5, "«Обычный» changed the text")
    XCTAssertLessThan(widths[.small] ?? 0, plain)
    XCTAssertGreaterThan(widths[.large] ?? 0, plain)
    XCTAssertGreaterThan(widths[.xlarge] ?? 0, widths[.large] ?? 0)
  }

  /// A sheet is laid out by a host of its own: it takes the size with the dependencies it is
  /// handed, and a text with a font of its own keeps it.
  func testASheetHandedTheDependenciesTakesTheSize() {
    let text = Text(verbatim: "Новый банк")
    let plain = width(of: text)
    XCTAssertGreaterThan(width(of: text.handingOver(deps(.xlarge))), plain)
    XCTAssertGreaterThan(width(of: text.appDependencies(deps(.large))), plain)
    let headline = Text(verbatim: "Новый банк").font(.headline)
    XCTAssertEqual(
      width(of: headline.appDependencies(deps(.xlarge))), width(of: headline), accuracy: 0.5)
  }

  /// Amounts keep digits of one width at every size: «111» and «888» are as wide.
  func testAmountsKeepDigitsOfOneWidthAtEverySize() {
    for size in AppFontSize.allCases {
      let ones = width(of: Text(verbatim: "1,111 ₽").monospacedDigit().appDependencies(deps(size)))
      let eights = width(
        of: Text(verbatim: "8,888 ₽").monospacedDigit().appDependencies(deps(size)))
      XCTAssertEqual(ones, eights, accuracy: 0.5, "digits of two widths at \(size)")
    }
  }

  func testTheStoredSizeReadsSafelyAndTheTestHostKeepsNone() {
    let defaults = UserDefaults(suiteName: "ohmymoney.tests.fontSize.\(UUID().uuidString)")!
    XCTAssertEqual(AppFontSize.stored(in: defaults), .regular)
    defaults.set("xlarge", forKey: AppFontSize.key)
    XCTAssertEqual(AppFontSize.stored(in: defaults), .xlarge)
    defaults.set("huge", forKey: AppFontSize.key)
    XCTAssertEqual(AppFontSize.stored(in: defaults), .regular)
    XCTAssertEqual(AppFontSize.stored(in: nil), .regular)

    let before = UserDefaults.standard.object(forKey: AppFontSize.key) as? String
    let theme = AppTheme()
    theme.fontSize = .large
    XCTAssertEqual(
      UserDefaults.standard.object(forKey: AppFontSize.key) as? String, before,
      "the test host wrote the owner's choice")
    XCTAssertEqual(AppTheme().fontSize, .regular)
  }

  /// The settings hold the choice: both pickers are in «Оформление» with words in both
  /// languages.
  func testEveryChoiceHasWordsInBothLanguages() {
    let words = SettingsSearch.catalogWords()
    let keys =
      AppFontSize.allCases.map(\.settingsKey) + CurrencyStyle.allCases.map(\.settingsKey)
      + ["settings.appearance.fontSize", "settings.appearance.currencyStyle"]
    for key in keys {
      for code in SettingsSearch.languages {
        let text = words(.settings(key), code)
        XCTAssertFalse(text.isEmpty || text == key, "no \(code) words for \(key)")
      }
    }
  }
}
