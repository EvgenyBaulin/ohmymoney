import SwiftUI

/// The numbers of «Операции» as the design draws them: the Mac at 1440 × 900 (its content is
/// 1206 pt wide), the tablet at 1366 × 1024 and the phone at 440 pt. The table of the Mac is the
/// system's — its header row, the height of its rows and its separators are drawn by AppKit — so
/// these are the numbers of what the screen draws itself: the header, the chips, the month, the
/// card the table stands on, the cells and the head of a day.
enum OperationsMetrics {
  // MARK: The header (Mac)

  /// The margins of the page: 24 at the sides; the title row 14 above and 10 below, 56 tall.
  static let pageSide: CGFloat = 24
  static let headerTop: CGFloat = 14
  static let headerBottom: CGFloat = 10
  /// The search box: 220 × 34, 12 inside, the magnifier 15 pt and 8 from the words, radius 10.
  static let searchWidth: CGFloat = 220
  static let controlHeight: CGFloat = 34
  static let controlRadius: CGFloat = 10
  static let searchHorizontal: CGFloat = 12
  static let searchIcon: CGFloat = 15
  static let searchIconGap: CGFloat = 8
  /// Between the search box and «Новая операция».
  static let headerGap: CGFloat = 10

  // MARK: The chips and the month (Mac)

  /// The row of chips: 6 under the header, 16 above the table, 8 between chips.
  static let chipsTop: CGFloat = 6
  static let chipsToTable: CGFloat = 16
  static let chipGap: CGFloat = 8
  /// A chip: 14 × 6 around 13 medium words, a capsule.
  static let chipHorizontal: CGFloat = 14
  static let chipVertical: CGFloat = 6
  /// The month: 12 × 6, the chevrons 13 pt and 8 from the name, a capsule on the card colour
  /// with the hairline.
  static let monthHorizontal: CGFloat = 12
  static let monthVertical: CGFloat = 6
  static let monthChevron: CGFloat = 13
  static let monthGap: CGFloat = 8

  // MARK: The table (Mac and tablet)

  /// The card of the table: radius 12 on the Mac, 22 on the tablet, 4 above and below, the
  /// hairline and a shadow 0 / 4 / 16 at 3 %.
  static let cardRadius: CGFloat = 12
  static let padCardRadius: CGFloat = 22
  static let cardVertical: CGFloat = 4
  static let cardShadowY: CGFloat = 4
  static let cardShadowBlur: CGFloat = 16
  static let cardShadowOpacity: Double = 0.03
  /// A row: 18 at the sides, 9 above and below (8 on the tablet), 12 between the columns.
  static let rowHorizontal: CGFloat = 18
  static let rowVertical: CGFloat = 9
  static let padRowVertical: CGFloat = 8
  static let columnGap: CGFloat = 12
  /// The round mark of a row: 32 with a 16-pt drawing, 12 from the description.
  static let badge: CGFloat = 32
  static let badgeSymbol: CGFloat = 16
  static let badgeGap: CGFloat = 12
  /// The columns the design shows, as wide as it draws them; the description takes the rest.
  static let categoryWidth: CGFloat = 160
  static let accountWidth: CGFloat = 140
  static let timeWidth: CGFloat = 70
  static let amountWidth: CGFloat = 120
  /// The head of a day: 10 above and 6 below on the Mac, 8 and 4 on the tablet.
  static let dayTop: CGFloat = 10
  static let dayBottom: CGFloat = 6
  static let padDayTop: CGFloat = 8
  static let padDayBottom: CGFloat = 4

  // MARK: The tablet

  /// The tablet's page: 32 at the sides, 8 above the title, 16 between its parts; the search
  /// 240 × 34 with 14 inside and a 16-pt magnifier; a chip 16 × 7 around 14 medium words.
  static let padPageSide: CGFloat = 32
  static let padSearchWidth: CGFloat = 240
  static let padSearchHorizontal: CGFloat = 14
  static let padSearchIcon: CGFloat = 16
  static let padStackGap: CGFloat = 16
  static let padChipHorizontal: CGFloat = 16
  static let padChipVertical: CGFloat = 7
  static let padMonthHorizontal: CGFloat = 14
  static let padMonthVertical: CGFloat = 7
  static let padMonthChevron: CGFloat = 14

  // MARK: The phone

