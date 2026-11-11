import AppCore
import SwiftUI

/// The numbers of «Покупки» as its frames draw them: the Mac's «Хочу купить» (88:71027, 1440 ×
/// 900) and the phone's (61:77801, 440). The page and the switch are the three screens'
/// (`SectionMetrics`); the list of rows is Purchases' own.
enum PurchasesMetrics {
  /// The Mac's frame sets the header 24 under the top of the window, 2 more than the others.
  static let macTopExtra: CGFloat = 2
  /// Between the header, the tabs, the button of a phone and the list: 14 on the Mac and a
  /// tablet, 12 on a phone.
  static func stackGap(_ idiom: LayoutIdiom) -> CGFloat { idiom == .phone ? 12 : 14 }
  /// A row of the list: 16 at the sides, 11 above and below (12 on a phone), 12 between its
  /// parts; the badge 32, the words 2 apart; 1 pt of hairline between two rows.
  static func rowHorizontal(_ idiom: LayoutIdiom) -> CGFloat { 16 }
  static func rowVertical(_ idiom: LayoutIdiom) -> CGFloat { idiom == .phone ? 12 : 11 }
  static let rowGap: CGFloat = 12
  static let badge: CGFloat = 32
  static let lineGap: CGFloat = 2
  static let divider: CGFloat = 1
  /// The chip of the verdict: 8 × 2, a capsule.
  static let chipHorizontal: CGFloat = 8
  static let chipVertical: CGFloat = 2
  /// The quiet button of a phone under the tabs: 16 × 9, radius 8.
  static let phoneButtonHorizontal: CGFloat = 16
  static let phoneButtonVertical: CGFloat = 9
  static let phoneButtonRadius: CGFloat = 8

  // The cards of the other four pages (frames 61:76722, 61:77071, 61:77448, 61:81207).
  /// A card of facts: 16 at the sides, 14 above and below inside its 1 pt edge, 8 between its
  /// parts (4 in a card of one figure), radius 12.
  static let cardHorizontal: CGFloat = 16
  static let cardVertical: CGFloat = 14
  static let cardGap: CGFloat = 8
  static let totalGap: CGFloat = 4
  /// A line of a card: a 14 glyph, 6 of air, the words.
  static let detailGlyph: CGFloat = 14
  static let detailGap: CGFloat = 6
  /// The buttons under a card's lines: 8 apart, each 16 × 9, radius 8.
  static let actionGap: CGFloat = 8
  /// The field «Что купить»: its name 6 above it, the field 12 × 9, radius 8.
  static let fieldLabelGap: CGFloat = 6
  static let fieldHorizontal: CGFloat = 12
  static let fieldVertical: CGFloat = 9
  static let fieldRadius: CGFloat = 8
  /// The mark of a line of the shopping list: 20, 12 after the badge.
  static let markSize: CGFloat = 20
  /// Between the two columns of a card page: 16 on the Mac, as the other screens.
  static func columnGap(_ idiom: LayoutIdiom) -> CGFloat { SectionMetrics.columnGap(idiom) }
}

/// The type of the list: the Mac's 13 medium name over 11, its figure 13 semibold, the chip 11
/// semibold; a phone's 15 over 12, its figure 15.
enum PurchasesType {
  static func title(_ idiom: LayoutIdiom) -> AppFont {
    .system(size: idiom == .phone ? 15 : 13, weight: .medium)
  }
  static func detail(_ idiom: LayoutIdiom) -> AppFont {
    .system(size: idiom == .phone ? 12 : 11)
  }
  static func figure(_ idiom: LayoutIdiom) -> AppFont {
    .system(size: idiom == .phone ? 15 : 13, weight: .semibold).monospacedDigit()
  }
  static let chip = AppFont.system(size: 11, weight: .semibold)
  static let phoneButton = AppFont.system(size: 15, weight: .medium)
  /// The card of facts: the name 14 semibold, its figure 15 semibold, the lines 12; a total's
  /// figure 22 bold; the name of a group of cards 13 semibold; the buttons 13 medium.
  static let cardTitle = AppFont.system(size: 14, weight: .semibold)
  static let cardFigure = AppFont.system(size: 15, weight: .semibold).monospacedDigit()
  static let cardLine = AppFont.system(size: 12).monospacedDigit()
  static let totalFigure = AppFont.system(size: 22, weight: .bold).monospacedDigit()
  static let groupTitle = AppFont.system(size: 13, weight: .semibold)
  static let action = AppFont.system(size: 13, weight: .medium)
  static let fieldLabel = AppFont.system(size: 12)
  static let field = AppFont.system(size: 13)
}

