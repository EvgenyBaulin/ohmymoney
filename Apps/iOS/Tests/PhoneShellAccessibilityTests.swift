import AppCore
import UIKit
import XCTest

@testable import OhMyMoney

/// What VoiceOver finds on the shell of the phone: every section of the bar named and the open
/// one told by its trait, the round «+» named, a name for every control of every screen, and the
/// names following the language of the app while it is open. Read from the accessibility tree
/// of hosted windows.
@MainActor
final class PhoneShellAccessibilityTests: XCTestCase {
  private let size = PhoneSize.regular

  private func barTitles(_ environment: AppEnvironment) -> [String] {
    [
      environment.language("section.overview"),
      environment.language("section.operations"),
      environment.language("phone.tab.planning", table: "Phone"),
      environment.language("accounts.section.accounts", table: "Accounts"),
      environment.language("phone.tab.more", table: "Phone"),
    ]
  }

  /// The controls of the bar by position from the left.
  private func bar(_ harness: PhoneHarness, _ shown: PhoneScreenShown) -> [AXLeaf] {
    let titles = barTitles(harness.environment)
    return harness.leaves(of: shown.window, in: shown.content)
      .filter { titles.contains($0.label) && $0.isControl && $0.frame.maxY > size.height - 60 }
      .sorted { $0.frame.minX < $1.frame.minX }
  }

  func testTheBarNamesEveryTabAndMarksOnlyTheOpenOne() async throws {
    executionTimeAllowance = 300
    let harness = try await PhoneHarness.make()
    for (index, tab) in PhoneTab.allCases.enumerated() {
      let shown = PhoneScreenRegistry.open(.tab(tab), in: harness, size: size)
      let controls = bar(harness, shown)
      harness.close(shown.window)
      XCTAssertEqual(Set(controls.map(\.label)).count, 5, "five different names at \(tab)")
      let selected = controls.enumerated().filter { $0.element.traits.contains(.selected) }
      XCTAssertEqual(selected.count, 1, "exactly one tab is open at \(tab)")
      XCTAssertEqual(selected.first?.offset, index, "the open tab is told at \(tab)")
    }
    await harness.tearDown()
  }

  func testTheRoundPlusHasAName() async throws {
    let harness = try await PhoneHarness.make()
    let shown = PhoneScreenRegistry.open(.tab(.operations), in: harness, size: size)
    let title = harness.environment.language("phone.entry.new", table: "Phone")
    let plus = harness.leaves(of: shown.window, in: shown.content).filter { $0.label == title }
    harness.close(shown.window)
    XCTAssertFalse(title.isEmpty)
    XCTAssertNotEqual(title, "phone.entry.new", "the name is a sentence, not a key")
    XCTAssertEqual(plus.count, 1, "one round «+» named «\(title)»")
    XCTAssertTrue(plus.first?.isControl ?? false, "VoiceOver reads it as a button")
    await harness.tearDown()
  }

  func testTheNamesOfTheBarFollowALanguageChangedWhileItIsOpen() async throws {
    executionTimeAllowance = 300
    let harness = try await PhoneHarness.make(language: .russian)
    let shown = PhoneScreenRegistry.open(.tab(.overview), in: harness, size: size)
    let russian = bar(harness, shown).map(\.label)
    XCTAssertEqual(russian.count, 5)

    harness.environment.language.choice = .english
    harness.settleStable(shown.window)
    let english = bar(harness, shown).map(\.label)
    XCTAssertEqual(english.count, 5, "the bar is still there after the change")
    XCTAssertNotEqual(english, russian)
    XCTAssertEqual(english, barTitles(harness.environment))
    XCTAssertFalse(english.contains { $0.contains(".") && !$0.contains(" ") }, "\(english)")
    harness.close(shown.window)
    await harness.tearDown()
  }

  func testEveryControlOfEveryScreenHasAName() async throws {
    executionTimeAllowance = 300
    let harness = try await PhoneHarness.make()
    var report: [String] = []
    for screen in PhoneScreen.all {
      let shown = PhoneScreenRegistry.open(screen, in: harness, size: size)
      let unnamed = harness.leaves(of: shown.window, in: shown.content)
        .filter { $0.isControl && $0.label.trimmingCharacters(in: .whitespaces).isEmpty }
        .filter { $0.frame.width >= 1 && $0.frame.height >= 1 }
      harness.close(shown.window)
      let allowed = PhoneUnnamedControlBaseline.counts[screen.description] ?? 0
      if unnamed.count != allowed {
        report.append(
          "\(screen): \(unnamed.count) controls without a name, the baseline has \(allowed): "
            + unnamed.map { "id «\($0.identifier)» at \(Int($0.frame.minX)),\(Int($0.frame.minY))" }
            .joined(separator: "; "))
      }
    }
    await harness.tearDown()
    XCTAssertTrue(report.isEmpty, report.joined(separator: "\n"))
  }

  func testEveryControlOfEveryScreenHasANameInAnEmptyBook() async throws {
    executionTimeAllowance = 300
    let harness = try await PhoneHarness.make(withData: false, language: .english)
    var report: [String] = []
    for screen in PhoneScreen.all {
      let shown = PhoneScreenRegistry.open(screen, in: harness, size: PhoneSize.narrow)
      let unnamed = harness.leaves(of: shown.window, in: shown.content)
        .filter { $0.isControl && $0.label.trimmingCharacters(in: .whitespaces).isEmpty }
        .filter { $0.frame.width >= 1 && $0.frame.height >= 1 }
      harness.close(shown.window)
      let allowed = PhoneUnnamedControlBaseline.emptyBookCounts[screen.description] ?? 0
      if unnamed.count != allowed {
        report.append(
          "\(screen): \(unnamed.count) controls without a name, the baseline has \(allowed): "
            + unnamed.map { "id «\($0.identifier)» at \(Int($0.frame.minX)),\(Int($0.frame.minY))" }
            .joined(separator: "; "))
      }
    }
    await harness.tearDown()
    XCTAssertTrue(report.isEmpty, report.joined(separator: "\n"))
  }
}

/// Controls a screen has without a name for VoiceOver, counted per screen, found when the test
/// was written. A screen may only get fewer: a new unnamed control fails the test, and a
/// fixed one fails it until it is taken out here.
enum PhoneUnnamedControlBaseline {
  static let counts: [String: Int] = [:]
  static let emptyBookCounts: [String: Int] = [:]
}
