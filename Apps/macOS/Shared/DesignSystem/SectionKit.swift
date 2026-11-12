import SwiftUI

/// The numbers Calendar, Capital and Purchases share, as their frames draw them on the Mac
/// (1440 × 900), the phone (440 wide) and the tablet (1366 × 1024): the margins of the page, the
/// header, the cards of 15 inside their edge with a title of 14 and rows of 32 (34 on touch), the
/// segments with a track of 3. What one of the three screens has of its own is in its own metrics.
enum SectionMetrics {
  /// The margins at the sides: 28 on the Mac (the content starts 28 from the sidebar), 32 on a
  /// tablet (282 from the 250 of its sidebar), the phone's screen margin (20) on a phone.
  static func side(_ idiom: LayoutIdiom) -> CGFloat {
    switch idiom {
    case .mac: StyleMetrics.pageSide
    case .pad: 32
    case .phone: PhoneMetrics.screenMargin
    }
  }

  /// Above the header: 22 on the Mac; a phone and a tablet start right under their navigation.
  static func top(_ idiom: LayoutIdiom) -> CGFloat { idiom == .mac ? StyleMetrics.pageTop : 12 }
  static func bottom(_ idiom: LayoutIdiom) -> CGFloat {
    idiom == .mac ? StyleMetrics.pageBottom : 16
  }

  /// Between the header (34 tall with its button) and the first card or switch: 18.
  static let headerToContent: CGFloat = 18
  /// Between the title of a screen and its subtitle («Октябрь 2026»): 14.
  static let subtitleGap: CGFloat = 14
  /// Between two cards one above the other, and between a switch and the card under it: 14.
  static let stackGap: CGFloat = 14
  /// Between two columns: 568 + 16 + 568 on the Mac, 20 on a tablet.
  static func columnGap(_ idiom: LayoutIdiom) -> CGFloat { idiom == .pad ? 20 : 16 }

  /// A card: 14 of margin inside an edge of 1 (its content 15 from the outside), 10 between its
  /// title and its rows, radius 12 on the Mac and 22 on touch, as every card of those designs.
  static let cardPadding: CGFloat = 14
  static let cardEdge: CGFloat = 1
  static let cardGap: CGFloat = 10
  static var cardRadius: CGFloat { ContentCard.cornerRadius }
  /// The words of a card's title and the grey caption at its right: 8 apart.
  static let headerGap: CGFloat = 8

  /// A row: 32 tall on the Mac, its round badge 32 with a glyph of 16; 34 and 17 on touch. 10
  /// between the badge and the words, 1 between the two lines, 10 between rows.
  static func rowHeight(_ idiom: LayoutIdiom) -> CGFloat { idiom == .mac ? 32 : 34 }
  static func badge(_ idiom: LayoutIdiom) -> CGFloat { idiom == .mac ? 32 : 34 }
  static func badgeGlyph(_ idiom: LayoutIdiom) -> CGFloat { idiom == .mac ? 16 : 17 }
  static let rowGap: CGFloat = 10
  static let rowLineGap: CGFloat = 1

  /// The Mac's switch: a track of 3 around segments of 12 × 5, 2 apart, the track rounded 10 and a
  /// segment 8.
  static let trackInset: CGFloat = 3
  static let segmentHorizontal: CGFloat = 12
  static let segmentVertical: CGFloat = 5
  static let segmentGap: CGFloat = 2
  static let trackRadius: CGFloat = 10
  static let segmentRadius: CGFloat = 8
  /// The chips of a phone and a tablet in place of the switch: 10 × 5, 6 apart, a capsule.
  static let chipHorizontal: CGFloat = 10
  static let chipVertical: CGFloat = 5
  static let chipGap: CGFloat = 6
}

/// The type of those screens in points at «Обычный»; each grows with the size of the text chosen
/// in Settings (`AppFont`).
enum SectionType {
  /// The name of the screen: 22 bold on the Mac and a tablet, 34 bold on a phone.
  static func title(_ idiom: LayoutIdiom) -> AppFont {
    .system(size: idiom == .phone ? 34 : 22, weight: .bold)
  }
  /// The subtitle under it («Октябрь 2026»): 14 medium; 12 on a phone.
  static func subtitle(_ idiom: LayoutIdiom) -> AppFont {
    idiom == .phone ? .system(size: 12) : .system(size: 14, weight: .medium)
  }
  /// The title of a card: 14 semibold; the caption at its right 12.
  static let cardTitle = AppFont.system(size: 14, weight: .semibold)
  static let cardCaption = AppFont.system(size: 12).monospacedDigit()
  /// A row: its name 13 medium over 11, its figure 13 semibold.
  static let rowTitle = AppFont.system(size: 13, weight: .medium)
  static let rowDetail = AppFont.system(size: 11).monospacedDigit()
  static let rowFigure = AppFont.system(size: 13, weight: .semibold).monospacedDigit()
  /// A segment of the Mac's switch: 12, the chosen one semibold. A chip: 11, the chosen one
  /// semibold, the others medium.
  static func segment(selected: Bool) -> AppFont {
    .system(size: 12, weight: selected ? .semibold : .regular)
  }
  static func chip(selected: Bool) -> AppFont {
    .system(size: 11, weight: selected ? .semibold : .medium)
  }
}

