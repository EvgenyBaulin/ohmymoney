import SwiftUI

/// The shared parts of the one style of the app (Figma «единый стиль»): every screen takes its
/// cards, buttons, switches, chips and row icons from here instead of drawing its own. All of
/// it is content or control chrome painted from the theme — never glass (`GlassSurfaces.swift`
/// owns that) — and nothing here holds a meaning in colour alone: a status always carries its
/// words, a selected chip and a selected tab differ in fill and weight too.

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

/// The small rounded label of a status: «хватает», «просрочен», «превышен».
struct StatusLabel: View {
  @Environment(\.appTheme) private var theme
  let tone: StatusTone
  let text: String

  private var ink: Color {
    switch tone {
    case .good: theme.statusPositive
    case .attention: theme.contentWarning
    case .bad: theme.statusNegative
    case .neutral: .secondary
    }
  }

  var body: some View {
    Label {
      Text(verbatim: text)
    } icon: {
      Image(systemName: tone.symbol).imageScale(.small)
    }
    .labelStyle(.titleAndIcon)
    .appFont(.caption.weight(.semibold))
    .foregroundStyle(ink)
    .padding(.horizontal, 8)
    .padding(.vertical, 3)
    .background(ink.opacity(0.14), in: Capsule())
    .accessibilityElement(children: .combine)
  }
}

/// The white main card of a screen — calm, with a coloured stripe on the left and one line of
/// verdict. The coloured gradient card is only for «Капитал» and «Итоги» (`GradientCard`).
struct MainCard<Content: View>: View {
  @Environment(\.themeSurfaces) private var surfaces
  @Environment(\.colorSchemeContrast) private var contrast
  let stripe: Color
  @ViewBuilder let content: Content

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: ContentCard.cornerRadius)
    HStack(alignment: .top, spacing: 14) {
      RoundedRectangle(cornerRadius: 2).fill(stripe).frame(width: 4)
      content.frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.vertical, 14)
    .padding(.horizontal, 16)
    .background(surfaces.card, in: shape)
    .overlay {
      shape.strokeBorder(surfaces.cardBorder, lineWidth: 0.5)
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
        .appFont(.largeTitle.bold())
        .accessibilityAddTraits(.isHeader)
      Spacer(minLength: 8)
      trailing
    }
  }
}

/// The one main button of a screen: the accent fill, the text on it.
struct PrimaryActionButtonStyle: ButtonStyle {
  @Environment(\.appTheme) private var theme
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .appFont(.callout.weight(.semibold))
      .foregroundStyle(theme.contentOnAccent)
      .padding(.horizontal, 14)
      .padding(.vertical, 7)
      .background(theme.accentDefault, in: .rect(cornerRadius: 10))
      .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.4)
  }
}

/// Every other button of a screen: grey, quiet.
struct QuietActionButtonStyle: ButtonStyle {
  @Environment(\.appTheme) private var theme
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .appFont(.callout)
      .foregroundStyle(.primary)
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
      .background(theme.surfaceSegmented, in: .rect(cornerRadius: 10))
      .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
  }
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
