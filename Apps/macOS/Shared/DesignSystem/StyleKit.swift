import SwiftUI

/// The shared parts of the one style of the app (Figma «единый стиль»): every screen takes its
/// cards, buttons, switches, chips and row icons from here instead of drawing its own. All of
/// it is content or control chrome painted from the theme — never glass (`GlassSurfaces.swift`
/// owns that) — and nothing here holds a meaning in colour alone: a status always carries its
/// words, a selected chip and a selected tab differ in fill and weight too.

/// The numbers of the one style, as the design file draws them on the Mac (Overview master,
/// 1440 × 900): every screen lays its cards, buttons and gaps out by these, so a screen and its
/// frame agree to the point. The phone and the tablet keep their own where their frames differ.
enum StyleMetrics {
  /// The margins of the content of a window: 28 at the sides, 22 above, 24 below.
  static let pageSide: CGFloat = 28
  static let pageTop: CGFloat = 22
  static let pageBottom: CGFloat = 24
  /// The gap between the parts of a page stacked one above the other — the header, the main
  /// card, each row of tiles, the name of a group.
  static let stackGap: CGFloat = 10
  /// The gap between two tiles side by side.
  static let columnGap: CGFloat = 14
  /// The narrowest a tile is drawn: four of them fill 1,150 pt of content.
  static let tileMinWidth: CGFloat = 277

  /// A tile: 14 of margin, 6 between its lines, radius 12, a 1 pt outline.
  static let tilePadding: CGFloat = 14
  static let tileGap: CGFloat = 6
  static let cardRadius: CGFloat = 12
  static let cardBorder: CGFloat = 1

  /// The main card: 20 × 12 of margin, the stripe 4 × 56 rounded 2 and 16 from the words, 3
  /// between its three lines.
  static let mainCardHorizontal: CGFloat = 20
  static let mainCardVertical: CGFloat = 12
  static let mainCardGap: CGFloat = 16
  static let stripeWidth: CGFloat = 4
  static let stripeHeight: CGFloat = 56
  static let stripeRadius: CGFloat = 2
  static let mainCardLineGap: CGFloat = 3

  /// A status label: a 6 pt dot 5 from its words, 8 × 3 of margin, a capsule.
  static let statusDot: CGFloat = 6
  static let statusGap: CGFloat = 5
  static let statusHorizontal: CGFloat = 8
  static let statusVertical: CGFloat = 3

  /// A button of the header of a window: 16 × 9 of margin, radius 10, 8 between buttons.
  static let headerButtonHorizontal: CGFloat = 16
  static let headerButtonVertical: CGFloat = 9
  static let headerButtonRadius: CGFloat = 10
  static let headerButtonGap: CGFloat = 8

  /// A button inside a row of a card («Провести», «Распределить…»): 16 × 8, radius 8, outlined.
  static let rowButtonHorizontal: CGFloat = 16
  static let rowButtonVertical: CGFloat = 8
  static let rowButtonRadius: CGFloat = 8

  /// The name of a group of tiles and its chevron: 8 apart, the chevron 12 pt.
  static let groupNameGap: CGFloat = 8
  static let groupChevron: CGFloat = 12

  /// «Что сделать сейчас»: 16 at the sides, 14 above, 8 below, 4 between header and rows; a row
  /// 8 above and below, 12 between dot, words and button; the dot 8 pt.
  static let doNowHorizontal: CGFloat = 16
  static let doNowTop: CGFloat = 14
  static let doNowBottom: CGFloat = 8
  static let doNowGap: CGFloat = 4
  static let doNowRowVertical: CGFloat = 8
  static let doNowRowGap: CGFloat = 12
  static let doNowDot: CGFloat = 8

  /// A part of a sum («На счетах», «Обязательные платежи»): 160 × 62, radius 9, 8 of margin, 3
  /// between figure and words, 8 between parts, 6 above and below the row.
  static let partWidth: CGFloat = 160
  static let partHeight: CGFloat = 62
  static let partRadius: CGFloat = 9
  static let partPadding: CGFloat = 8
  static let partLineGap: CGFloat = 3
  static let partGap: CGFloat = 8
  static let partsVertical: CGFloat = 6
}

/// The type of the one style, as the design names it in points at «Обычный»; each grows with the
/// size of the text chosen in Settings like every other font (`AppFont`).
enum StyleType {
  /// «Обзор», «Операции»: 22 bold.
  static let screenTitle = AppFont.title.bold()
  /// The caption of the main card: 12 medium.
  static let mainCaption = AppFont.callout.weight(.medium)
  /// The figure of the main card and of a tile: 24 bold.
  static let mainFigure = AppFont.system(size: 24, weight: .bold).monospacedDigit()
  /// The line under the main figure: 13.
  static let mainLine = AppFont.body.monospacedDigit()
  /// A status label: 11.5 semibold.
  static let status = AppFont.system(size: 11.5, weight: .semibold)
  /// A button of the header: 13 medium.
  static let headerButton = AppFont.body.weight(.medium)
  /// A button in a row of a card: 11.
  static let rowButton = AppFont.subheadline
  /// The title of a tile: 15 semibold.
  static let tileTitle = AppFont.title3.weight(.semibold)
  /// A line of a tile: 12.
  static let tileRow = AppFont.callout
  /// The grey hint under a figure of a tile: 11.
  static let tileHint = AppFont.subheadline
  /// The name of a group of tiles and the title of «Что сделать сейчас»: 14 semibold.
  static let groupName = AppFont.system(size: 14, weight: .semibold)
  /// A row of «Что сделать сейчас»: 13 medium over 12.
  static let rowTitle = AppFont.body.weight(.medium)
  static let rowDetail = AppFont.callout
  /// The second figure of a card («41 600 ₽ на 30 дней»): 16 bold; a part's figure 16 semibold
  /// over its words in 10.
  static let cardSubtitle = AppFont.system(size: 16, weight: .bold).monospacedDigit()
  static let partFigure = AppFont.system(size: 16, weight: .semibold).monospacedDigit()
  static let partLabel = AppFont.footnote
}

