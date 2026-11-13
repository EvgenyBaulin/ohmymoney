import AppCore
import SwiftUI
import UIKit
import XCTest

@testable import OhMyMoney

/// Every screen of the phone (`PhoneScreen.all`) at the widths of the phones iOS 26 runs on —
/// 375, 402 and 440 pt — and at the largest size of the text, on a synthetic book and an empty
/// one: nothing wider than the screen or cut at its sides, every control at least 44 pt, the
/// round «+» and the bar of the sections not on top of each other; and no Mac element anywhere.
/// The screens are walked through the accessibility tree, the only place the frames of SwiftUI
/// text and buttons can be read from.
@MainActor
final class PhoneScreenLayoutTests: XCTestCase {
  private var harness: PhoneHarness!

  override func setUp() async throws {
    harness = try await PhoneHarness.make()
  }

  override func tearDown() async throws {
    await harness.tearDown()
    harness = nil
  }

  private var audit: PhoneLayoutAudit { PhoneLayoutAudit(harness: harness) }

  private func walk(
    size: CGSize, fontSize: AppFontSize = .regular, dark: Bool = false, idiom: LayoutIdiom = .phone,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    harness.environment.theme.fontSize = fontSize
    for screen in PhoneScreen.all {
      let shown = PhoneScreenRegistry.open(
        screen, in: harness, size: size, dark: dark, idiom: idiom)
      let layout = audit.problems(
        shown, size: size, reachesRightMargin: idiom == .phone && screen == .tab(.overview))
      let mac = audit.macElements(shown)
      harness.close(shown.window)
      let where_ = "\(screen) at \(Int(size.width)) pt, \(fontSize)"
      if PhoneLayoutKnownIssues.contains(
        screen, width: size.width, idiom: idiom, largestText: fontSize == .xlarge)
      {
        XCTAssertFalse(
          layout.isEmpty, "\(where_) fits now: take it out of PhoneLayoutKnownIssues",
          file: file, line: line)
      } else {
        XCTAssertTrue(
          layout.isEmpty, "\(where_): \(layout.joined(separator: "; "))", file: file, line: line)
      }
      XCTAssertTrue(
        mac.isEmpty, "\(screen) shows Mac elements: \(mac.joined(separator: "; "))",
        file: file, line: line)
    }
  }

  func testEveryScreenFitsAPhone375WideAtTheUsualTextSize() {
    executionTimeAllowance = 300
    walk(size: PhoneSize.narrow)
  }

  func testEveryScreenFitsAPhone402WideAtTheUsualTextSize() {
    executionTimeAllowance = 300
    walk(size: PhoneSize.regular)
  }

  func testEveryScreenFitsAPhone440WideAtTheUsualTextSize() {
    executionTimeAllowance = 300
    walk(size: PhoneSize.wide)
  }

  func testEveryScreenFitsAPhone375WideAtTheLargestTextSize() {
    executionTimeAllowance = 300
    walk(size: PhoneSize.narrow, fontSize: .xlarge)
  }

  func testEveryScreenFitsAPhone402WideAtTheLargestTextSize() {
    executionTimeAllowance = 300
    walk(size: PhoneSize.regular, fontSize: .xlarge)
  }

  func testEveryScreenFitsAPhone440WideAtTheLargestTextSize() {
    executionTimeAllowance = 300
    walk(size: PhoneSize.wide, fontSize: .xlarge)
  }

  func testEveryScreenFitsAnIPadPro12_9InEveryWindowSize() {
    executionTimeAllowance = 300
    for size in PadSize.all { walk(size: size, idiom: .pad) }
  }

  func testEveryScreenFitsAPhoneInTheDarkTheme() {
    executionTimeAllowance = 300
    walk(size: PhoneSize.regular, dark: true)
  }
}

/// The same walk over a book with nothing in it: the empty state of every screen.
@MainActor
final class PhoneScreenEmptyBookTests: XCTestCase {
  func testEveryScreenOfAnEmptyBookFitsAPhone375Wide() async throws {
    executionTimeAllowance = 300
    let harness = try await PhoneHarness.make(withData: false)
    let audit = PhoneLayoutAudit(harness: harness)
    for screen in PhoneScreen.all {
      let shown = PhoneScreenRegistry.open(screen, in: harness, size: PhoneSize.narrow)
      let layout = audit.problems(shown, size: PhoneSize.narrow)
      harness.close(shown.window)
      if PhoneLayoutKnownIssues.contains(screen, width: PhoneSize.narrow.width, idiom: .phone) {
        continue
      }
      XCTAssertTrue(layout.isEmpty, "\(screen), empty book: \(layout.joined(separator: "; "))")
    }
    await harness.tearDown()
  }
}

