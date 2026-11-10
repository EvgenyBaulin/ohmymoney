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
  let symbol: String
  let title: String
  var detail: String?
  var chip: (title: String, tone: StatusTone)?
  var figure: String?

  var body: some View {
    let design = LayoutIdiom.resolved(idiom)
    HStack(spacing: PurchasesMetrics.rowGap) {
      if design != .phone {
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
