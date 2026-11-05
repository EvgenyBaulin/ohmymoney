import AppCore
import SwiftUI

/// The main card of Overview on every platform: «Свободно … — хватает» with the days to the
/// end of the free sum's window, in the white calm card of the one style (`OverviewHeadlineCard`).
/// The coloured gradient card belongs to «Капитал» and «Итоги» only. Content, never glass.
struct OverviewHero: View {
  /// The main card stands first on every screen, wide or narrow.
  static func shows(forWidth width: CGFloat) -> Bool { true }

  /// The line under the figure, with «часть скрыта» after it when the free sum holds money of a
  /// hidden account.
  static func line(_ line: String?, partHidden: String?) -> String? {
    guard let partHidden else { return line }
    return line.map { "\($0) · \(partHidden)" } ?? partHidden
  }

  var body: some View { OverviewHeadlineCard() }
}

/// The hero card of the phone design: radius 28, 20 × 18 of margin, the caption in 14 pt medium,
/// the figure in 44 pt bold, one line of 13 pt under it, and the soft shadow of a raised card.
struct PhoneHeroCard: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.colorSchemeContrast) private var contrast
  let caption: String
  let figure: String
  var line: String?
  var figureIdentifier = "screen.hero.figure"

  static let cornerRadius: CGFloat = 28

  /// The caption begins with a capital, as the design writes it.
  static func sentenceCase(_ text: String) -> String {
    text.prefix(1).uppercased() + text.dropFirst()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(verbatim: Self.sentenceCase(caption))
        .appFont(.subheadline.weight(.medium))
        .cardInk(.caption)
      Text(verbatim: figure)
        .appFont(.largeTitle.bold().monospacedDigit())
        .minimumScaleFactor(0.6)
        .lineLimit(1)
        .accessibilityIdentifier(figureIdentifier)
      if let line {
        Text(verbatim: line)
          .appFont(.footnote.monospacedDigit())
          .cardInk(.line)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .foregroundStyle(theme.heroContent)
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 20)
    .padding(.vertical, 18)
    .background(
      LinearGradient(
        colors: [theme.heroStart, theme.heroEnd], startPoint: .topLeading,
        endPoint: .bottomTrailing),
      in: .rect(cornerRadius: Self.cornerRadius)
    )
    .cardShadow(.deep, radius: 12, y: 10)
    .overlay {
      if contrast == .increased {
        RoundedRectangle(cornerRadius: Self.cornerRadius).strokeBorder(.separator, lineWidth: 1)
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("screen.hero")
  }
}
