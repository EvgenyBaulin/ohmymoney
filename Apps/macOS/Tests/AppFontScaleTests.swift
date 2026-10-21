import AppKit
import SwiftUI
import XCTest

@testable import OhMyMoney

/// Every font the app names grows with the size of the text (`AppFont`, `.appFont(_:)`):
/// «Обычный» is the system's own text styles, unchanged; «Крупный» and «Очень крупный» are
/// larger in every style, «Мелкий» smaller; amounts keep digits of one width at every size.
@MainActor
final class AppFontScaleTests: XCTestCase {
  private static let styles: [(Font.TextStyle, NSFont.TextStyle, AppFont, Font)] = [
    (.largeTitle, .largeTitle, .largeTitle, .largeTitle),
    (.title, .title1, .title, .title),
    (.title2, .title2, .title2, .title2),
    (.title3, .title3, .title3, .title3),
    (.headline, .headline, .headline, .headline),
    (.subheadline, .subheadline, .subheadline, .subheadline),
    (.body, .body, .body, .body),
    (.callout, .callout, .callout, .callout),
    (.footnote, .footnote, .footnote, .footnote),
    (.caption, .caption1, .caption, .caption),
    (.caption2, .caption2, .caption2, .caption2),
  ]

  private func width(of view: some View) -> CGFloat {
    // dependencies: none — plain text measured for its width, nothing reads the environment.
    NSHostingView(rootView: view.fixedSize()).fittingSize.width
  }

  private func deps(_ size: AppFontSize) -> AppDependencies {
    let environment = AppEnvironment()
    environment.theme.fontSize = size
    return AppDependencies.forTests(environment)
  }

  /// «Обычный» is the very `Font` the app wrote before the sizes: the style, then its modifiers
  /// in the order written.
  func testRegularIsTheSystemsFontValueForValue() {
    for (_, _, app, system) in Self.styles {
      XCTAssertEqual(app.font(at: .regular), system)
      XCTAssertEqual(app.monospacedDigit().font(at: .regular), system.monospacedDigit())
      XCTAssertEqual(
        app.monospacedDigit().weight(.semibold).font(at: .regular),
        system.monospacedDigit().weight(.semibold))
      XCTAssertEqual(app.bold().italic().font(at: .regular), system.bold().italic())
      XCTAssertEqual(app.monospaced().font(at: .regular), system.monospaced())
    }
    XCTAssertEqual(AppFont.system(size: 14).font(at: .regular), Font.system(size: 14))
    XCTAssertEqual(
      AppFont.system(.body, design: .rounded).font(at: .regular),
      Font.system(.body, design: .rounded))
  }

  /// The column of «Обычный» in the table is the size macOS draws each style at.
  func testTheTableOfRegularIsWhatMacOSDraws() {
    for (style, appKit, _, _) in Self.styles {
      XCTAssertEqual(
        AppFontSize.regular.points(of: style), NSFont.preferredFont(forTextStyle: appKit).pointSize,
        "\(style)")
    }
  }

  /// A text in a style at «Обычный» is exactly as wide as with the system's font.
  func testRegularDrawsTheTextAsBefore() {
    let words = "Можно тратить 12,345 ₽"
    for (style, _, app, system) in Self.styles {
      let before = width(of: Text(verbatim: words).font(system))
      let now = width(of: Text(verbatim: words).appFont(app).appDependencies(deps(.regular)))
      XCTAssertEqual(now, before, accuracy: 0.01, "\(style)")
    }
  }

  /// Every style grows from «Мелкий» to «Очень крупный», in the table and on the screen.
  func testEveryStyleGrowsWithTheSize() {
    let words = "Можно тратить 12,345 ₽"
    for (style, _, app, _) in Self.styles {
      let points = AppFontSize.allCases.map { $0.points(of: style) }
      XCTAssertEqual(points, points.sorted(), "\(style): \(points)")
      XCTAssertEqual(Set(points).count, points.count, "\(style): two sizes alike \(points)")
      let widths = AppFontSize.allCases.map {
        width(of: Text(verbatim: words).appFont(app.monospacedDigit()).appDependencies(deps($0)))
      }
      for (smaller, larger) in zip(widths, widths.dropFirst()) {
        XCTAssertGreaterThan(larger, smaller, "\(style): \(widths)")
      }
    }
    let points = AppFontSize.allCases.map { AppFont.system(size: 14).font(at: $0) }
    XCTAssertEqual(Set(points).count, 4, "a size in points does not grow")
  }

  /// The weight, the design and the digits of one width survive any size; the headline stays
  /// bold the way the system draws it.
  func testTheModifiersSurviveEverySize() {
    let words = "Итого"
    for size in AppFontSize.allCases where size != .regular {
      let plain = width(of: Text(verbatim: words).appFont(.body).appDependencies(deps(size)))
      let bold = width(of: Text(verbatim: words).appFont(.body.bold()).appDependencies(deps(size)))
      let headline = width(of: Text(verbatim: words).appFont(.headline).appDependencies(deps(size)))
      XCTAssertGreaterThan(bold, plain, "the weight is lost at \(size)")
      XCTAssertEqual(headline, bold, accuracy: 0.5, "the headline is not bold at \(size)")
      let mono = width(
        of: Text(verbatim: "iiii").appFont(.body.monospaced()).appDependencies(deps(size)))
      let wide = width(
        of: Text(verbatim: "MMMM").appFont(.body.monospaced()).appDependencies(deps(size)))
      XCTAssertEqual(mono, wide, accuracy: 0.5, "the design is lost at \(size)")
    }
  }

  /// Amounts keep digits of one width at every size and in every style the app writes them in.
  func testAmountsKeepDigitsOfOneWidthAtEverySize() {
    for size in AppFontSize.allCases {
      for font: AppFont in [
        .caption.monospacedDigit(), .callout.monospacedDigit(), .body.monospacedDigit(),
        .title2.monospacedDigit(), .headline.monospacedDigit(),
        .caption.monospacedDigit().weight(.semibold),
      ] {
        let ones = width(of: Text(verbatim: "1,111.11 ₽").appFont(font).appDependencies(deps(size)))
        let eights = width(
          of: Text(verbatim: "8,888.88 ₽").appFont(font).appDependencies(deps(size)))
        XCTAssertEqual(ones, eights, accuracy: 0.5, "digits of two widths at \(size): \(font)")
      }
    }
  }

  /// A font set on a container reaches the label and the text inside it, at the size chosen.
  func testAFontOnAContainerReachesItsTexts() {
    let label = Label {
      Text(verbatim: "Подушка безопасности")
    } icon: {
      Image(systemName: "shield")
    }
    let regular = width(of: VStack { label }.appFont(.caption).appDependencies(deps(.regular)))
    let xlarge = width(of: VStack { label }.appFont(.caption).appDependencies(deps(.xlarge)))
    XCTAssertGreaterThan(xlarge, regular)
  }

  /// A size written in points grows with the body, to whole points, never below 9 pt.
  func testASizeInPointsGrowsWithTheBody() {
    XCTAssertEqual(AppFontSize.regular.points(fromRegular: 14), 14)
    XCTAssertEqual(AppFontSize.xlarge.points(fromRegular: 13), 17)
    XCTAssertEqual(AppFontSize.small.points(fromRegular: 10), 9, "smaller than legible")
  }
}
