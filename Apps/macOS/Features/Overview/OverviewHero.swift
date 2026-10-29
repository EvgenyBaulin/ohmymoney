import AppCore
import SwiftUI

/// «Можно тратить сейчас» on the theme's hero gradient, over the groups of tiles on a phone or a
/// tablet: the one figure of the screen, the free sum with its sentence about the day. The
/// «Свободные средства» tile keeps the terms it is made of. Content, never glass; the figures
/// are the core's, only put into words (`PlanningHero`).
struct OverviewHero: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute

  /// The hero stands first on every screen of the phone and the tablet, as the design draws it;
  /// on the Mac the free-sum tile carries the figure.
  static func shows(forWidth width: CGFloat) -> Bool {
    #if os(iOS)
      true
    #else
      false
    #endif
  }

  var body: some View {
    if let snapshot = compute.snapshot,
      let content = PlanningHero.make(free: snapshot.planning.freeMoney, environment: environment)
    {
      PhoneHeroCard(
        caption: content.caption, figure: content.figure,
        line: content.lines.first, figureIdentifier: "overview.hero.figure")
    }
  }
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
