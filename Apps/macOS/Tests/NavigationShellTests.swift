import AppKit
import XCTest

@testable import OhMyMoney

// Synthetic data only.

/// The shell of the main window: the order of the sidebar and the shortcuts that follow it, the
/// menu that carries every action the toolbar no longer has, and the sections that used to be
/// windows of their own.
@MainActor
final class NavigationShellTests: XCTestCase {
  private func items(_ menu: NSMenu? = NSApp.mainMenu) -> [NSMenuItem] {
    (menu?.items ?? []).flatMap { [$0] + items($0.submenu) }
  }

  private func bundle(_ language: String) -> Bundle {
    Bundle.main.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:))
      ?? .main
  }

  private func names(_ key: String) -> Set<String> {
    Set(
      ["ru", "en"].map {
        bundle($0).localizedString(forKey: key, value: nil, table: "Common")
      })
  }

  private func menuItems(key: String, modifiers: NSEvent.ModifierFlags) -> [NSMenuItem] {
    items().filter {
      $0.keyEquivalent.lowercased() == key
        && $0.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask) == modifiers
    }
  }

  // MARK: The order

  func testTheSidebarIsInTheOrderOfTheDesign() {
    XCTAssertEqual(
      MainWindow.Section.allCases.map(\.rawValue),
      [
        "overview", "operations", "planning", "calendar", "capital", "debts", "purchases",
        "analytics", "reports",
      ])
  }

  func testEveryShortcutIsThePlaceInTheSidebar() {
    for (position, section) in MainWindow.Section.allCases.enumerated() {
      XCTAssertEqual(section.shortcutIndex, position + 1, section.rawValue)
    }
    XCTAssertEqual(MainWindow.Section.analytics.shortcutIndex, 8)
    XCTAssertEqual(MainWindow.Section.reports.shortcutIndex, 9)
  }

  func testEverySectionHasANameAndASymbolInBothLanguages() {
    for section in MainWindow.Section.allCases {
      XCTAssertFalse(section.symbol.isEmpty, section.rawValue)
      for language in ["ru", "en"] {
        let name = bundle(language).localizedString(
          forKey: section.titleKey, value: "\u{0}", table: "Common")
        XCTAssertNotEqual(name, "\u{0}", "\(section.titleKey) has no \(language) name")
      }
    }
    XCTAssertEqual(
      names(MainWindow.Section.analytics.titleKey), ["Аналитика", "Analytics"])
    XCTAssertEqual(names(MainWindow.Section.reports.titleKey), ["Отчёты", "Reports"])
  }

  // MARK: The menu

  /// ⌘1 … ⌘9: one item each, named like the section at that place of the sidebar.
  func testTheMenuHasOneItemForEveryNumberOfTheSidebar() {
    for section in MainWindow.Section.allCases {
      let key = String(section.shortcutIndex)
      let found = menuItems(key: key, modifiers: .command)
      XCTAssertEqual(found.count, 1, "⌘\(key): \(found.map(\.title))")
      XCTAssertTrue(
        names(section.titleKey).contains(found.first?.title ?? ""),
        "⌘\(key) is «\(found.first?.title ?? "")», not \(section.rawValue)")
    }
  }

  /// What the toolbar lost is in the menu bar, each with its key: nothing is gone.
  func testWhatTheToolbarLostIsInTheMenu() {
    let command: NSEvent.ModifierFlags = .command
    // «Сверка» ⌥⌘R, «Экспорт» ⇧⌘E, «Пересчитать» ⌘R, «Скрыть суммы» ⌃⌘H, «Настройки» ⌘, .
    XCTAssertEqual(menuItems(key: "r", modifiers: [.command, .option]).count, 1, "Count: ⌥⌘R")
    XCTAssertEqual(menuItems(key: "e", modifiers: [.command, .shift]).count, 1, "Export: ⇧⌘E")
    XCTAssertEqual(menuItems(key: "r", modifiers: command).count, 1, "Recompute: ⌘R")
    XCTAssertEqual(menuItems(key: "h", modifiers: [.command, .control]).count, 1, "Hide: ⌃⌘H")
    XCTAssertEqual(menuItems(key: ",", modifiers: command).count, 1, "Settings: ⌘,")
    // «Обновления»: an item of the menu bar, whichever its words.
    let updates = items().contains {
      $0.title.contains("обновлен") || $0.title.lowercased().contains("update")
        || $0.title.contains("Перезапустить") || $0.title.contains("Restart")
    }
    XCTAssertTrue(updates, "no item for the updates")
  }

  /// ⌘⇧T, ⌘⇧A, ⌘⇧R remain, one each; there is no window left for Analytics or Reports.
  func testTheShiftShortcutsRemainAndLeadToSections() {
    for key in ["t", "a", "r"] {
      XCTAssertEqual(menuItems(key: key, modifiers: [.command, .shift]).count, 1, "⌘⇧\(key)")
    }
    XCTAssertEqual(AppScreen.allCases.filter { $0.sceneId == "analytics" }.count, 1)
    #if os(macOS)
      XCTAssertFalse(
        NSApp.windows.contains { $0.identifier?.rawValue.contains("analytics") == true },
        "a window of Analytics of its own is open")
    #endif
  }

  // MARK: «Открыть в новом окне»

  func testAnalyticsAndReportsOpenInAWindowOfTheirOwn() {
    for section in [MainWindow.Section.analytics, .reports] {
      let value = SectionWindowValue(.section(section))
      XCTAssertEqual(value.item, .section(section))
      let data = try? JSONEncoder().encode(value)
      XCTAssertNotNil(data)
      let again = data.flatMap { try? JSONDecoder().decode(SectionWindowValue.self, from: $0) }
      XCTAssertEqual(again?.item, .section(section), "a window brought back by macOS")
    }
  }
}