/// A card of those screens: the theme's card, its 1 pt edge, 14 of margin inside it, radius 12 on
/// the Mac and 22 on touch. Content, never glass. «Увеличить контраст» adds the separator edge.
struct SectionCard: ViewModifier {
  @Environment(\.themeSurfaces) private var surfaces
  @Environment(\.colorSchemeContrast) private var contrast

  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: SectionMetrics.cardRadius)
    content
      .frame(maxWidth: .infinity, alignment: .topLeading)
      .padding(SectionMetrics.cardPadding + SectionMetrics.cardEdge)
      .background(surfaces.card, in: shape)
      .overlay {
        shape.strokeBorder(surfaces.cardBorder, lineWidth: SectionMetrics.cardEdge)
        if contrast == .increased { shape.strokeBorder(.separator, lineWidth: 1) }
      }
  }
}

extension View {
  func sectionCard() -> some View { modifier(SectionCard()) }
}

/// The title of a card and its grey caption at the right («доли», «12 месяцев», «3 дня»).
struct SectionCardHeader: View {
  let title: String
  var caption: String?

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: SectionMetrics.headerGap) {
      Text(verbatim: title)
        .appFont(SectionType.cardTitle)
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityAddTraits(.isHeader)
      if let caption {
        Text(verbatim: caption)
          .appFont(SectionType.cardCaption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    }
  }
}

/// The round pastel badge at the start of a row: the glyph in `tint`, the tint's own faded token
/// behind it.
struct SectionBadge: View {
  @Environment(\.layoutIdiom) private var idiom
  let symbol: String
  let tint: Color
  let fill: Color

  var body: some View {
    let design = LayoutIdiom.resolved(idiom)
    let glyph = SectionMetrics.badgeGlyph(design) * 0.85
    Image(systemName: symbol)
      .font(.system(size: glyph, weight: .medium))  // font-fixed: the glyph of a fixed badge
      .foregroundStyle(tint)
      .frame(width: SectionMetrics.badge(design), height: SectionMetrics.badge(design))
      .background(fill, in: Circle())
      .accessibilityHidden(true)
  }
}

/// A row of a card: the badge, the name over its detail, and the figure at the right. The words
/// carry the meaning; the badge only repeats it.
struct SectionRow<Trailing: View>: View {
  @Environment(\.layoutIdiom) private var idiom
  let badge: SectionBadge?
  let title: String
  var detail: String?
  var figure: String?
  var figureInk: Color?
  @ViewBuilder var trailing: Trailing

  var body: some View {
    let design = LayoutIdiom.resolved(idiom)
    HStack(spacing: SectionMetrics.rowGap) {
      if let badge { badge }
      VStack(alignment: .leading, spacing: SectionMetrics.rowLineGap) {
        Text(verbatim: title)
          .appFont(SectionType.rowTitle)
          .lineLimit(1)
        if let detail {
          Text(verbatim: detail)
            .appFont(SectionType.rowDetail)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      trailing
      if let figure {
        Text(verbatim: figure)
          .appFont(SectionType.rowFigure)
          .foregroundStyle(figureInk ?? .primary)
          .lineLimit(1)
          .fixedSize()
      }
    }
    .frame(minHeight: SectionMetrics.rowHeight(design))
    .contentShape(.rect)
    .accessibilityElement(children: .combine)
  }
}

extension SectionRow where Trailing == EmptyView {
  init(
    badge: SectionBadge?, title: String, detail: String? = nil, figure: String? = nil,
    figureInk: Color? = nil
  ) {
    self.init(
      badge: badge, title: title, detail: detail, figure: figure, figureInk: figureInk,
      trailing: { EmptyView() })
  }
}

/// The switch of those screens: on the Mac a grey track of 3 with the chosen segment white
/// («Месяц | Неделя», «12 мес. | Всё», the pages of «Покупки»); on a phone and a tablet the chips
/// their frames draw instead — the chosen one in the accent. The chosen one is told by its fill
/// and its weight, never the colour alone.
struct SectionSegments<Value: Hashable>: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.themeSurfaces) private var surfaces
  @Environment(\.layoutIdiom) private var idiom
  let options: [(value: Value, title: String)]
  @Binding var selection: Value
  /// Chips on touch, as the frames of Capital and Purchases draw them; `false` keeps the track.
  var chipsOnTouch = true
  /// The segments share the width of their column, as the tablet's «Месяц | Неделя»; otherwise
  /// the track is as wide as its words.
  var fillsWidth = false
  var identifier: (Value) -> String? = { _ in nil }

