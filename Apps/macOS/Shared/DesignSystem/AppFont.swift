import SwiftUI

/// A font of the app that follows the size of the text chosen in Settings → Appearance
/// (`AppFontSize`). Written the way a `Font` is — `.caption`, `.headline.monospacedDigit()`,
/// `.callout.weight(.semibold)`, `.system(size: 14)` — and set with `.appFont(_:)` instead of
/// `.font(_:)`, which reads the size from the environment and writes the `Font` of that size.
///
/// macOS draws the text styles of SwiftUI at one size whatever `dynamicTypeSize` says, so a
/// `.font(.caption)` stays 10 pt at «Очень крупный». Every text style here has its point size
/// for each of the four choices (`AppFontSize.points(of:)`); «Обычный» is the system's own
/// style itself — `Font.caption`, not 10 pt written by hand — with the same modifiers applied in
/// the same order, so the app at «Обычный» is drawn exactly as before.
///
/// The modifiers are kept in the order they were written and replayed onto the font of the
/// size: the weight, the design, `.monospacedDigit()` (amounts keep digits of one width at every
/// size), `.italic()` survive any choice.
public struct AppFont: Hashable, Sendable {
  enum Base: Hashable, Sendable {
    case style(Font.TextStyle, design: Font.Design?)
    case points(CGFloat, weight: Font.Weight?, design: Font.Design?)
  }

  enum Step: Hashable, Sendable {
    case monospacedDigit
    case monospaced
    case bold
    case italic
    case weight(Font.Weight)
  }

  let base: Base
  let steps: [Step]

  private func adding(_ step: Step) -> AppFont { AppFont(base: base, steps: steps + [step]) }

  public func monospacedDigit() -> AppFont { adding(.monospacedDigit) }
  public func monospaced() -> AppFont { adding(.monospaced) }
  public func bold() -> AppFont { adding(.bold) }
  public func italic() -> AppFont { adding(.italic) }
  public func weight(_ weight: Font.Weight) -> AppFont { adding(.weight(weight)) }

  /// The font this one is at `size`. `designPoints` draws a text style at the points of the
  /// design's table (`AppFontSize.points(of:)`) at «Обычный» too, not at the system's size of the
  /// style: a phone's and a tablet's frames write their type in the Mac's points, which the
  /// styles of iOS draw several points larger. The Mac's styles are the table, so it changes
  /// nothing there.
  ///
  /// `dynamicType` matters for `system` only: the points follow it (`AppFontSize.systemScale`),
  /// and a text style not written in design points is the system's own, which grows by itself.
  public func font(
    at size: AppFontSize, designPoints: Bool = false, dynamicType: DynamicTypeSize = .large
  ) -> Font {
    steps.reduce(baseFont(at: size, designPoints: designPoints, dynamicType: dynamicType)) {
      font, step in
      switch step {
      case .monospacedDigit: font.monospacedDigit()
      case .monospaced: font.monospaced()
      case .bold: font.bold()
      case .italic: font.italic()
      case .weight(let weight): font.weight(weight)
      }
    }
  }

  /// The size this font is drawn at, in points; `nil` for the system's own size of a style.
  func points(
    at size: AppFontSize, designPoints: Bool = false, dynamicType: DynamicTypeSize = .large
  ) -> CGFloat? {
    let grown = growth(at: size, dynamicType: dynamicType)
    switch base {
    case .style(let style, _):
      if size == .system, !designPoints, let capped = Self.cappedHeadingPoints(style, dynamicType) {
        return capped
      }
      if (size == .system || size == .regular) && !designPoints { return nil }
      return Self.grow(size.points(of: style), by: grown)
    case .points(let points, _, _):
      return Self.grow(size.points(fromRegular: points), by: grown)
    }
  }

