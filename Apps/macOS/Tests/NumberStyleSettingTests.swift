import AppCore
import XCTest

@testable import OhMyMoney

/// «Настройки → Основные → Запись чисел» (0563): «1,234.56» by default, «1 234,56» on choice,
/// live for everything the interface writes; fields, CSV and the archive keep the point.
@MainActor
final class NumberStyleSettingTests: XCTestCase {
  private let nbsp = "\u{00A0}"

  override func tearDown() {
    NumberText.style = .point
    super.tearDown()
  }

  func testThePointStyleIsTheDefault() {
    XCTAssertEqual(AppTheme().numberStyle, .point)
    XCTAssertEqual(NumberText.style, .point)
  }

  func testChoosingTheSpaceStyleChangesWhatMoneyFormatterWrites() {
    let theme = AppTheme()
    let amount = AmountE4(raw: 12_345_600)
    let money = MoneyFormatter(locale: Locale(identifier: "en"))
    XCTAssertEqual(money.exact(amount), "1,234.56\(nbsp)₽")
    theme.numberStyle = .space
    XCTAssertEqual(NumberText.style, .space)
    XCTAssertEqual(money.exact(amount), "1\(nbsp)234,56\(nbsp)₽")
    XCTAssertEqual(MoneyFormatter(locale: Locale(identifier: "ru")).exact(amount), "1\(nbsp)234,56\(nbsp)₽")
    theme.numberStyle = .point
    XCTAssertEqual(money.exact(amount), "1,234.56\(nbsp)₽")
  }

  func testFieldsAndFilesKeepThePointInTheSpaceStyle() {
    AppTheme().numberStyle = .space
    XCTAssertEqual(NumberText.amount(AmountE4(raw: 12_345_600), grouping: false), "1234.56")
    XCTAssertEqual(NumberText.plain(Decimal(string: "81.4321")!), "81.4321")
    XCTAssertEqual(TypedNumber.read("1234,56")?.canonical, "1,234.56")
  }

  func testTheStyleIsStoredUnderItsKeyAndReadBack() throws {
    let suite = "NumberStyleSettingTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    XCTAssertEqual(AppTheme.storedNumberStyle(in: defaults), .point)
    defaults.set("space", forKey: "app.numberStyle")
    XCTAssertEqual(AppTheme.storedNumberStyle(in: defaults), .space)
    defaults.set("nonsense", forKey: "app.numberStyle")
    XCTAssertEqual(AppTheme.storedNumberStyle(in: defaults), .point)
    XCTAssertEqual(AppTheme.numberStyleKey, "app.numberStyle")
  }

  func testTheRowsShowBothWritings() {
    XCTAssertEqual(GeneralSettingsView.numberStyleSample(.point), "1,234.56")
    XCTAssertEqual(GeneralSettingsView.numberStyleSample(.space), "1\(nbsp)234,56")
  }

  func testTheSettingHasWordsInBothLanguages() throws {
    for code in ["ru", "en"] {
      let bundle = try XCTUnwrap(
        Bundle.main.path(forResource: code, ofType: "lproj").flatMap(Bundle.init(path:)))
      for key in ["settings.numbers", "settings.numbers.hint"] {
        let text = bundle.localizedString(forKey: key, value: nil, table: "Settings")
        XCTAssertNotEqual(text, key, "\(code) \(key)")
      }
    }
  }
}
