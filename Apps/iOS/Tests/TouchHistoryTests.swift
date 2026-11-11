import AppCore
import AppDatabase
import SwiftUI
import UIKit
import XCTest

@testable import OhMyMoney

@MainActor
final class TouchHistoryTests: XCTestCase {
  func testHardwareShortcutsUseCommandZAndShiftCommandZ() {
    XCTAssertEqual(TouchHistoryAction.undo.modifiers, .command)
    XCTAssertEqual(TouchHistoryAction.redo.modifiers, [.command, .shift])
  }

  private func store() throws -> (TransactionsStore, TransactionRepository) {
    let stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    let repository = TransactionRepository(writer: stack.writer)
    return (
      TransactionsStore(
        repository: repository, references: ReferenceRepository(writer: stack.writer)),
      repository
    )
  }

  private func entry() throws -> TransactionEntry {
    var draft = TransactionDraft(
      occurredAt: CalendarContext.system.noon(of: DateOnly(year: 2026, month: 11, day: 11)),
      amount: AmountE4(whole: 100), note: "Coffee")
    draft.normalizeSinglePart()
    return try draft.materialize()
  }

  func testTheBannerOffersRedoAfterUndoAndReplaysTheSameOperation() throws {
    let (store, repository) = try store()
    XCTAssertTrue(TouchHistoryAction.available(in: store).isEmpty)
    let saved = try entry()
    XCTAssertTrue(store.save(saved))
    XCTAssertEqual(TouchHistoryAction.available(in: store), [.undo])
    TouchHistoryAction.undo.perform(in: store)
    XCTAssertNil(try repository.entry(id: saved.id))
    XCTAssertEqual(TouchHistoryAction.available(in: store), [.redo])
    TouchHistoryAction.redo.perform(in: store)
    XCTAssertNotNil(try repository.entry(id: saved.id))
    XCTAssertEqual(TouchHistoryAction.available(in: store), [.undo])
  }

  func testUndoAndRedoCanStandTogetherAndANewWriteClearsRedo() throws {
    let (store, _) = try store()
    XCTAssertTrue(store.save(try entry()))
    XCTAssertTrue(store.save(try entry()))
    TouchHistoryAction.undo.perform(in: store)
    XCTAssertEqual(TouchHistoryAction.available(in: store), [.undo, .redo])
    XCTAssertTrue(store.save(try entry()))
    XCTAssertEqual(TouchHistoryAction.available(in: store), [.undo])
    store.isReadOnly = { true }
    XCTAssertTrue(TouchHistoryAction.available(in: store).isEmpty)
  }

  func testTheTwoButtonsFitANarrowPhoneAndBothTouchIdioms() throws {
    let (store, _) = try store()
    XCTAssertTrue(store.save(try entry()))
    XCTAssertTrue(store.save(try entry()))
    store.undo()
    let environment = AppEnvironment()
    let before = environment.language.choice
    defer { environment.language.choice = before }
    for language in [AppLanguage.Choice.russian, .english] {
      environment.language.choice = language
      for idiom in [LayoutIdiom.phone, .pad] {
        let bar = TouchHistoryBar(store: store)
          .environment(\.layoutIdiom, idiom)
          .appDependencies(.forTests(environment))
        let host = UIHostingController(rootView: bar)
        let size = host.sizeThatFits(in: CGSize(width: 288, height: 300))
        XCTAssertLessThanOrEqual(size.width, 288)
        XCTAssertGreaterThanOrEqual(size.height, 44)
        for action in TouchHistoryAction.allCases {
          XCTAssertNotEqual(environment.language(action.titleKey), action.titleKey)
        }
      }
    }
  }
}