/// What a status label says, apart from its colour.
enum StatusTone: Hashable {
  case good, attention, bad, neutral

  /// The symbol that goes with the words, so the tone is never colour alone.
  var symbol: String {
    switch self {
    case .good: "checkmark.circle.fill"
    case .attention: "exclamationmark.triangle.fill"
    case .bad: "xmark.circle.fill"
    case .neutral: "circle.fill"
    }
  }
}

/// The small rounded label of a status: «хватает», «просрочен», «превышен». A dot of the tone's
/// colour before the words, the words in the primary ink, on the tint of the tone — the words
/// always say what the colour says.
struct StatusLabel: View {
  @Environment(\.appTheme) private var theme
  let tone: StatusTone
  let text: String

  /// The colour of the dot.
  static func ink(_ tone: StatusTone, in theme: AppThemeColors) -> Color {
    switch tone {
    case .good: theme.statusPositive
    case .attention: theme.accentDefault
    case .bad: theme.statusNegative
    case .neutral: theme.contentSecondary
    }
  }

  /// The tint behind the words: a token of the theme, never the dot's colour faded by hand.
  static func tint(_ tone: StatusTone, in theme: AppThemeColors) -> Color {
    switch tone {
    case .good: theme.statusPositiveTint
    case .attention: theme.accentTint
    case .bad: theme.statusNegativeTint
    case .neutral: theme.contentSecondaryTint
    }
  }

  var body: some View {
    HStack(spacing: StyleMetrics.statusGap) {
      Circle()
        .fill(Self.ink(tone, in: theme))
        .frame(width: StyleMetrics.statusDot, height: StyleMetrics.statusDot)
        .accessibilityHidden(true)
      Text(verbatim: text)
        .appFont(StyleType.status)
        .foregroundStyle(theme.contentPrimary)
        .lineLimit(1)
    }
    .padding(.horizontal, StyleMetrics.statusHorizontal)
    .padding(.vertical, StyleMetrics.statusVertical)
    .background(Self.tint(tone, in: theme), in: Capsule())
    .fixedSize()
    .accessibilityElement(children: .combine)
  }
}

/// The white main card of a screen — calm, with a coloured stripe on the left and one line of
/// verdict. The coloured gradient card is only for «Капитал» and «Итоги» (`GradientCard`).
struct MainCard<Content: View>: View {
  @Environment(\.themeSurfaces) private var surfaces
  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.appFontSize) private var fontSize
  let stripe: Color
  @ViewBuilder let content: Content

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: ContentCard.cornerRadius)
    HStack(alignment: .top, spacing: StyleMetrics.mainCardGap) {
      RoundedRectangle(cornerRadius: StyleMetrics.stripeRadius)
        .fill(stripe)
        // The stripe grows with the text it stands beside.
        .frame(
          width: StyleMetrics.stripeWidth,
          height: fontSize.points(fromRegular: StyleMetrics.stripeHeight))
        .accessibilityHidden(true)
      content.frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.vertical, StyleMetrics.mainCardVertical)
    .padding(.horizontal, StyleMetrics.mainCardHorizontal)
    .background(surfaces.card, in: shape)
    .overlay {
      shape.strokeBorder(surfaces.cardBorder, lineWidth: StyleMetrics.cardBorder)
      if contrast == .increased { shape.strokeBorder(.separator, lineWidth: 1) }
    }
  }
}

/// The card with the theme's gradient: only «Капитал» and «Итоги» wear it. Its colours come
/// from the chosen theme, never from the screen.
struct GradientCard<Content: View>: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.colorSchemeContrast) private var contrast
  @ViewBuilder let content: Content

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: ContentCard.cornerRadius)
    content
      .foregroundStyle(theme.heroContent)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(16)
      .background(
        LinearGradient(
          colors: [theme.heroStart, theme.heroEnd], startPoint: .topLeading,
          endPoint: .bottomTrailing), in: shape
      )
      .overlay { if contrast == .increased { shape.strokeBorder(.separator, lineWidth: 1) } }
  }
}

