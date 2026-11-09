import AppCore
import XCTest

@testable import OhMyMoney

/// «Чипы шаблонов под строкой» and «Подсказки по истории» in Settings → «Ввод»: on by default,
/// kept in the defaults, carried by the transfer archive.
@MainActor
final class EntryHintSwitchTests: XCTestCase {
  private let keys = [AppEnvironment.entryChipsKey, AppEnvironment.entryHistoryHintsKey]

  override func setUp() {
    for key in keys { UserDefaults.standard.removeObject(forKey: key) }
  }

  override func tearDown() {
    for key in keys { UserDefaults.standard.removeObject(forKey: key) }
  }

  func testBothAreOnUntilTheOwnerSwitchesThemOff() {
    let environment = AppEnvironment()
    XCTAssertTrue(environment.entryChipsShown)
    XCTAssertTrue(environment.entryHistoryHintsShown)
    environment.entryChipsShown = false
    environment.entryHistoryHintsShown = false
    let again = AppEnvironment()
    XCTAssertFalse(again.entryChipsShown)
    XCTAssertFalse(again.entryHistoryHintsShown)
  }

  func testTheArchiveCarriesBothSwitches() {
    let environment = AppEnvironment()
    environment.entryChipsShown = false
    let values = environment.portableSettings()
    XCTAssertEqual(values[AppEnvironment.entryChipsKey], "0")
    XCTAssertEqual(values[AppEnvironment.entryHistoryHintsKey], "1")
  }

  func testEveryEntrySettingIsFoundBySearch() {
    let titles = SettingsSection.entry.index.map(\.key)
    XCTAssertTrue(titles.contains("settings.entry.chips"))
    XCTAssertTrue(titles.contains("settings.entry.historyHints"))
  }
}
