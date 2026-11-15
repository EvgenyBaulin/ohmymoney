import SwiftUI
import UIKit
import XCTest

@testable import OhMyMoney

/// The main screens of the phone in the languages that stress a layout: the two languages with
/// the longest texts (German and French run about a fifth longer than English), and Arabic and
/// Hebrew, which mirror the page. Nothing leaves the width of the screen, the bar of the sections
/// keeps its five items apart, and under a right-to-left language the bar and the page are
/// laid out mirrored: the first section stands at the right.
@MainActor
final class PhoneLanguageLayoutTests: XCTestCase {
  private let screens: [PhoneScreen] = [
    .tab(.overview), .tab(.operations), .tab(.planning), .tab(.accounts), .tab(.more),
  ]

  /// Screens that overflow a 375 pt phone in a language, found by this walk and not fixed yet:
  /// `screen@language`. None now; a listed screen must still fail — the walk complains once it
  /// fits, so the entry comes out with the fix — and an unlisted one must fit.
  private static let knownOverflows: Set<String> = []

  private func walk(
    _ language: AppLanguage.Choice, size: CGSize, fontSize: AppFontSize = .regular
  )
    async throws
  {
    let harness = try await PhoneHarness.make(language: language)
    harness.environment.theme.fontSize = fontSize
    let audit = PhoneLayoutAudit(harness: harness)
    for screen in screens {
      let shown = PhoneScreenRegistry.open(screen, in: harness, size: size)
      let problems = audit.problems(shown, size: size)
      let mac = audit.macElements(shown)
      harness.close(shown.window)
      let where_ = "\(screen) in \(language.rawValue) at \(Int(size.width)) pt, \(fontSize)"
      if size.width == PhoneSize.narrow.width,
        Self.knownOverflows.contains("\(screen)@\(language.rawValue)")
      {
        XCTAssertFalse(
          problems.isEmpty, "\(where_) fits now: take it out of knownOverflows")
      } else {
        XCTAssertTrue(problems.isEmpty, "\(where_): " + problems.joined(separator: "; "))
      }
      XCTAssertTrue(
        mac.isEmpty, "\(screen) in \(language.rawValue): \(mac.joined(separator: "; "))")
    }
    await harness.tearDown()
  }

  func testTheLongestLanguagesFitTheNarrowestPhone() async throws {
    executionTimeAllowance = 300
    for language in [AppLanguage.Choice.german, .french] {
      try await walk(language, size: PhoneSize.narrow)
    }
  }

  func testTheLongestLanguagesFitTheNarrowestPhoneAtTheLargestText() async throws {
    executionTimeAllowance = 300
    for language in [AppLanguage.Choice.german, .french] {
      try await walk(language, size: PhoneSize.narrow, fontSize: .xlarge)
    }
  }

  func testArabicAndHebrewFitThePhone() async throws {
    executionTimeAllowance = 300
    for language in [AppLanguage.Choice.arabic, .hebrew] {
      try await walk(language, size: PhoneSize.narrow)
      try await walk(language, size: PhoneSize.wide)
    }
  }

  /// The sections of the bar by position from the left, read from the accessibility tree.
  private func barOrder(_ language: AppLanguage.Choice) async throws -> [String] {
    let harness = try await PhoneHarness.make(language: language)
    let size = PhoneSize.regular
    let shown = PhoneScreenRegistry.open(.tab(.overview), in: harness, size: size)
    let environment = harness.environment
    let sections: [(name: String, title: String)] = [
      ("overview", environment.language("section.overview")),
      ("operations", environment.language("section.operations")),
      // The bar of a phone says the short name of planning (`NavItem.phoneBarKey`).
      ("planning", environment.language("phone.tab.planning", table: "Phone")),
      ("accounts", environment.language("accounts.section.accounts", table: "Accounts")),
      ("more", environment.language("phone.tab.more", table: "Phone")),
    ]
    let bar = harness.leaves(of: shown.window, in: shown.content).filter { leaf in
      sections.contains { $0.title == leaf.label } && leaf.isControl
        && leaf.frame.maxY > size.height - 60
    }
    harness.close(shown.window)
    await harness.tearDown()
    var order: [String] = []
    for leaf in bar.sorted(by: { $0.frame.minX < $1.frame.minX }) {
      if let name = sections.first(where: { $0.title == leaf.label })?.name,
        !order.contains(name)
      {
        order.append(name)
      }
    }
    return order
  }

  func testTheBarIsMirroredUnderARightToLeftLanguage() async throws {
    executionTimeAllowance = 300
    let leftToRight = try await barOrder(.english)
    let rightToLeft = try await barOrder(.arabic)
    let hebrew = try await barOrder(.hebrew)
    XCTAssertEqual(leftToRight, ["overview", "operations", "planning", "accounts", "more"])
    XCTAssertEqual(rightToLeft, leftToRight.reversed())
    XCTAssertEqual(hebrew, leftToRight.reversed())
  }
}