/// What the chip of a wish says: «можно» — the money is there now, «ждать» — it will be after
/// some months at the pace of «can save», «нет срока» — no pace or no rate to tell a day by, and
/// «пора» when the prices noted say it is time to buy. Always words; the colour only repeats them.
enum PurchasesWishVerdict: String, CaseIterable {
  case now, wait, none, time

  var titleKey: String { "purchases.wish.chip.\(rawValue)" }

  var tone: StatusTone {
    switch self {
    case .now, .time: .good
    case .wait: .attention
    case .none: .neutral
    }
  }

  /// `nil` for a wish without a price: nothing to tell.
  static func of(_ line: WishLine) -> PurchasesWishVerdict? {
    if line.tracking.timeToBuy != nil { return .time }
    if line.rateMissing { return PurchasesWishVerdict.none }
    switch line.afford.outcome {
    case .noPrice: return nil
    case .affordableNow: return .now
    case .months: return .wait
    case .noSavingPace: return PurchasesWishVerdict.none
    }
  }
}

/// The one card of a list: its rows one under another with a hairline between them, as the
/// frame draws «Хочу купить».
struct PurchasesListCard<Row: View>: View {
  @Environment(\.themeSurfaces) private var surfaces
  @Environment(\.appTheme) private var theme
  @Environment(\.colorSchemeContrast) private var contrast
  let count: Int
  @ViewBuilder let row: (Int) -> Row

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: SectionMetrics.cardRadius)
    VStack(spacing: 0) {
      ForEach(0..<count, id: \.self) { index in
        if index > 0 {
          Rectangle()
            .fill(theme.borderHairline)
            .frame(height: PurchasesMetrics.divider)
            .accessibilityHidden(true)
        }
        row(index)
      }
    }
    .padding(SectionMetrics.cardEdge)
    .background(surfaces.card, in: shape)
    .overlay {
      shape.strokeBorder(surfaces.cardBorder, lineWidth: SectionMetrics.cardEdge)
      if contrast == .increased { shape.strokeBorder(.separator, lineWidth: 1) }
    }
    .accessibilityElement(children: .contain)
  }
}

/// A row of a list: the badge (not on a phone, whose frame has none), the name over its detail,
/// the chip of the verdict and the figure.
struct PurchasesRow: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.layoutIdiom) private var idiom
  /// `nil` — a row without a badge («По месяцам»: 38 high).
  let symbol: String?
  let title: String
  var detail: String?
  var chip: (title: String, tone: StatusTone)?
  var figure: String?

  var body: some View {
    let design = LayoutIdiom.resolved(idiom)
    HStack(spacing: PurchasesMetrics.rowGap) {
      if design != .phone, let symbol {
        Image(systemName: symbol)
          .font(.system(size: 14, weight: .medium))  // font-fixed: the glyph of a fixed badge
          .foregroundStyle(theme.accentDefault)
          .frame(width: PurchasesMetrics.badge, height: PurchasesMetrics.badge)
          .background(theme.accentTint, in: Circle())
          .accessibilityHidden(true)
      }
      VStack(alignment: .leading, spacing: PurchasesMetrics.lineGap) {
        Text(verbatim: title)
          .appFont(PurchasesType.title(design))
          .lineLimit(1)
        if let detail {
          Text(verbatim: detail)
            .appFont(PurchasesType.detail(design))
            .foregroundStyle(.secondary)
            .lineLimit(design == .phone ? 2 : 1)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      if let chip {
        Text(verbatim: chip.title)
          .appFont(PurchasesType.chip)
          .foregroundStyle(Self.ink(chip.tone, theme))
          .lineLimit(1)
          .padding(.horizontal, PurchasesMetrics.chipHorizontal)
          .padding(.vertical, PurchasesMetrics.chipVertical)
          .background(Self.fill(chip.tone, theme), in: Capsule())
          .fixedSize()
      }
      if let figure {
        Text(verbatim: figure)
          .appFont(PurchasesType.figure(design))
          .lineLimit(1)
          .fixedSize()
      }
    }
    .padding(.horizontal, PurchasesMetrics.rowHorizontal(design))
    .padding(.vertical, PurchasesMetrics.rowVertical(design))
    .contentShape(.rect)
    .accessibilityElement(children: .combine)
  }

  /// The words of a chip: green, the warning's brown, grey.
  static func ink(_ tone: StatusTone, _ theme: AppThemeColors) -> Color {
    switch tone {
    case .good: theme.statusPositive
    case .attention: theme.contentWarning
    case .bad: theme.statusNegative
    case .neutral: theme.contentSecondary
    }
  }

  static func fill(_ tone: StatusTone, _ theme: AppThemeColors) -> Color {
    switch tone {
    case .good: theme.statusPositiveTint
    case .attention: theme.accentTint
    case .bad: theme.statusNegativeTint
    case .neutral: theme.fillNeutral
    }
  }
}

/// The quiet button of a phone under the tabs («Добавить желание»): the neutral fill, 15 medium,
/// 16 × 9, radius 8.
struct PhoneQuietButtonStyle: ButtonStyle {
  @Environment(\.appTheme) private var theme
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .appFont(PurchasesType.phoneButton)
      .foregroundStyle(theme.contentPrimary)
      .padding(.horizontal, PurchasesMetrics.phoneButtonHorizontal)
      .padding(.vertical, PurchasesMetrics.phoneButtonVertical)
      .background(
        theme.fillNeutral, in: .rect(cornerRadius: PurchasesMetrics.phoneButtonRadius)
      )
      .contentShape(.rect(cornerRadius: PurchasesMetrics.phoneButtonRadius))
      .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
  }
}