  /// The phone's page: 16 at the sides, 10 between its parts; a day: its head 6 inside and 6
  /// above, 4 over its card; the card radius 22 with a shadow 0 / 6 / 20 at 5 %.
  static let phonePageSide: CGFloat = 16
  static let phoneStackGap: CGFloat = 10
  static let phoneDayInset: CGFloat = 6
  static let phoneDayGap: CGFloat = 4
  static let phoneCardRadius: CGFloat = 22
  static let phoneShadowY: CGFloat = 6
  static let phoneShadowBlur: CGFloat = 20
  static let phoneShadowOpacity: Double = 0.05
  /// A row: 14 × 10, 12 between its parts; the mark 36 with an 18-pt drawing; 1 between its
  /// two lines.
  static let phoneRowHorizontal: CGFloat = 14
  static let phoneRowVertical: CGFloat = 10
  static let phoneBadge: CGFloat = 36
  static let phoneBadgeSymbol: CGFloat = 18
  static let phoneLineGap: CGFloat = 1
  /// The month: 12 × 7, chevrons 14, a capsule.
  static let phoneMonthHorizontal: CGFloat = 12
  static let phoneMonthVertical: CGFloat = 7
  static let phoneMonthChevron: CGFloat = 14
}

/// The type of «Операции» at «Обычный»; each grows with the size chosen in Settings.
enum OperationsType {
  /// A chip: 13 medium on the Mac; 14 medium on the tablet.
  static let chip = AppFont.system(size: 13, weight: .medium)
  static let padChip = AppFont.system(size: 14, weight: .medium)
  /// The search prompt: 13 on the Mac, 14 on the tablet.
  static let search = AppFont.system(size: 13)
  static let padSearch = AppFont.system(size: 14)
  /// The month: 13 semibold on the Mac, 14 semibold on the tablet and the phone.
  static let month = AppFont.system(size: 13, weight: .semibold)
  static let touchMonth = AppFont.system(size: 14, weight: .semibold)
  /// The head of a day: its name 12 semibold in capitals, its figure 12 medium.
  static let dayName = AppFont.system(size: 12, weight: .semibold)
  static let dayFigure = AppFont.system(size: 12, weight: .medium).monospacedDigit()
  /// A row of the table: the description 15 medium, the other columns 14, the amount 15
  /// semibold.
  static let rowTitle = AppFont.system(size: 15, weight: .medium)
  static let rowCell = AppFont.system(size: 14)
  static let rowAmount = AppFont.system(size: 15, weight: .semibold).monospacedDigit()
  /// A row of the phone: the description 16 medium over «category · account» 12, the amount 16
  /// semibold.
  static let phoneTitle = AppFont.system(size: 16, weight: .medium)
  static let phoneCaption = AppFont.system(size: 12)
  static let phoneAmount = AppFont.system(size: 16, weight: .semibold).monospacedDigit()
}

/// The card a table of «Операции» stands on (Mac 5:35466, tablet 5:76375): the card colour, the
/// hairline, the faint shadow; radius 12 on the Mac and 22 on a tablet.
struct OperationsCard: ViewModifier {
  @Environment(\.appTheme) private var theme
  @Environment(\.colorSchemeContrast) private var contrast

  static var radius: CGFloat {
    #if os(iOS)
      OperationsMetrics.padCardRadius
    #else
      OperationsMetrics.cardRadius
    #endif
  }

  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: Self.radius)
    content
      .background(theme.surfaceCard, in: shape)
      .clipShape(shape)
      .overlay {
        shape.strokeBorder(theme.borderHairline, lineWidth: StyleMetrics.cardBorder)
        if contrast == .increased { shape.strokeBorder(.separator, lineWidth: 1) }
      }
      .background {
        shape.fill(theme.surfaceCard)
          .shadow(
            color: .black.opacity(OperationsMetrics.cardShadowOpacity),
            radius: OperationsMetrics.cardShadowBlur / 2, y: OperationsMetrics.cardShadowY)
      }
  }
}

extension View {
  func operationsCard() -> some View { modifier(OperationsCard()) }
}

/// The column of the editor beside the table (6:89246): 360 wide, 16 inside; its head
/// «Правка · Обед» 17 bold with the round × of 28 at the right.
enum InspectorMetrics {
  static let width: CGFloat = 360
  static let padding: CGFloat = 16
  static let close: CGFloat = 28
  static let title = AppFont.system(size: 17, weight: .bold)
}
