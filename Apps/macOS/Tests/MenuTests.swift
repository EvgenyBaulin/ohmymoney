import AppKit
import Observation
import XCTest

@testable import OhMyMoney

/// The menu the app really builds, read from the test host's `NSApp.mainMenu`.
@MainActor
final class MenuTests: XCTestCase {
  /// Every item of the menu bar, submenus included.
  private func items(_ menu: NSMenu? = NSApp.mainMenu) -> [NSMenuItem] {
    (menu?.items ?? []).flatMap { [$0] + items($0.submenu) }
  }

  /// ⌘⇧T, ⌘⇧A and ⌘⇧R open Transactions, Analytics and Reports. The first run of
  /// `make test-ui` (19.09) found none of them working: a `Window` scene given
  /// `.keyboardShortcut` put its item into the Window menu without the key.
  func testTheSecondaryWindowsOpenByTheirShortcuts() {
    let shiftCommand: NSEvent.ModifierFlags = [.command, .shift]
    for key in ["t", "a", "r"] {
      let matches = items().filter {
        $0.keyEquivalent == key
          && $0.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask)
            == shiftCommand
      }
      XCTAssertEqual(matches.count, 1, "⌘⇧\(key.uppercased()): \(matches.map(\.title))")
    }
  }

  /// ⌘Z takes back the typing in the focused field first. With nothing typed, it takes back
  /// the store's last step from a window — the entry line keeps the cursor after a save — but
  /// never from a sheet or a popover: the sheet was opened over what that step wrote (a
  /// reimbursement lists the parts of the purchase ⌘Z would purge), and its own typing is
  /// all ⌘Z may reach there.
  func testUndoInsideASheetNeverReachesTheStore() {
    typealias Target = TextEditingUndo.UndoTarget
    func target(_ editing: Bool, _ field: Bool, _ store: Bool, sheet: Bool) -> Target {
      TextEditingUndo.undoTarget(
        isEditingText: editing, fieldCanUndo: field, storeCanUndo: store, inSheet: sheet)
    }
    XCTAssertEqual(target(true, true, true, sheet: false), .field)
    XCTAssertEqual(target(true, true, true, sheet: true), .field)
    XCTAssertEqual(target(true, false, true, sheet: false), .store, "the entry line after a save")
    XCTAssertEqual(target(false, false, true, sheet: false), .store)
    XCTAssertEqual(target(false, false, false, sheet: false), .none)
    XCTAssertEqual(target(true, false, true, sheet: true), .none, "an empty field of a sheet")
    XCTAssertEqual(target(false, false, true, sheet: true), .none, "a checkbox of a sheet")
  }

  /// What the two items show follows the one rule of `undoTarget`: Undo is on exactly when
  /// ⌘Z would reach something, so it is never on only to beep, and Redo only over typing
  /// that was taken back.
  func testTheItemsShowWhatTheKeysWouldReach() {
    typealias State = TextEditingUndo.State
    let typing = State(isEditingText: true, fieldCanUndo: true)
    XCTAssertEqual(typing.undoTarget(storeCanUndo: false), .field, "typing, nothing in the store")
    XCTAssertEqual(State().undoTarget(storeCanUndo: true), .store)
    XCTAssertEqual(State().undoTarget(storeCanUndo: false), .none)
    XCTAssertEqual(
      State(isEditingText: true, inSheet: true).undoTarget(storeCanUndo: true), .none)
    XCTAssertTrue(State(isEditingText: true, fieldCanRedo: true).canRedo)
    XCTAssertFalse(State(fieldCanRedo: true).canRedo, "no field has the cursor")
  }

  /// The watch reads AppKit again at every moment the field or the key window can change,
  /// and tells its observers only when what the items show has changed.
  func testTheWatchTellsOnlyWhenTheItemsChange() {
    let center = NotificationCenter()
    var field = TextEditingUndo.State()
    let watch = TextEditingWatch(center: center, read: { field })
    final class Count: @unchecked Sendable { var value = 0 }
    let told = Count()
    func observe() {
      withObservationTracking {
        _ = watch.state
      } onChange: {
        told.value += 1
      }
    }

    observe()
    center.post(name: NSText.didChangeNotification, object: nil)
    XCTAssertEqual(told.value, 0, "nothing changed, yet the commands were drawn again")

    field.isEditingText = true
    center.post(name: NSText.didBeginEditingNotification, object: nil)
    XCTAssertEqual(told.value, 1)
    XCTAssertEqual(watch.state, field)

    observe()
    field.inSheet = true
    center.post(name: NSWindow.didBecomeKeyNotification, object: nil)
    XCTAssertEqual(told.value, 2)
    XCTAssertEqual(watch.state.undoTarget(storeCanUndo: true), .none)
  }
}
