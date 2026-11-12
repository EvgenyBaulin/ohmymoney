import AppKit
import SwiftUI
import XCTest

@testable import OhMyMoney

/// A theme is colours and nothing else (0632): the same screen, laid out in two very different
/// themes (and in both schemes), has the same size and the same element frames.
@MainActor
final class ThemeLayoutIndependenceTests: XCTestCase {
  private final class Box { var frames: [String: CGRect] = [:] }

  private func frames(_ id: ThemeID, _ palette: ThemePalette) -> [String: CGRect] {
    let colors = AppThemeColors(id: id, palette: palette)
    let box = Box()
    let root = VStack(alignment: .leading, spacing: 12) {
      ScreenHero(
        caption: "Total", figure: "1,234,567", lines: ["Line one", "Line two"],
        figureIdentifier: "t.hero.figure"
      )
      .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named("root")) }) {
        box.frames["hero"] = $0
      }
      ListSurface()
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named("root")) }) {
          box.frames["list"] = $0
        }
    }
    .frame(width: 480)
    .coordinateSpace(name: "root")
    .environment(\.appTheme, colors)
    let host = NSHostingView(rootView: root)
    let window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: 480, height: 600), styleMask: [.titled],
      backing: .buffered, defer: true)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    host.layoutSubtreeIfNeeded()
    box.frames["fitting"] = CGRect(origin: .zero, size: host.fittingSize)
    return box.frames
  }

  func testTheLayoutOfAScreenIsTheSameInEveryTheme() {
    let all = ThemeCatalog.all
    let reference = frames(all[0].id, all[0].light)
    XCTAssertEqual(reference.count, 3, "the frames were not measured")
    for theme in all {
      for (scheme, palette) in [("light", theme.light), ("dark", theme.dark)] {
        XCTAssertEqual(
          frames(theme.id, palette), reference, "theme \(theme.id.rawValue) \(scheme)")
      }
    }
  }

  /// A card-like block built from the theme's surface colours only.
  private struct ListSurface: View {
    @Environment(\.appTheme) private var theme
    var body: some View {
      VStack(alignment: .leading, spacing: 8) {
        Text(verbatim: "Row").foregroundStyle(theme.contentPrimary)
        Text(verbatim: "Second row").foregroundStyle(theme.contentSecondary)
      }
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(theme.surfaceCard, in: .rect(cornerRadius: 12))
      .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.borderCard))
    }
  }
}
