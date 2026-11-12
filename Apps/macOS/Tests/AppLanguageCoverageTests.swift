import AppCore
import Foundation
import SwiftUI
import XCTest

@testable import OhMyMoney

@MainActor
final class AppLanguageCoverageTests: XCTestCase {
  func testEveryStarterLanguageCanBeChosenAndResolvedLive() throws {
    let language = AppLanguage()
    let previous = language.choice
    defer { language.choice = previous }
    XCTAssertEqual(
      Set(AppLanguage.Choice.allCases.filter { $0 != .system }.map(\.rawValue)),
      Set(StarterLanguage.allCases.map(\.rawValue)))
    for starter in StarterLanguage.allCases {
      let choice = try XCTUnwrap(AppLanguage.Choice(rawValue: starter.rawValue))
      language.choice = choice
      XCTAssertEqual(language.resolvedCode, starter.rawValue)
      XCTAssertEqual(language.locale.identifier, Locale(identifier: starter.rawValue).identifier)
      XCTAssertEqual(language.translationVerification, starter.translationVerification)
      for (key, table) in [
        ("app.name", "Common"), ("kind.expense", "Common"),
        ("entry.placeholder", "Entry"), (choice.settingsKey, "Settings"),
      ] {
        let text = language(key, table: table)
        XCTAssertFalse(text.isEmpty, "\(starter): \(key)")
        XCTAssertNotEqual(text, key, "\(starter): \(key)")
      }
      XCTAssertEqual(language("app.name"), "OhMyMoney")
      XCTAssertEqual(
        UserDefaults.standard.stringArray(forKey: AppLanguage.appleLanguagesKey),
        [starter.rawValue])
    }
  }

  func testLayoutDirectionSwitchesLiveForArabicAndHebrew() {
    let language = AppLanguage()
    let previous = language.choice
    defer { language.choice = previous }
    for choice in AppLanguage.Choice.allCases where choice != .system {
      language.choice = choice
      XCTAssertEqual(
        language.layoutDirection,
        choice == .arabic || choice == .hebrew ? .rightToLeft : .leftToRight)
    }
  }

  func testUkrainianStringsAndPluralFormsComeFromTheSelectedBundle() {
    let language = AppLanguage()
    let previous = language.choice
    defer { language.choice = previous }
    language.choice = .ukrainian
    XCTAssertEqual(language("kind.expense"), "Витрата")
    XCTAssertEqual(language("entry.placeholder", table: "Entry"), "Що купили? Наприклад: кафе 450")
    for (count, expected) in [
      (1, "1 хвилина"), (2, "2 хвилини"), (5, "5 хвилин"), (11, "11 хвилин"),
      (21, "21 хвилина"), (22, "22 хвилини"), (25, "25 хвилин"),
    ] {
      XCTAssertEqual(language.format("phone.lock.minutes", table: "Phone", counts: count), expected)
    }
    language.choice = .english
    XCTAssertEqual(language("kind.expense"), "Expense")
  }

  func testSystemTagsResolveRegionsScriptsAndUnsupportedLanguages() {
    let examples = [
      "uk-UA": "uk", "be_BY": "be", "kk-KZ": "kk", "de-CH": "de", "fr-CA": "fr",
      "pt": "pt-PT", "pt_PT": "pt-PT", "pt-BR": "pt-BR", "zh": "zh-Hans",
      "zh-CN": "zh-Hans", "zh-SG": "zh-Hans", "zh-Hant-TW": "zh-Hant",
      "zh-HK": "zh-Hant", "zh_MO": "zh-Hant", "AR-sa": "ar", "he-IL": "he",
      "sv-SE": "en", "fi": "en", "": "en", "unknown": "en",
    ]
    for (identifier, expected) in examples {
      XCTAssertEqual(AppLanguage.systemCode(for: identifier), expected, identifier)
    }
    for starter in StarterLanguage.allCases {
      XCTAssertEqual(AppLanguage.systemCode(for: starter.rawValue), starter.rawValue)
    }
  }

  func testEveryExplicitLanguageIsSettledForTheNextLaunch() throws {
    let suite = "ohmymoney.tests.language.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    for choice in AppLanguage.Choice.allCases where choice != .system {
      AppLanguage.store(choice, in: defaults)
      XCTAssertEqual(AppLanguage.storedCode(in: defaults), choice.rawValue)
      defaults.removeObject(forKey: AppLanguage.appleLanguagesKey)
      AppLanguage.settle(in: defaults, domain: suite)
      XCTAssertEqual(defaults.stringArray(forKey: AppLanguage.appleLanguagesKey), [choice.rawValue])
    }
    AppLanguage.store(.system, in: defaults)
    XCTAssertNil(defaults.persistentDomain(forName: suite)?[AppLanguage.appleLanguagesKey])
  }

  func testMissingTranslationsUseEnglishIncludingTouchInstructionsAndPlurals() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let selectedURL = root.appendingPathComponent("uk.lproj")
    let englishURL = root.appendingPathComponent("en.lproj")
    for url in [selectedURL, englishURL] {
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    try "\"delete\" = \"Видалити — ⌘Z\";".write(
      to: selectedURL.appendingPathComponent("Fixture.strings"), atomically: true, encoding: .utf8)
    try "\"missing\" = \"English fallback\";\n\"delete.touch\" = \"Tap Undo\";".write(
      to: englishURL.appendingPathComponent("Fixture.strings"), atomically: true, encoding: .utf8)
    let selected = try XCTUnwrap(Bundle(url: selectedURL))
    let english = try XCTUnwrap(Bundle(url: englishURL))
    XCTAssertEqual(
      AppLanguage.localizedText(
        "missing", table: "Fixture", forTouch: false, in: selected, fallback: english),
      "English fallback")
    XCTAssertEqual(
      AppLanguage.localizedText(
        "delete", table: "Fixture", forTouch: true, in: selected, fallback: english),
      "Tap Undo")
    XCTAssertEqual(
      AppLanguage.localizedText(
        "delete", table: "Fixture", forTouch: false, in: selected, fallback: english),
      "Видалити — ⌘Z")
    XCTAssertEqual(
      AppLanguage.localizedText(
        "absent", table: "Fixture", forTouch: false, in: selected, fallback: english),
      "absent")
    // An empty language bundle must also fall back for a compiled stringsdict entry.
    let bundledEnglish = try XCTUnwrap(Bundle.main.url(forResource: "en", withExtension: "lproj"))
    let fallback = try XCTUnwrap(Bundle(url: bundledEnglish))
    let format = AppLanguage.localizedText(
      "accounts.group.count", table: "Accounts", forTouch: false, in: selected, fallback: fallback)
    XCTAssertEqual(String.localizedStringWithFormat(format, 2), "2 accounts")
  }
}
