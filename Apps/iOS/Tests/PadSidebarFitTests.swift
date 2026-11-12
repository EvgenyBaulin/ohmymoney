import SwiftUI
import UIKit
import XCTest

@testable import OhMyMoney

/// The sidebar of an iPad at the sizes of the iPad Pro 12.9 and the iPad 11, both ways up: the
/// foot («Настройки») has a place of its own under the list and hides what is scrolled behind
/// it, a figure of an account is one line and whole beside a long name, and the last tiles of a
/// screen can be scrolled out from under the round «+».
@MainActor
final class PadSidebarFitTests: XCTestCase {
  private var windows: [UIWindow] = []

  private static let screens: [CGSize] = [
    CGSize(width: 1366, height: 1024), CGSize(width: 1024, height: 1366),
    CGSize(width: 1194, height: 834), CGSize(width: 834, height: 1194),
  ]

  override func tearDown() async throws {
    for window in windows {
      window.rootViewController = nil
      window.isHidden = true
    }
    windows = []
  }

  // MARK: Figures

  func testAFigureStaysOneLineBesideALongNameAtEverySize() {
    let names = [
      "Очень длинное название накопительного счёта в банке",
      "A very long name of a savings account at the bank",
    ]
    let figures = ["1 234 567,89 ₽", "1,234,567.89 ₽", "≈ 18,531 ₽"]
    // The panel is 250 pt at every window size; the list keeps 16 pt at each side of a row.
    let width = CGFloat(PadLayout.sidebarWidth) - 32
    for name in names {
      for figure in figures {
        let long = fittingSize(row(name: name, main: figure), width: width)
        let short = fittingSize(row(name: "A", main: figure), width: width)
        XCTAssertEqual(long.height, short.height, accuracy: 0.5, "\(figure) wraps beside \(name)")
        XCTAssertLessThanOrEqual(long.width, width + 0.5)
      }
    }
  }

  func testTheFigureIsWholeAndTheNameIsTheOneCutShort() {
    let width = CGFloat(PadLayout.sidebarWidth) - 32
    let withFigure = fittingSize(row(name: "A", main: "1,234,567.89 ₽"), width: 1_000)
    // The figure alone needs this much; a long name leaves it exactly that.
    let narrow = fittingSize(
      row(name: String(repeating: "Wide ", count: 20), main: "1,234,567.89 ₽"), width: width)
    XCTAssertLessThanOrEqual(narrow.width, width + 0.5)
    XCTAssertGreaterThan(withFigure.width, 60)
  }

  private func row(name: String, main: String) -> some View {
    SidebarAccountRowBody(
      name: name, nameFont: AccountsSidebarMetrics.memberName, dot: .gray, isMain: false,
      main: main, caption: nil, mainLabel: "")
  }

  private func fittingSize<V: View>(_ view: V, width: CGFloat) -> CGSize {
    let controller = UIHostingController(rootView: view)
    return controller.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
  }

  // MARK: Foot

  func testTheFootHidesWhatScrollsBehindItAndTheListEndsAboveIt() throws {
    for screen in Self.screens {
      let size = CGSize(width: CGFloat(PadLayout.sidebarWidth), height: screen.height)
      let footTop = FootBox()
      let window = host(
        FootProbe(footTop: footTop), size: size)
      settle(window)
      let top = try XCTUnwrap(footTop.minY, "the foot was not laid out")

      // At rest, a red row lies where the foot is, and the foot is painted over it.
      var picture = try Picture(window: window)
      XCTAssertTrue(
        picture.isGreen(x: 4, y: top + 8), "a row shows through the foot at \(screen)")

      // Scrolled to its end, the list stops above the foot: the last (blue) row is whole.
      let scroll = try XCTUnwrap(scrollView(in: window))
      scrollToEnd(scroll, in: window)
      picture = try Picture(window: window)
      XCTAssertTrue(
        picture.isBlue(x: 4, y: top - 6),
        "the last row is under the foot at \(screen)")
      XCTAssertTrue(
        picture.isBlue(x: 4, y: top - FootProbe.rowHeight + 6),
        "the last row is cut by the foot at \(screen)")
    }
  }

  // MARK: The round plus

