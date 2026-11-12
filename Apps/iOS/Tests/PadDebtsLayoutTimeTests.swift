import AppCore
import SwiftUI
import UIKit
import XCTest

@testable import OhMyMoney

/// «Долги» on an iPad (1366 × 1024) lays out in a moment in both languages. The English screen
/// once sat for minutes inside SwiftUI's `sizeThatFits`: a layout whose cost grows with the text
/// is a hang, not a slow test, so each language gets a budget of a few seconds.
@MainActor
final class PadDebtsLayoutTimeTests: XCTestCase {
  private func timeToLayOut(_ language: AppLanguage.Choice) async throws -> TimeInterval {
    executionTimeAllowance = 120
    let harness = try await PhoneHarness.make(language: language, now: ScreenSnapshots.fixedNow)
    let started = Date()
    let shown = PhoneScreenRegistry.open(
      .more(.debts), in: harness, size: PadSize.landscape, dark: false, idiom: .pad)
    harness.settle(shown.window, passes: 12)
    let spent = Date().timeIntervalSince(started)
    harness.close(shown.window)
    await harness.tearDown()
    return spent
  }

  func testDebtsOnAnIPadLaysOutQuicklyInEnglish() async throws {
    let spent = try await timeToLayOut(.english)
    XCTAssertLessThan(spent, 2, "English «Долги» took \(spent) s to lay out on an iPad")
  }

  func testDebtsOnAnIPadLaysOutQuicklyInRussian() async throws {
    let spent = try await timeToLayOut(.russian)
    XCTAssertLessThan(spent, 2, "Russian «Долги» took \(spent) s to lay out on an iPad")
  }
}