  var body: some View {
    if LayoutIdiom.resolved(idiom) != .mac, chipsOnTouch {
      chips
    } else {
      track
    }
  }

  private var track: some View {
    HStack(spacing: SectionMetrics.segmentGap) {
      ForEach(options.indices, id: \.self) { index in
        let option = options[index]
        let selected = option.value == selection
        Button {
          selection = option.value
        } label: {
          Text(verbatim: option.title)
            .appFont(SectionType.segment(selected: selected))
            .foregroundStyle(selected ? theme.contentPrimary : theme.contentSecondary)
            .lineLimit(1)
            .padding(.horizontal, SectionMetrics.segmentHorizontal)
            .padding(.vertical, SectionMetrics.segmentVertical)
            .frame(maxWidth: fillsWidth ? .infinity : nil)
            .background(
              selected ? surfaces.card : .clear,
              in: .rect(cornerRadius: SectionMetrics.segmentRadius)
            )
            .contentShape(.rect(cornerRadius: SectionMetrics.segmentRadius))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(identifier(option.value) ?? "")
      }
    }
    .padding(SectionMetrics.trackInset)
    .background(theme.surfaceSegmented, in: .rect(cornerRadius: SectionMetrics.trackRadius))
    .fixedSize(horizontal: !fillsWidth, vertical: true)
  }

  private var chips: some View {
    HStack(spacing: SectionMetrics.chipGap) {
      ForEach(options.indices, id: \.self) { index in
        let option = options[index]
        let selected = option.value == selection
        Button {
          selection = option.value
        } label: {
          Text(verbatim: option.title)
            .appFont(SectionType.chip(selected: selected))
            .foregroundStyle(selected ? theme.contentOnAccent : theme.contentSecondary)
            .lineLimit(1)
            .padding(.horizontal, SectionMetrics.chipHorizontal)
            .padding(.vertical, SectionMetrics.chipVertical)
            .background(selected ? theme.accentDefault : theme.fillNeutral, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(identifier(option.value) ?? "")
      }
    }
    .fixedSize()
  }
}

/// The header of Calendar, Capital and Purchases: the name of the screen, 22 bold, an optional
/// subtitle under it 14 below, and at the right the screen's one orange button. A phone writes
/// the large title of its frame and leaves the button to its own entry.
struct SectionHeader: View {
  @Dependency(\.environment) private var environment
  @Environment(\.layoutIdiom) private var idiom
  let title: String
  var subtitle: String?
  var identifier = "screen.title"
  /// The words and the action of the orange button; `nil` — none. It is not drawn while the
  /// app is «Только просмотр».
  var primary: (title: String, identifier: String, action: () -> Void)?
  var trailing: AnyView?

  var body: some View {
    let design = LayoutIdiom.resolved(idiom)
    let phone = design == .phone
    VStack(alignment: .leading, spacing: phone ? 2 : SectionMetrics.subtitleGap) {
      HStack(alignment: .center, spacing: 12) {
        Text(verbatim: title)
          .appFont(SectionType.title(design))
          .lineLimit(1)
          .accessibilityAddTraits(.isHeader)
          .accessibilityIdentifier(identifier)
        Spacer(minLength: 8)
        HStack(spacing: StyleMetrics.headerButtonGap) {
          if let trailing { trailing }
          if !phone, let primary, !environment.shield.isReadOnly {
            Button(primary.title, action: primary.action)
              .buttonStyle(.primaryAction)
              .fixedSize()
              .accessibilityIdentifier(primary.identifier)
          }
        }
      }
      // The row keeps the height of the header button even when there is none.
      .frame(minHeight: phone ? nil : 34)
      if let subtitle {
        Text(verbatim: subtitle)
          .appFont(SectionType.subtitle(design))
          .foregroundStyle(.secondary)
          .accessibilityIdentifier(identifier + ".subtitle")
      }
    }
  }
}

/// The page of those screens: the margins of its design around a scrolling column.
struct SectionPage<Content: View>: View {
  @Environment(\.layoutIdiom) private var idiom
  @Environment(\.themeSurfaces) private var surfaces
  @ViewBuilder let content: Content

  var body: some View {
    let design = LayoutIdiom.resolved(idiom)
    ScrollView {
      content
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.horizontal, SectionMetrics.side(design))
        .padding(.top, SectionMetrics.top(design))
        .padding(.bottom, SectionMetrics.bottom(design))
    }
    .background(surfaces.background)
  }
}