  func testScrolledContentLeavesRoomUnderTheTabletsPlus() {
    let clear = PhoneContent<EmptyView, EmptyView>.scrollClearance(onPhone: false)
    XCTAssertGreaterThanOrEqual(
      clear, EntryPlusMetrics.padDiameter + EntryPlusMetrics.padMargin)
    XCTAssertEqual(
      PhoneContent<EmptyView, EmptyView>.scrollClearance(onPhone: true),
      PhoneEntryButton.scrollClearance)
  }

  // MARK: Hosting

  private func host<Content: View>(_ content: Content, size: CGSize) -> UIWindow {
    let controller = UIHostingController(rootView: content)
    let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
    window.frame = CGRect(origin: .zero, size: size)
    window.windowLevel = .alert + 1
    controller.safeAreaRegions = []
    window.rootViewController = controller
    window.isHidden = false
    controller.view.frame = window.bounds
    windows.append(window)
    return window
  }

  private func settle(_ window: UIWindow, passes: Int = 30) {
    for _ in 0..<passes {
      window.layoutIfNeeded()
      RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
  }

  /// A list sizes its rows lazily, so the content grows while it is scrolled; the end is reached
  /// only when the offset sits at the end and neither the content nor the insets move any more.
  private func scrollToEnd(_ scroll: UIScrollView, in window: UIWindow) {
    var last: (CGFloat, CGFloat, CGFloat)?
    var stable = 0
    for _ in 0..<200 where stable < 5 {
      scroll.contentOffset.y =
        scroll.contentSize.height + scroll.adjustedContentInset.bottom - scroll.bounds.height
      settle(window, passes: 3)
      let now = (
        scroll.contentSize.height, scroll.adjustedContentInset.bottom, scroll.contentOffset.y
      )
      let atEnd =
        abs(now.2 - (now.0 + now.1 - scroll.bounds.height)) < 0.5
      if atEnd, let last, last == now { stable += 1 } else { stable = 0 }
      last = now
    }
    settle(window)
  }

  private func scrollView(in view: UIView) -> UIScrollView? {
    if let scroll = view as? UIScrollView { return scroll }
    for child in view.subviews { if let found = scrollView(in: child) { return found } }
    return nil
  }
}

@MainActor
private final class FootBox {
  var minY: CGFloat?
}

/// A list of red rows, the last one blue, with a green foot, as the sidebar is built.
private struct FootProbe: View {
  static let rowHeight: CGFloat = 40
  // Pure sRGB colours: the system's red, green and blue shift with every OS (the blue has a
  // green part of 136 now), and the picture is read by channel.
  static let row = Color(red: 1, green: 0, blue: 0)
  static let last = Color(red: 0, green: 0, blue: 1)
  static let foot = Color(red: 0, green: 1, blue: 0)
  let footTop: FootBox

  var body: some View {
    List {
      ForEach(0..<60, id: \.self) { index in
        (index == 59 ? FootProbe.last : FootProbe.row)
          .frame(height: Self.rowHeight)
          .listRowInsets(EdgeInsets())
          .listRowSeparator(.hidden)
          .listRowBackground(Color.clear)
      }
    }
    .listStyle(.plain)
    .environment(\.defaultMinListRowHeight, 0)
    .scrollContentBackground(.hidden)
    .padSidebarFoot(background: Self.foot) {
      Text(verbatim: "Settings")
        .frame(height: 56)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
          // geometry: a test probe reads where the foot starts to check pixels; nothing lays out by it
          footTop.minY = $0.minY
        }
    }
  }
}

private struct Picture {
  private let pixels: [UInt8]
  private let width: Int

  init(window: UIWindow) throws {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true
    let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
      window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
    }
    let cg = try XCTUnwrap(image.cgImage)
    width = cg.width
    var data = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
    let context = try XCTUnwrap(
      CGContext(
        data: &data, width: cg.width, height: cg.height, bitsPerComponent: 8,
        bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
    pixels = data
  }

  private func rgb(_ x: Int, _ y: CGFloat) -> (Int, Int, Int) {
    let at = (Int(y) * width + x) * 4
    return (Int(pixels[at]), Int(pixels[at + 1]), Int(pixels[at + 2]))
  }

  func isGreen(x: Int, y: CGFloat) -> Bool {
    let (r, g, b) = rgb(x, y)
    return g > 150 && r < 100 && b < 100
  }

  func isBlue(x: Int, y: CGFloat) -> Bool {
    let (r, g, b) = rgb(x, y)
    return b > 150 && r < 100 && g < 100
  }
}