/// A card of facts of the other pages: 16 at the sides and 14 above and below inside the 1 pt
/// edge, its parts 8 apart (or `gap`), radius 12; content, never glass.
struct PurchasesFactCard<Content: View>: View {
  @Environment(\.themeSurfaces) private var surfaces
  @Environment(\.colorSchemeContrast) private var contrast
  var gap: CGFloat = PurchasesMetrics.cardGap
  @ViewBuilder let content: Content

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: SectionMetrics.cardRadius)
    VStack(alignment: .leading, spacing: gap) { content }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, PurchasesMetrics.cardHorizontal + SectionMetrics.cardEdge)
      .padding(.vertical, PurchasesMetrics.cardVertical + SectionMetrics.cardEdge)
      .background(surfaces.card, in: shape)
      .overlay {
        shape.strokeBorder(surfaces.cardBorder, lineWidth: SectionMetrics.cardEdge)
        if contrast == .increased { shape.strokeBorder(.separator, lineWidth: 1) }
      }
  }
}

/// The name of a card at the left and its figure at the right: 14 semibold over an optional
/// grey 12 line, the figure 15 semibold.
struct PurchasesCardTitle: View {
  let title: String
  var detail: String?
  var figure: String?

  var body: some View {
    HStack(spacing: PurchasesMetrics.cardGap) {
      VStack(alignment: .leading, spacing: 2) {
        Text(verbatim: title).appFont(PurchasesType.cardTitle).lineLimit(2)
        if let detail {
          Text(verbatim: detail).appFont(PurchasesType.cardLine).foregroundStyle(.secondary)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      if let figure {
        Text(verbatim: figure).appFont(PurchasesType.cardFigure).lineLimit(1).fixedSize()
      }
    }
  }
}

/// A line of a card: a 14 glyph, 6 of air and the words in 12 (a warning in its own ink).
struct PurchasesDetailLine: View {
  @Environment(\.appTheme) private var theme
  let symbol: String
  let text: String
  var ink: Color?
  var glyphInk: Color?

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: PurchasesMetrics.detailGap) {
      Image(systemName: symbol)
        .font(.system(size: PurchasesMetrics.detailGlyph - 2))  // font-fixed: a 14 glyph
        .foregroundStyle(glyphInk ?? ink ?? theme.contentSecondary)
        .frame(width: PurchasesMetrics.detailGlyph)
        .accessibilityHidden(true)
      Text(verbatim: text)
        .appFont(PurchasesType.cardLine)
        .foregroundStyle(ink ?? theme.contentPrimary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .accessibilityElement(children: .combine)
  }
}

/// The buttons of a card, 8 apart.
struct PurchasesActionRow<Content: View>: View {
  @ViewBuilder let content: Content

  var body: some View {
    HStack(spacing: PurchasesMetrics.actionGap) { content }
      .buttonStyle(PurchasesActionButtonStyle())
  }
}

/// A button of a card: the neutral fill, 13 medium, 16 × 9, radius 8; «Удалить» in the red of
/// a loss (its word says it too).
struct PurchasesActionButtonStyle: ButtonStyle {
  @Environment(\.appTheme) private var theme
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .appFont(PurchasesType.action)
      .foregroundStyle(
        configuration.role == .destructive ? theme.statusNegative : theme.contentPrimary
      )
      .padding(.horizontal, PurchasesMetrics.phoneButtonHorizontal)
      .padding(.vertical, PurchasesMetrics.phoneButtonVertical)
      .background(
        theme.fillNeutral, in: .rect(cornerRadius: PurchasesMetrics.phoneButtonRadius)
      )
      .contentShape(.rect(cornerRadius: PurchasesMetrics.phoneButtonRadius))
      .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
  }
}

/// A page of cards in two columns on the Mac and a tablet — the first card at the left, the next
/// at the right, and so on, as the frames lay them —, one column in the order of the list on a
/// phone. `head` stands above the left column, `tail` under the right one.
struct PurchasesColumns<Item: Identifiable, Head: View, Tail: View, Card: View>: View {
  @Environment(\.layoutIdiom) private var idiom
  let items: [Item]
  @ViewBuilder let head: Head
  @ViewBuilder let tail: Tail
  @ViewBuilder let card: (Item) -> Card

