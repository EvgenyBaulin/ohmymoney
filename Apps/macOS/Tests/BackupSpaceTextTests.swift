import AppCore
import XCTest

@testable import OhMyMoney

/// What the Backups tab says before it deletes copies, in both languages.
@MainActor
final class BackupSpaceTextTests: XCTestCase {
  private func environment(_ choice: AppLanguage.Choice) -> AppEnvironment {
    let environment = AppEnvironment()
    environment.language.choice = choice
    return environment
  }

  private func entries(_ count: Int) -> [BackupEntry] {
    (0..<count).map {
      BackupEntry(
        id: "2026-01-\(String(format: "%02d", $0 + 1)) 10.00 · 1.12.0 · after a change.sqlite",
        moment: Date(timeIntervalSince1970: 1_780_000_000 + Double($0) * 86_400), kind: .change,
        bytes: 2_000_000)
    }
  }

  func testTheQuestionNamesWhatWillBeDeletedInBothLanguages() {
    for choice in [AppLanguage.Choice.english, .russian] {
      let environment = environment(choice)
      let plan = BackupSpace.Plan(removals: entries(3), staysLow: false)
      let text = BackupSpaceText.freeUpMessage(plan, in: environment)
      XCTAssertFalse(text.contains("backups."), "\(choice): \(text)")
      XCTAssertTrue(text.contains("3"), text)
      for entry in plan.removals { XCTAssertTrue(text.contains(entry.id), text) }
      XCTAssertFalse(text.contains("•\n"))
    }
  }

  func testALongListEndsWithHowManyMore() {
    let environment = environment(.english)
    let plan = BackupSpace.Plan(removals: entries(20), staysLow: false)
    let text = BackupSpaceText.freeUpMessage(plan, in: environment)
    XCTAssertEqual(
      text.split(separator: "\n").filter { $0.hasPrefix("•") }.count, BackupSpaceText.namesShown)
    XCTAssertTrue(text.contains("8 more"), text)
  }

  func testAPlanThatLeavesTheDiskLowSaysThereIsNothingMore() {
    for choice in [AppLanguage.Choice.english, .russian] {
      let environment = environment(choice)
      let plan = BackupSpace.Plan(removals: entries(1), staysLow: true)
      let text = BackupSpaceText.freeUpMessage(plan, in: environment)
      XCTAssertTrue(
        text.contains(environment.language("backups.freeUp.stillLow", table: "Settings")))
    }
  }

  func testNothingToDeleteHasItsOwnLine() {
    for choice in [AppLanguage.Choice.english, .russian] {
      let environment = environment(choice)
      let text = BackupSpaceText.freeUpMessage(
        BackupSpace.Plan(removals: [], staysLow: true), in: environment)
      XCTAssertEqual(text, environment.language("backups.freeUp.nothing", table: "Settings"))
      XCTAssertNotEqual(text, "backups.freeUp.nothing")
      let none = BackupSpaceText.oldUpdatesMessage([], in: environment)
      XCTAssertEqual(none, environment.language("backups.beforeUpdate.none", table: "Settings"))
    }
  }

  func testTheOldCopiesBeforeUpdatesAreListedAndTheNewestIsSaidToStay() {
    for choice in [AppLanguage.Choice.english, .russian] {
      let environment = environment(choice)
      let old = entries(2)
      let text = BackupSpaceText.oldUpdatesMessage(old, in: environment)
      for entry in old { XCTAssertTrue(text.contains(entry.id), text) }
      XCTAssertTrue(
        text.contains(environment.language("backups.beforeUpdate.newestStays", table: "Settings")))
    }
  }

  func testTheTotalOfTheCopiesBeforeUpdatesSaysTheyAreKept() {
    let english = BackupSpaceText.beforeUpdateTotal(
      count: 4, bytes: 38_000_000, in: environment(.english))
    XCTAssertTrue(english.contains("4") && english.contains("kept for ever"), english)
    let russian = BackupSpaceText.beforeUpdateTotal(
      count: 4, bytes: 38_000_000, in: environment(.russian))
    XCTAssertTrue(russian.contains("4") && russian.contains("хранятся всегда"), russian)
  }

  func testTheWarningNamesTheFreeSpaceAndPromisesNothingIsDeleted() {
    let english = BackupSpaceText.low(freeBytes: 640_000_000, in: environment(.english))
    XCTAssertTrue(english.contains("640") && english.contains("Nothing is deleted"), english)
    let russian = BackupSpaceText.low(freeBytes: 640_000_000, in: environment(.russian))
    XCTAssertTrue(russian.contains("640") && russian.contains("Ничего не удаляется"), russian)
  }

  func testEveryNewKeyHasBothLanguages() {
    let keys = [
      "backups.readable.note", "backups.space.low", "backups.space.freeUp", "backups.freeUp.title",
      "backups.freeUp.stillLow", "backups.freeUp.nothing", "backups.freeUp.yes",
      "backups.freeUp.no", "backups.beforeUpdate.keptForever", "backups.beforeUpdate.deleteOld",
      "backups.beforeUpdate.confirmTitle", "backups.beforeUpdate.none",
      "backups.beforeUpdate.newestStays", "backups.row.unverified",
    ]
    for choice in [AppLanguage.Choice.english, .russian] {
      let language = AppLanguage()
      language.choice = choice
      for key in keys {
        XCTAssertNotEqual(language(key, table: "Settings"), key, "\(key) in \(choice.rawValue)")
      }
    }
    XCTAssertTrue(
      environment(.english).language("backups.readable.note", table: "Settings")
        .contains("this Mac only"))
    XCTAssertTrue(
      environment(.russian).language("backups.readable.note", table: "Settings")
        .contains("только на этом Mac"))
  }
}