/// A picture of every screen, light and dark, kept with the result for the owner's eye (the
/// attachments of the test in the result bundle), and the Russian and English of the busiest.
@MainActor
final class PhoneScreenPictureTests: XCTestCase {
  private func pictures(
    dark: Bool, language: AppLanguage.Choice, screens: [PhoneScreen]
  ) async throws {
    executionTimeAllowance = 300
    let harness = try await PhoneHarness.make(language: language)
    for screen in screens {
      let shown = PhoneScreenRegistry.open(
        screen, in: harness, size: PhoneSize.regular, dark: dark)
      harness.attachPicture(
        of: shown.window,
        named: "\(screen) iPhone 402 \(dark ? "dark" : "light") \(language.rawValue)", to: self)
      harness.close(shown.window)
    }
    await harness.tearDown()
  }

  func testPicturesOfEveryScreenInTheLightTheme() async throws {
    try await pictures(dark: false, language: .russian, screens: PhoneScreen.all)
  }

  func testPicturesOfEveryScreenInTheDarkTheme() async throws {
    try await pictures(dark: true, language: .russian, screens: PhoneScreen.all)
  }

  func testPicturesOfTheTabsAndMoreInEnglish() async throws {
    try await pictures(
      dark: false, language: .english,
      screens: PhoneTab.allCases.map(PhoneScreen.tab) + [.more(.settings), .more(.debts)])
  }
}

/// Controls a finger can hit: no screen may gain a control smaller than 44 × 44 pt. The ones it
/// has are the baseline (`PhoneTouchTargetBaseline`) and are listed in the attachment of the test
/// for whoever fixes them.
@MainActor
final class PhoneScreenTouchTargetTests: XCTestCase {
  func testNoScreenGainsAControlUnderFortyFourPoints() async throws {
    executionTimeAllowance = 300
    let harness = try await PhoneHarness.make()
    let audit = PhoneLayoutAudit(harness: harness)
    var report: [String] = []
    for screen in PhoneScreen.all {
      let shown = PhoneScreenRegistry.open(screen, in: harness, size: PhoneSize.regular)
      let small = audit.smallControls(shown)
      harness.close(shown.window)
      report.append("\(screen): \(small.count)")
      report += small.map { "    \($0)" }
      let allowed = PhoneTouchTargetBaseline.counts[screen.description] ?? 0
      XCTAssertLessThanOrEqual(
        small.count, allowed,
        "\(screen) has \(small.count) controls under 44 pt, the baseline allows \(allowed): \(small.joined(separator: "; "))"
      )
    }
    let attachment = XCTAttachment(string: report.joined(separator: "\n"))
    attachment.name = "small controls"
    attachment.lifetime = .keepAlways
    add(attachment)
    await harness.tearDown()
  }
}

/// The two buttons of a payment on «Планирование»: each is one line at every phone width, in
/// both languages. «Пропустить» used to break into «Про-/пу-/стить» when the name and the
/// amount beside it took the room.
@MainActor
final class PhonePlanningButtonsTests: XCTestCase {
  func testMarkAsPaidAndSkipAreOneLineAtEveryPhoneWidthInBothLanguages() async throws {
    executionTimeAllowance = 300
    for language in [AppLanguage.Choice.russian, .english] {
      let harness = try await PhoneHarness.make(language: language)
      let environment = harness.environment
      let titles = [
        environment.language("scheduled.markAsPaid", table: "Planning"),
        environment.language("scheduled.skip", table: "Planning"),
      ]
      for size in PhoneSize.all {
        let shown = PhoneScreenRegistry.open(.tab(.planning), in: harness, size: size)
        let leaves = harness.leaves(of: shown.window, in: shown.content)
        harness.close(shown.window)
        let buttons = leaves.filter { titles.contains($0.label) && $0.isControl }
        XCTAssertFalse(
          buttons.isEmpty, "no payment button at \(Int(size.width)) pt (\(language.rawValue))")
        for button in buttons {
          XCTAssertLessThanOrEqual(
            button.frame.height, 34,
            "«\(button.label)» is \(Int(button.frame.width)) × \(Int(button.frame.height)) at \(Int(size.width)) pt (\(language.rawValue)): broken over lines"
          )
        }
      }
      await harness.tearDown()
    }
  }
}
