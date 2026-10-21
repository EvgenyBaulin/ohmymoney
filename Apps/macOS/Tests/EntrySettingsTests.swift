import AppCore
import XCTest

@testable import OhMyMoney

/// Settings → «Ввод»: a move is written at once and a new launch reads it back; «Сбросить» brings
/// the order of 1.1 back. The order is the owner's own key in the test host's defaults:
/// `AppDefaultsGuard` clears it before every test and puts the owner's back afterwards.
@MainActor
final class EntrySettingsTests: XCTestCase {
  func testAMoveIsWrittenAtOnceAndReadBackByANewEnvironment() {
    let environment = AppEnvironment()
    // Drag «Комментарий» to the top.
    let note = EntryField.allCases.firstIndex(of: .note)!
    EntrySettingsActions.move(environment, from: IndexSet(integer: note), to: 0)
    XCTAssertEqual(environment.entryFieldOrder.first, .note)
    XCTAssertEqual(AppEnvironment().entryFieldOrder, environment.entryFieldOrder)

    // «Ниже» and «Выше», for the keyboard and VoiceOver.
    EntrySettingsActions.move(environment, .note, by: 1)
    XCTAssertEqual(Array(environment.entryFieldOrder.prefix(2)), [.amount, .note])
    EntrySettingsActions.move(environment, .note, by: -1)
    XCTAssertEqual(environment.entryFieldOrder.first, .note)
    XCTAssertFalse(EntrySettingsActions.canMove(environment, .note, by: -1))
    XCTAssertFalse(EntrySettingsActions.canMove(environment, .currency, by: 1))
    XCTAssertEqual(environment.entryFieldOrder.count, EntryField.allCases.count)
  }

  func testResetBringsTheStandardOrderBack() {
    let environment = AppEnvironment()
    EntrySettingsActions.move(environment, .date, by: -1)
    XCTAssertFalse(EntryFieldOrder.isStandard(environment.entryFieldOrder))
    EntrySettingsActions.reset(environment)
    XCTAssertTrue(EntryFieldOrder.isStandard(environment.entryFieldOrder))
    XCTAssertEqual(AppEnvironment().entryFieldOrder, EntryFieldOrder.standard)
  }

  /// Every field has a name in the list, in both languages.
  func testEveryFieldIsNamed() {
    let environment = AppEnvironment()
    for choice in [AppLanguage.Choice.english, .russian] {
      environment.language.choice = choice
      let names = EntryField.allCases.map { EntrySettingsView.name(of: $0, environment) }
      XCTAssertEqual(Set(names).count, EntryField.allCases.count)
      XCTAssertFalse(names.contains { $0.hasPrefix("settings.entry.") })
    }
  }
}