  private func baseFont(at size: AppFontSize, designPoints: Bool, dynamicType: DynamicTypeSize)
    -> Font
  {
    let grown = growth(at: size, dynamicType: dynamicType)
    switch base {
    case .style(let style, let design):
      if size == .system, !designPoints, let capped = Self.cappedHeadingPoints(style, dynamicType) {
        return Font.system(
          size: capped, weight: AppFontSize.defaultWeight(of: style), design: design ?? .default)
      }
      if (size == .regular || size == .system), !designPoints {
        return design.map { Font.system(style, design: $0, weight: nil) }
          ?? Self.systemFont(of: style)
      }
      return Font.system(
        size: Self.grow(size.points(of: style), by: grown),
        weight: AppFontSize.defaultWeight(of: style),
        design: design ?? .default)
    case .points(let points, let weight, let design):
      // The same overload the call wrote, with nothing it did not name.
      return Font.system(
        size: Self.grow(size.points(fromRegular: points), by: grown), weight: weight, design: design)
    }
  }

  /// The most a heading grows at the accessibility sizes: a title one word wide would be wider
  /// than any phone at the full factor (a 26 pt «Планирование» at AX5 is over 500 pt), and a
  /// word does not wrap. Headings stay legible and large, and the body text — which wraps — takes
  /// the whole factor.
  static let headingGrowthLimit: CGFloat = 1.35

  /// The Dynamic Type factor this font is drawn with at `size`.
  func growth(at size: AppFontSize, dynamicType: DynamicTypeSize) -> CGFloat {
    guard size == .system else { return 1 }
    let factor = AppFontSize.systemScale(for: dynamicType)
    switch base {
    case .style(let style, _):
      return [.largeTitle, .title, .title2].contains(style)
        ? min(factor, Self.headingGrowthLimit) : factor
    case .points(let points, _, _):
      return points >= 22 ? min(factor, Self.headingGrowthLimit) : factor
    }
  }

  /// The points a heading style is drawn at at an accessibility size, where the system's own
  /// style would grow past `headingGrowthLimit`; `nil` where the system's style is kept.
  static func cappedHeadingPoints(_ style: Font.TextStyle, _ dynamicType: DynamicTypeSize) -> CGFloat? {
    guard dynamicType.isAccessibilitySize else { return nil }
    let regular: CGFloat
    switch style {
    case .largeTitle: regular = 34
    case .title: regular = 28
    case .title2: regular = 22
    default: return nil
    }
    return (regular * headingGrowthLimit).rounded()
  }

  /// `points` grown by the Dynamic Type factor, to whole points; untouched when nothing grows.
  static func grow(_ points: CGFloat, by factor: CGFloat) -> CGFloat {
    factor == 1 ? points : (points * factor).rounded()
  }

  /// The system's font of a style, by the name SwiftUI gives it: `.caption` and not
  /// `.system(.caption)`, so «Обычный» is the very value the app used before.
  private static func systemFont(of style: Font.TextStyle) -> Font {
    switch style {
    case .largeTitle: .largeTitle
    case .title: .title
    case .title2: .title2
    case .title3: .title3
    case .headline: .headline
    case .subheadline: .subheadline
    case .body: .body
    case .callout: .callout
    case .footnote: .footnote
    case .caption: .caption
    case .caption2: .caption2
    @unknown default: .system(style)
    }
  }
}

extension AppFont {
  public static let largeTitle = style(.largeTitle)
  public static let title = style(.title)
  public static let title2 = style(.title2)
  public static let title3 = style(.title3)
  public static let headline = style(.headline)
  public static let subheadline = style(.subheadline)
  public static let body = style(.body)
  public static let callout = style(.callout)
  public static let footnote = style(.footnote)
  public static let caption = style(.caption)
  public static let caption2 = style(.caption2)

  private static func style(_ style: Font.TextStyle) -> AppFont {
    AppFont(base: .style(style, design: nil), steps: [])
  }

  /// A text style in a design of its own, as `Font.system(_:design:weight:)` writes it.
  public static func system(
    _ style: Font.TextStyle, design: Font.Design? = nil, weight: Font.Weight? = nil
  ) -> AppFont {
    let font = AppFont(base: .style(style, design: design), steps: [])
    return weight.map { font.weight($0) } ?? font
  }

  /// A size in points at «Обычный», grown with the text at the other sizes (`AppFontSize.scale`).
  public static func system(
    size: CGFloat, weight: Font.Weight? = nil, design: Font.Design? = nil
  ) -> AppFont {
    AppFont(base: .points(size, weight: weight, design: design), steps: [])
  }
}

