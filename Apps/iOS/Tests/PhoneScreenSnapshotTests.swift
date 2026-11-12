import AppCore
import SwiftUI
import UIKit
import XCTest

@testable import OhMyMoney

/// The main screens of the iPhone (402 pt wide) and the iPad (1366 × 1024) — Overview,
/// Operations, Planning, Debts, Capital and the editor of an operation with parts — over a
/// synthetic book drawn up to a fixed day, in three themes and in light and dark, compared with
/// the pictures kept in `Snapshots/` (`ScreenSnapshots`). To record the references again, run
/// these tests with `TEST_RUNNER_OHMYMONEY_RECORD_SNAPSHOTS=1` and look at the pictures before
/// committing them.
@MainActor
final class PhoneScreenSnapshotTests: XCTestCase {
  private struct Device {
    let name: String
    let size: CGSize
    let idiom: LayoutIdiom
    let referenceWidth: Int
  }

  private static let phone = Device(
    name: "phone", size: PhoneSize.regular, idiom: .phone,
    referenceWidth: ScreenSnapshots.ReferenceWidth.phone)
  private static let pad = Device(
    name: "pad", size: PadSize.landscape, idiom: .pad,
    referenceWidth: ScreenSnapshots.ReferenceWidth.tablet)

  private static let screens: [(String, PhoneScreen)] = [
    ("overview", .tab(.overview)), ("operations", .tab(.operations)),
    ("planning", .tab(.planning)), ("debts", .more(.debts)), ("capital", .more(.capital)),
  ]

  /// `language` marks the pictures of another language than Russian (`pad-01-en-light-debts`);
  /// `only` limits the walk to some screens, and then the editor is left out.
  private func run(
    _ device: Device, theme number: String, language: AppLanguage.Choice = .russian,
    only: Set<String>? = nil
  ) async throws {
    executionTimeAllowance = 300
    let id = try XCTUnwrap(ThemeID(rawValue: number))
    let harness = try await PhoneHarness.make(language: language, now: ScreenSnapshots.fixedNow)
    let tag = language == .russian ? "" : "-\(language == .english ? "en" : language.rawValue)"
    let before = harness.environment.theme.themeID
    harness.environment.theme.themeID = id
    for dark in [false, true] {
      let stem = "\(device.name)-\(number)\(tag)-\(dark ? "dark" : "light")"
      for (name, screen) in Self.screens where only?.contains(name) ?? true {
        let shown = PhoneScreenRegistry.open(
          screen, in: harness, size: device.size, dark: dark, idiom: device.idiom)
        check(shown.window, "\(stem)-\(name)", device: device, harness: harness)
        harness.close(shown.window)
      }
      if only != nil { continue }
      if let entry = harness.sampleEntries.first(where: { $0.parts.count >= 3 })
        ?? harness.sampleEntries.first(where: { $0.parts.count == 2 })
      {
        let (window, _) = harness.host(
          EditTransactionSheet(entry: entry), size: device.size, dark: dark,
          idiom: device.idiom == .pad ? .pad : nil)
        check(window, "\(stem)-editor", device: device, harness: harness)
        harness.close(window)
      } else {
        XCTFail("the synthetic book has no operation with parts")
      }
    }
    harness.environment.theme.themeID = before
    await harness.tearDown()
  }

  /// Takes the picture again until two in a row agree: a screen under load lays out late.
  private func check(_ window: UIWindow, _ name: String, device: Device, harness: PhoneHarness) {
    var last: ScreenSnapshots.Pixels?
    var latest = Data()
    for _ in 0..<8 {
      harness.settle(window, passes: 12)
      guard let data = harness.picture(of: window).pngData() else { break }
      latest = data
      let pixels = ScreenSnapshots.pixels(fromPNG: data, width: device.referenceWidth)
      if let pixels, let last, last.height == pixels.height,
        ScreenSnapshots.compare(pixels, with: last, threshold: 4).differing == 0
      {
        break
      }
      last = pixels
    }
    ScreenSnapshots.verify(png: latest, name: name, width: device.referenceWidth, test: self)
  }

  func testPhoneTheme01() async throws { try await run(Self.phone, theme: "01") }
  func testPhoneTheme09() async throws { try await run(Self.phone, theme: "09") }
  func testPhoneTheme15() async throws { try await run(Self.phone, theme: "15") }
  func testPadTheme01() async throws { try await run(Self.pad, theme: "01") }
  func testPadTheme09() async throws { try await run(Self.pad, theme: "09") }
  func testPadTheme15() async throws { try await run(Self.pad, theme: "15") }

  /// «Долги» on the iPad in English: its long labels once hung the layout.
  func testPadDebtsEnglishTheme01() async throws {
    try await run(Self.pad, theme: "01", language: .english, only: ["debts"])
  }
}