/// The title of a screen, with its buttons at the right edge: the name of the screen, never the
/// name of its section.
struct ScreenTitleRow<Trailing: View>: View {
  let title: String
  @ViewBuilder let trailing: Trailing

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      Text(verbatim: title)
        .appFont(StyleType.screenTitle)
        .accessibilityAddTraits(.isHeader)
      Spacer(minLength: 8)
      HStack(spacing: StyleMetrics.headerButtonGap) { trailing }
    }
  }
}

/// The one main button of a screen: the accent fill, the text on it, 13 medium, 16 × 9, radius 10.
struct PrimaryActionButtonStyle: ButtonStyle {
  @Environment(\.appTheme) private var theme
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .appFont(StyleType.headerButton)
      .foregroundStyle(theme.contentOnAccent)
      .padding(.horizontal, StyleMetrics.headerButtonHorizontal)
      .padding(.vertical, StyleMetrics.headerButtonVertical)
      .background(theme.accentDefault, in: .rect(cornerRadius: StyleMetrics.headerButtonRadius))
      .contentShape(.rect(cornerRadius: StyleMetrics.headerButtonRadius))
      .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.4)
  }
}

/// Every other button of the header of a screen: the neutral fill, the same size as the main one.
struct QuietActionButtonStyle: ButtonStyle {
  @Environment(\.appTheme) private var theme
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .appFont(StyleType.headerButton)
      .foregroundStyle(theme.contentPrimary)
      .padding(.horizontal, StyleMetrics.headerButtonHorizontal)
      .padding(.vertical, StyleMetrics.headerButtonVertical)
      .background(theme.fillNeutral, in: .rect(cornerRadius: StyleMetrics.headerButtonRadius))
      .contentShape(.rect(cornerRadius: StyleMetrics.headerButtonRadius))
      .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
  }
}

/// A button inside a row of a card — «Провести», «Разобрать», «Распределить…»: the neutral fill
/// with an outline, 11 pt, 16 × 8, radius 8.
struct RowActionButtonStyle: ButtonStyle {
  @Environment(\.appTheme) private var theme
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    let shape = RoundedRectangle(cornerRadius: StyleMetrics.rowButtonRadius)
    configuration.label
      .appFont(StyleType.rowButton)
      .foregroundStyle(theme.contentPrimary)
      .padding(.horizontal, StyleMetrics.rowButtonHorizontal)
      .padding(.vertical, StyleMetrics.rowButtonVertical)
      .background(theme.fillNeutral, in: shape)
      .overlay { shape.strokeBorder(theme.borderOutline, lineWidth: StyleMetrics.cardBorder) }
      .contentShape(shape)
      .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
  }
}

extension ButtonStyle where Self == RowActionButtonStyle {
  static var rowAction: RowActionButtonStyle { RowActionButtonStyle() }
}

extension ButtonStyle where Self == PrimaryActionButtonStyle {
  static var primaryAction: PrimaryActionButtonStyle { PrimaryActionButtonStyle() }
}

extension ButtonStyle where Self == QuietActionButtonStyle {
  static var quietAction: QuietActionButtonStyle { QuietActionButtonStyle() }
}

/// Tabs and periods: a grey track with the selected segment white. On the Mac it is as wide as
/// its content, not the window.
struct SegmentedTabs<Value: Hashable>: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.themeSurfaces) private var surfaces
  let options: [(value: Value, title: String)]
  @Binding var selection: Value

  var body: some View {
    HStack(spacing: 2) {
      ForEach(options.indices, id: \.self) { index in
        let option = options[index]
        let selected = option.value == selection
        Button { selection = option.value } label: {
          Text(verbatim: option.title)
            .appFont(.callout.weight(selected ? .semibold : .regular))
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .frame(maxWidth: Self.fillsWidth ? .infinity : nil)
            .background(selected ? surfaces.card : .clear, in: .rect(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
      }
    }
    .padding(2)
    .background(theme.surfaceSegmented, in: .rect(cornerRadius: 10))
    .fixedSize(horizontal: !Self.fillsWidth, vertical: true)
  }

  /// A phone stretches the switch over the page; the Mac and the tablet keep it as wide as its
  /// words.
  static var fillsWidth: Bool {
    #if os(iOS)
      UIDevice.current.userInterfaceIdiom == .phone
    #else
      false
    #endif
  }
}

/// A filter: the chosen one is filled with the accent and bold, the others are grey.
struct FilterChip: View {
  @Environment(\.appTheme) private var theme
  let title: String
  let selected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Text(verbatim: title)
        .appFont(.callout.weight(selected ? .semibold : .regular))
        .foregroundStyle(selected ? theme.contentOnAccent : .primary)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(selected ? theme.accentDefault : theme.surfaceSegmented, in: Capsule())
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
}

/// The round pastel icon at the start of a row: the drawing in `tint`, the tint faded behind
/// it. An account passes its own colour.
struct RowBadge: View {
  let symbol: String
  var tint: Color = .accentColor
  var size: CGFloat = 32

  var body: some View {
    Image(systemName: symbol)
      .font(.system(size: size * 0.45, weight: .semibold))  // font-fixed: scales with the badge
      .foregroundStyle(tint)
      .frame(width: size, height: size)
      .background(tint.opacity(0.16), in: Circle())
      .accessibilityHidden(true)
  }
}