extension AppFontSize {
  /// The point size of a text style at this size. «Обычный» is the size macOS draws the style at
  /// (`NSFont.preferredFont(forTextStyle:)`); the others grow with the body — 11, 13, 15, 17 pt —
  /// and never fall below 9 pt, the smallest a caption stays legible at.
  ///
  /// | Style       | Мелкий | Обычный | Крупный | Очень крупный |
  /// |-------------|--------|---------|---------|---------------|
  /// | largeTitle  | 22     | 26      | 30      | 34            |
  /// | title       | 19     | 22      | 25      | 28            |
  /// | title2      | 15     | 17      | 19      | 22            |
  /// | title3      | 13     | 15      | 17      | 19            |
  /// | headline    | 11     | 13      | 15      | 17            |
  /// | body        | 11     | 13      | 15      | 17            |
  /// | callout     | 10     | 12      | 14      | 16            |
  /// | subheadline | 10     | 11      | 13      | 15            |
  /// | footnote    | 9      | 10      | 12      | 14            |
  /// | caption     | 9      | 10      | 12      | 14            |
  /// | caption2    | 9      | 10      | 12      | 14            |
  public func points(of style: Font.TextStyle) -> CGFloat {
    let row = Self.table[style] ?? Self.table[.body] ?? [11, 13, 15, 17]
    return row[Self.allCases.firstIndex(of: self) ?? 1]
  }

  /// A size written in points for «Обычный», at this size: grown with the body, to whole points.
  ///
  /// `textScale` (`EnvironmentValues.appTextScale`) is the growth `system` follows with the
  /// device's Dynamic Type size; the fixed sizes ignore it.
  public func points(fromRegular points: CGFloat, textScale: CGFloat) -> CGFloat {
    self == .system ? AppFont.grow(points, by: textScale) : self.points(fromRegular: points)
  }

  public func points(fromRegular points: CGFloat) -> CGFloat {
    self == .regular || self == .system ? points : max(9, (points * scale).rounded())
  }

  /// The weight macOS draws a style in when nothing names one: the headline is bold, the second
  /// caption medium.
  static func defaultWeight(of style: Font.TextStyle) -> Font.Weight {
    switch style {
    case .headline: .bold
    case .caption2: .medium
    default: .regular
    }
  }

  private static let table: [Font.TextStyle: [CGFloat]] = [
    .largeTitle: [22, 26, 30, 34],
    .title: [19, 22, 25, 28],
    .title2: [15, 17, 19, 22],
    .title3: [13, 15, 17, 19],
    .headline: [11, 13, 15, 17],
    .body: [11, 13, 15, 17],
    .callout: [10, 12, 14, 16],
    .subheadline: [10, 11, 13, 15],
    .footnote: [9, 10, 12, 14],
    .caption: [9, 10, 12, 14],
    .caption2: [9, 10, 12, 14],
  ]
}

extension EnvironmentValues {
  /// The size of the text chosen in Settings → Appearance; «Обычный» where no window set one.
  @Entry public var appFontSize: AppFontSize = .regular
  /// The text styles below are drawn at the design's points at «Обычный» too
  /// (`AppFont.font(at:designPoints:)`): set by a screen of a phone or a tablet whose frame
  /// writes its type in the Mac's points.
  @Entry var appFontDesignPoints = false
  /// How much larger than at the default size the text is drawn when the size is «Как в системе»
  /// (`AppFontSize.systemScale`); 1 for every fixed size. Sizes written in points for «Обычный»
  /// (icons, minimum heights, thresholds of a layout) grow by it.
  @Entry public var appTextScale: CGFloat = 1
}

/// Sets `font` at the size of the text in the environment.
struct AppFontModifier: ViewModifier {
  @Environment(\.appFontSize) private var size
  @Environment(\.appFontDesignPoints) private var designPoints
  @Environment(\.dynamicTypeSize) private var dynamicType
  let font: AppFont

  func body(content: Content) -> some View {
    content.font(font.font(at: size, designPoints: designPoints, dynamicType: dynamicType))
  }
}

extension View {
  /// The font of the app at the size of the text chosen in Settings → Appearance. Use it
  /// instead of `.font(_:)`: a `Font` stays the size it was written at (`make check-fonts`).
  public func appFont(_ font: AppFont) -> some View {
    modifier(AppFontModifier(font: font))
  }
}
