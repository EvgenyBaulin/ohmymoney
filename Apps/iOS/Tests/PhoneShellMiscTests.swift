import AppCore
import SwiftUI
import XCTest

@testable import OhMyMoney

/// The small pieces around the shell: the places switches kept on the device (and what a
/// damaged store reads as), the history strip's actions and place, and the folder status for
/// every combination of its inputs.
@MainActor
final class PhoneShellMiscTests: XCTestCase {
  private var defaults: UserDefaults!
  private var suite = ""

  override func setUp() {
    super.setUp()
    suite = "shell-misc-\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suite)
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suite)
    super.tearDown()
  }

  // MARK: Places on the device

  func testTheTwoSwitchesAreIndependentAndPersistAcrossReads() {
    PlaceHintsSettings.setHints(true, defaults)
    XCTAssertTrue(PlaceHintsSettings.hintsEnabled(defaults))
    XCTAssertFalse(PlaceHintsSettings.mapEnabled(defaults))
    PlaceHintsSettings.setMap(true, defaults)
    PlaceHintsSettings.setHints(false, defaults)
    XCTAssertFalse(PlaceHintsSettings.hintsEnabled(defaults))
    XCTAssertTrue(PlaceHintsSettings.mapEnabled(defaults))
  }

  func testADamagedStoreOfNoticesReadsAsNoNoticesAndTheNextOneRepairsIt() {
    let valid = UUID()
    defaults.set(
      ["not-a-uuid": 5.0, valid.uuidString: 100.0], forKey: PlaceHintsSettings.lastNoticeKey)
    let read = PlaceHintsSettings.lastNotified(defaults)
    XCTAssertEqual(read.count, 1, "a key that is no id is dropped")
    XCTAssertEqual(read[valid], Date(timeIntervalSince1970: 100))

    defaults.set("garbage", forKey: PlaceHintsSettings.lastNoticeKey)
    XCTAssertTrue(PlaceHintsSettings.lastNotified(defaults).isEmpty)
    defaults.set(["a": "text"], forKey: PlaceHintsSettings.lastNoticeKey)
    XCTAssertTrue(PlaceHintsSettings.lastNotified(defaults).isEmpty)

    let id = UUID()
    PlaceHintsSettings.remember(id, at: Date(timeIntervalSince1970: 7), defaults)
    XCTAssertEqual(PlaceHintsSettings.lastNotified(defaults), [id: Date(timeIntervalSince1970: 7)])
  }

  func testRememberingOneMarkKeepsTheOthersAndTheLaterMomentWins() {
    let first = UUID()
    let second = UUID()
    PlaceHintsSettings.remember(first, at: Date(timeIntervalSince1970: 10), defaults)
    PlaceHintsSettings.remember(second, at: Date(timeIntervalSince1970: 20), defaults)
    PlaceHintsSettings.remember(first, at: Date(timeIntervalSince1970: 30), defaults)
    let read = PlaceHintsSettings.lastNotified(defaults)
    XCTAssertEqual(read[first], Date(timeIntervalSince1970: 30))
    XCTAssertEqual(read[second], Date(timeIntervalSince1970: 20))
  }

  func testNoStoredKeyHoldsACoordinate() {
    PlaceHintsSettings.setHints(true, defaults)
    PlaceHintsSettings.setMap(true, defaults)
    PlaceHintsSettings.remember(UUID(), at: Date(), defaults)
    let keys = defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("places.") }
    XCTAssertEqual(
      Set(keys),
      [PlaceHintsSettings.hintsKey, PlaceHintsSettings.mapKey, PlaceHintsSettings.lastNoticeKey])
  }

  // MARK: History strip

  func testUndoAndRedoAreTwoActionsWithTheirOwnNamesSymbolsAndShortcuts() {
    XCTAssertEqual(TouchHistoryAction.allCases, [.undo, .redo])
    XCTAssertNotEqual(TouchHistoryAction.undo.titleKey, TouchHistoryAction.redo.titleKey)
    XCTAssertNotEqual(TouchHistoryAction.undo.symbol, TouchHistoryAction.redo.symbol)
    XCTAssertEqual(TouchHistoryAction.undo.modifiers, .command)
    XCTAssertEqual(TouchHistoryAction.redo.modifiers, [.command, .shift])
  }

  func testAFreshStoreOffersNeitherAndTheStripStaysAwayFromThePlusAndTheBar() {
    let store = TransactionsStore()
    XCTAssertTrue(TouchHistoryAction.available(in: store).isEmpty)
    TouchHistoryAction.undo.perform(in: store)
    TouchHistoryAction.redo.perform(in: store)
    XCTAssertTrue(TouchHistoryAction.available(in: store).isEmpty, "nothing to undo is no crash")

    XCTAssertGreaterThanOrEqual(
      TouchHistoryPlacement.trailingReserve,
      PhoneEntryButton.diameter + PhoneEntryButton.sideMargin,
      "the strip leaves the «+» its room")
    for barHeight in [CGFloat(0), 70, 120, 400] {
      XCTAssertEqual(
        TouchHistoryPlacement.bottomInset(placement: .bottom, barHeight: barHeight, onPhone: true),
        PhoneEntryButton.bottomPadding(placement: .bottom, barHeight: barHeight))
    }
    XCTAssertEqual(
      TouchHistoryPlacement.bottomInset(placement: .sidebar, barHeight: 0, onPhone: false),
      EntryPlusMetrics.padScrollClearance)
  }

  // MARK: Folder for copies

  func testTheFolderStatusForEveryCombination() {
    let folder = URL(fileURLWithPath: "/tmp/Копии/My Backups", isDirectory: true)
    for isStored in [false, true] {
      for unavailable in [false, true] {
        for mirror in [nil, folder] {
          let demo = FolderStatus.of(
            profile: .demo, isStored: isStored, mirror: mirror, unavailable: unavailable)
          XCTAssertEqual(demo, .demoWritesNothing, "the demo has nothing to choose")
          let real = FolderStatus.of(
            profile: .real, isStored: isStored, mirror: mirror, unavailable: unavailable)
          if mirror != nil {
            XCTAssertEqual(real, .ready(name: "My Backups"))
          } else if unavailable || isStored {
            XCTAssertEqual(real, .lost)
          } else {
            XCTAssertEqual(real, .notChosen)
          }
        }
      }
    }
  }
}
