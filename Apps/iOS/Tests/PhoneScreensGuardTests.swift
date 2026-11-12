import AppCore
import XCTest

@testable import OhMyMoney

/// The list of the phone's screens against the navigation it is built from: a screen that
/// navigation can reach and the registry does not know fails here, before any layout test is
/// asked to look at it.
@MainActor
final class PhoneScreensGuardTests: XCTestCase {
  func testTheRegistryHoldsEveryTabDestinationSettingAndSheetOnce() {
    let all = PhoneScreen.all
    XCTAssertEqual(Set(all).count, all.count, "a screen is listed twice")
    for tab in PhoneTab.allCases { XCTAssertTrue(all.contains(.tab(tab)), "tab \(tab)") }
    for destination in MoreDestination.allCases {
      XCTAssertTrue(all.contains(.more(destination)), "destination \(destination)")
    }
    for section in SettingsSection.allCases {
      XCTAssertTrue(all.contains(.setting(section)), "settings section \(section)")
    }
    for sheet in PhoneSheet.allCases { XCTAssertTrue(all.contains(.sheet(sheet)), "\(sheet)") }
    XCTAssertEqual(
      all.count,
      PhoneTab.allCases.count + MoreDestination.allCases.count + SettingsSection.allCases.count
        + PhoneSheet.allCases.count)
  }

  func testEveryRowOfMoreLeadsToAListedScreenAndEveryDestinationHasARow() {
    let menu = MoreMenu.make(more: NavItem.allCases, tripIsOn: true, hasConflicts: true)
    var reached = Set<MoreDestination>()
    for row in menu.sections + menu.app {
      guard let screen = PhoneScreen.screen(of: row) else { continue }
      XCTAssertTrue(PhoneScreen.all.contains(screen), "row \(row.id) opens \(screen)")
      if case .more(let destination) = screen { reached.insert(destination) }
    }
    for destination in MoreDestination.allCases {
      XCTAssertTrue(reached.contains(destination), "no row of «Ещё» opens \(destination)")
    }
  }

  func testEverySectionOfTheSettingsStandsInTheListOfThePhoneOnce() {
    let listed = SettingsSection.phoneGroups.flatMap { $0 }
    XCTAssertEqual(Set(listed).count, listed.count, "a section stands in two groups")
    XCTAssertEqual(Set(listed), Set(SettingsSection.allCases))
  }

  func testTheTabsOfThePhoneAreTheFiveOfTheBar() {
    XCTAssertEqual(PhoneTab.allCases.count, NavLayout.phoneSlots + 1)
  }

  /// A sheet, cover, popover, alert, dialog or inspector added to any screen's source — or a new
  /// file that has one — fails until the baseline is raised, which is the moment to look at what
  /// it opens on a phone.
  func testNoModalPresentationAppearsWithoutBeingListed() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let pattern = try NSRegularExpression(
      pattern: #"\.(sheet|fullScreenCover|popover|alert|confirmationDialog|inspector)\("#)
    var found: [String: Int] = [:]
    for folder in ["Apps/macOS", "Apps/iOS/App"] {
      let base = root.appendingPathComponent(folder)
      guard
        let walker = FileManager.default.enumerator(
          at: base, includingPropertiesForKeys: nil)
      else { return XCTFail("cannot read \(folder)") }
      for case let url as URL in walker where url.pathExtension == "swift" {
        let path = String(url.path.dropFirst(root.path.count + 1))
        if path.contains("/Tests/") || path.contains("/UITests/") { continue }
        let text = try String(contentsOf: url, encoding: .utf8)
        let count = pattern.numberOfMatches(
          in: text, range: NSRange(text.startIndex..., in: text))
        if count > 0 { found[path] = count }
      }
    }
    XCTAssertFalse(found.isEmpty, "the sources were not found next to the tests")
    for (path, count) in found.sorted(by: { $0.key < $1.key }) {
      let known = PhonePresentationBaseline.counts[path] ?? 0
      XCTAssertEqual(
        count, known,
        "\(path) holds \(count) modal presentations, the baseline says \(known): look at what the new one opens on a phone, then update PhonePresentationBaseline"
      )
    }
    for path in PhonePresentationBaseline.counts.keys where found[path] == nil {
      XCTFail("\(path) is in the baseline but has no modal presentation any more")
    }
  }
}