  var body: some View {
    let design = LayoutIdiom.resolved(idiom)
    if design == .phone {
      VStack(spacing: SectionMetrics.stackGap) {
        head
        ForEach(items) { card($0) }
        tail
      }
    } else {
      let indexed = Array(items.enumerated())
      HStack(alignment: .top, spacing: PurchasesMetrics.columnGap(design)) {
        VStack(spacing: SectionMetrics.stackGap) {
          head
          ForEach(indexed.filter { $0.offset % 2 == 0 }, id: \.element.id) { card($0.element) }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        VStack(spacing: SectionMetrics.stackGap) {
          ForEach(indexed.filter { $0.offset % 2 == 1 }, id: \.element.id) { card($0.element) }
          tail
        }
        .frame(maxWidth: .infinity, alignment: .top)
      }
    }
  }
}

/// Two columns of cards written out by hand («Скидки»): side by side on the Mac and a tablet,
/// one under the other on a phone.
struct PurchasesTwoColumns<Left: View, Right: View>: View {
  @Environment(\.layoutIdiom) private var idiom
  @ViewBuilder let left: Left
  @ViewBuilder let right: Right

  var body: some View {
    let design = LayoutIdiom.resolved(idiom)
    if design == .phone {
      VStack(alignment: .leading, spacing: SectionMetrics.stackGap) {
        left
        right
      }
    } else {
      HStack(alignment: .top, spacing: PurchasesMetrics.columnGap(design)) {
        VStack(alignment: .leading, spacing: SectionMetrics.stackGap) { left }
          .frame(maxWidth: .infinity, alignment: .topLeading)
        VStack(alignment: .leading, spacing: SectionMetrics.stackGap) { right }
          .frame(maxWidth: .infinity, alignment: .topLeading)
      }
    }
  }
}

/// The orange button inside a page («Добавить» of the shopping list): the accent fill, 13 medium,
/// 16 × 9, radius 8.
struct PurchasesAccentButtonStyle: ButtonStyle {
  @Environment(\.appTheme) private var theme
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .appFont(PurchasesType.action)
      .foregroundStyle(theme.contentOnAccent)
      .padding(.horizontal, PurchasesMetrics.phoneButtonHorizontal)
      .padding(.vertical, PurchasesMetrics.phoneButtonVertical)
      .background(
        theme.accentDefault, in: .rect(cornerRadius: PurchasesMetrics.phoneButtonRadius)
      )
      .contentShape(.rect(cornerRadius: PurchasesMetrics.phoneButtonRadius))
      .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.4)
  }
}
