import AppCore
import SwiftUI
import UIKit
import XCTest

@testable import OhMyMoney

/// Every screen of the registry, and the editor of an operation in the shapes the owner looks
/// at (one part, several parts, a part paid for someone else, a part «for» someone), written as
/// PNG files for whoever looks at them. Off unless `TEST_RUNNER_OHMYMONEY_SCREENSHOT_DIR` names
/// a folder, which is then made if it is not there:
/// `<folder>/<device>-<width>x<height>-<ru|en>-<light|dark>/<screen>.png`.
/// One test per language and size keeps each under the time a test method is given.
@MainActor
final class PhoneScreenShotDumpTests: XCTestCase {
  private struct Device {
    let name: String
    let size: CGSize
    let idiom: LayoutIdiom
  }

  private static let phone402 = Device(name: "iPhone", size: PhoneSize.regular, idiom: .phone)
  private static let phone440 = Device(name: "iPhone", size: PhoneSize.wide, idiom: .phone)
  private static let padLandscape = Device(
    name: "iPad", size: PadSize.landscape, idiom: .pad)
  private static let padPortrait = Device(name: "iPad", size: PadSize.portrait, idiom: .pad)

  private func write(
    _ language: AppLanguage.Choice, _ device: Device
  ) async throws {
    guard let root = ProcessInfo.processInfo.environment["OHMYMONEY_SCREENSHOT_DIR"],
      !root.isEmpty
    else { return }
    executionTimeAllowance = 300
    let harness = try await PhoneHarness.make(language: language)
    for dark in [false, true] {
      let folder = URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent(
        "\(device.name)-\(Int(device.size.width))x\(Int(device.size.height))-\(language.rawValue)-\(dark ? "dark" : "light")",
        isDirectory: true)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      for screen in PhoneScreen.all {
        let shown = PhoneScreenRegistry.open(
          screen, in: harness, size: device.size, dark: dark, idiom: device.idiom)
        try save(shown.window, to: folder.appendingPathComponent("\(screen).png"), harness: harness)
        harness.close(shown.window)
      }
      for (name, entry) in editorEntries(harness) {
        let (window, _) = harness.host(
          EditTransactionSheet(entry: entry), size: device.size, dark: dark,
          idiom: device.idiom == .pad ? .pad : nil)
        harness.settleStable(window)
        try save(window, to: folder.appendingPathComponent("editor.\(name).png"), harness: harness)
        harness.close(window)
      }
    }
    await harness.tearDown()
  }

  /// The editor for what the book has: a plain operation, one with several parts, one with a
  /// part that is paid for someone else, one with a part named «for» someone.
  private func editorEntries(_ harness: PhoneHarness) -> [(String, TransactionEntry)] {
    let all = harness.sampleEntries
    var found: [(String, TransactionEntry)] = []
    if let one = all.first(where: { $0.parts.count == 1 }) { found.append(("onePart", one)) }
    if let many = all.first(where: { $0.parts.count >= 3 })
      ?? all.first(where: { $0.parts.count == 2 })
    {
      found.append(("severalParts", many))
    }
    if let other = all.first(where: { $0.parts.contains { $0.reimbursable } }) {
      found.append(("paidForSomeoneElse", other))
    }
    if let forWhom = all.first(where: {
      $0.parts.contains { $0.forPersonId != nil && !$0.reimbursable }
    }) {
      found.append(("forSomeone", forWhom))
    }
    return found
  }

  private func save(_ window: UIWindow, to url: URL, harness: PhoneHarness) throws {
    try XCTUnwrap(harness.picture(of: window).pngData()).write(to: url)
  }

  func testScreensRuIPhone402() async throws { try await write(.russian, Self.phone402) }
  func testScreensRuIPhone440() async throws { try await write(.russian, Self.phone440) }
  func testScreensRuIPadLandscape() async throws { try await write(.russian, Self.padLandscape) }
  func testScreensRuIPadPortrait() async throws { try await write(.russian, Self.padPortrait) }
  func testScreensEnIPhone402() async throws { try await write(.english, Self.phone402) }
  func testScreensEnIPhone440() async throws { try await write(.english, Self.phone440) }
  func testScreensEnIPadLandscape() async throws { try await write(.english, Self.padLandscape) }
  func testScreensEnIPadPortrait() async throws { try await write(.english, Self.padPortrait) }
}
