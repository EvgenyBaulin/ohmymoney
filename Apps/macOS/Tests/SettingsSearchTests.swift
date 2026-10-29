import AppKit
import SwiftUI
import XCTest

@testable import OhMyMoney

/// The settings as System Settings shows its own: twelve sections in a sidebar, and a search that
/// finds a section by its name or a setting by its caption, in Russian or in English whatever the
/// language of the interface.
@MainActor
final class SettingsSearchTests: XCTestCase {
  private let words = SettingsSearch.catalogWords()

  func testEverySectionOfTheOldTabsIsInTheSidebarInTheirOrder() {
    XCTAssertEqual(
      SettingsSection.allCases,
      [
        .general, .appearance, .currencies, .accounts, .categories, .references, .entry,
        .templates, .planning, .rules, .attachments, .purchases, .privacy, .backups,
      ])
    XCTAssertEqual(Set(SettingsSection.allCases.map(\.symbol)).count, 14, "no two share a symbol")
  }

  /// Every name and every caption of the index has words in both languages: a caption without
  /// them would never be found.
  func testEveryNameAndCaptionHasWordsInBothLanguages() {
    for section in SettingsSection.allCases {
      for caption in [SettingsCaption.settings(section.titleKey)] + section.index {
        for code in SettingsSearch.languages {
          let text = words(caption, code)
          XCTAssertFalse(
            text.isEmpty || text == caption.key, "no \(code) words for \(caption.key)")
        }
      }
      XCTAssertFalse(section.index.isEmpty, "\(section) can only be found by its name")
    }
  }

  func testAnEmptyQueryShowsEverySection() {
    for query in ["", "   "] {
      let found = SettingsSearch.find(query, words: words)
      XCTAssertEqual(found.map(\.section), SettingsSection.allCases)
      XCTAssertTrue(found.allSatisfy(\.captions.isEmpty))
    }
  }

  func testASettingIsFoundByItsCaptionInEitherLanguage() {
    let russian = SettingsSearch.find("шрифт", words: words)
    XCTAssertEqual(russian.map(\.section), [.appearance])
    XCTAssertEqual(russian.first?.captions, [.settings("settings.appearance.fontSize")])

    let english = SettingsSearch.find("TEXT SIZE", words: words)
    XCTAssertEqual(english.map(\.section), [.appearance])

    let cushion = SettingsSearch.find("подушк", words: words)
    XCTAssertEqual(cushion.map(\.section), [.planning])

    let lock = SettingsSearch.find("Блокировать", words: words)
    XCTAssertEqual(lock.first?.section, .general)
    XCTAssertTrue(lock.first?.captions.contains(.settings("settings.privacy.lock")) ?? false)

    let cashback = SettingsSearch.find("кэшбэк", words: words)
    XCTAssertTrue(cashback.map(\.section).contains(.accounts), "\(cashback)")
    XCTAssertTrue(cashback.map(\.section).contains(.categories), "\(cashback)")
  }

  /// A section found by its name lists every setting it holds that also matches, and a query
  /// nothing answers leaves an empty sidebar.
  func testASectionIsFoundByItsNameAndNonsenseFindsNothing() {
    let backups = SettingsSearch.find("бэкап", words: words)
    XCTAssertEqual(backups.map(\.section), [.backups])
    XCTAssertEqual(SettingsSearch.find("Backups", words: words).map(\.section), [.backups])
    XCTAssertEqual(SettingsSearch.find("zqxw", words: words), [])
  }

  func testTheSearchIgnoresCaseYoAndGuillemets() {
    XCTAssertEqual(SettingsSearch.fold("  «Ёлка»… "), "елка")
    XCTAssertEqual(
      SettingsSearch.find("на кого", words: words).map(\.section).first, .general,
      "«Подписи «на кого»» was not found without its guillemets")
  }

  /// The settings window opens on the section chosen last, and a chosen section is the one the
  /// window shows.
  func testTheWindowShowsTheChosenSection() {
    let navigation = SettingsNavigation.shared
    let kept = navigation.section
    defer { navigation.section = kept }
    navigation.section = .backups
    let deps = AppDependencies.forTests(AppEnvironment())
    let controller = NSHostingController(
      rootView: AppScenes.root(deps, window: .settings, launches: false) {
        SettingsView(deps: $0)
      })
    let size = controller.sizeThatFits(in: SettingsView.idealSize)
    XCTAssertGreaterThanOrEqual(size.width, SettingsView.minimumSize.width)
    XCTAssertEqual(navigation.section, .backups)
  }

  /// Every section fits beside the widest sidebar in the smallest window: nothing asks for more
  /// width than 850 points leave, in either language.
  func testEverySectionFitsBesideTheSidebarInTheSmallestWindow() {
    let room = CGSize(
      width: SettingsView.minimumSize.width - SettingsView.sidebarWidth.max,
      height: SettingsView.minimumSize.height)
    for choice in [AppLanguage.Choice.russian, .english] {
      let environment = AppEnvironment()
      environment.language.choice = choice
      let deps = AppDependencies.forTests(environment)
      for section in SettingsSection.allCases {
        let navigation = SettingsNavigation.shared
        let kept = navigation.section
        navigation.section = section
        let controller = NSHostingController(
          rootView: SettingsSectionContent(section: section).appDependencies(deps))
        let size = controller.sizeThatFits(in: room)
        XCTAssertLessThanOrEqual(
          size.width, room.width + 0.5, "«\(section)» in \(choice) asks for \(size.width) pt")
        navigation.section = kept
      }
      environment.language.choice = .system
    }
  }
}
