import SwiftUI

/// The numbers of the page of Overview on each design: the Mac's master (1440 × 900), the
/// phone's (440 pt) and the tablet's (1366 × 1024). The tablet's frame is the Mac's master laid
/// into the tablet, so its tiles, type and buttons are the Mac's; it keeps its own gaps (12), the
/// height of its main card (16 above and below) and «Что сделать сейчас» with the main card: 440
/// wide beside it in a grid of three, under it across the page in a narrower window (Split View ½,
/// 564:97540, with margins of 24). The phone stacks everything 10 apart, its main card smaller
/// (20 pt figure, 14 × 16 of margin).
struct OverviewPageMetrics: Equatable, Sendable {
  /// The margins of the page.
  var side: CGFloat
  var top: CGFloat
  var bottom: CGFloat
  /// Between the title row, the main card and the groups.
  var stackGap: CGFloat
  /// Between two groups, above a group's name (besides `stackGap`) and under it.
  var groupGap: CGFloat
  var nameTop: CGFloat
  var nameGap: CGFloat
  /// Between tiles side by side and between rows of tiles.
  var columnGap: CGFloat
  var rowGap: CGFloat
  /// The title row of a phone and a tablet: the size of the name of the screen, and the room
  /// under the row besides `stackGap`.
  var titlePoints: CGFloat
  var titleBottom: CGFloat
  /// The main card: its margins and the size of its figure.
  var mainHorizontal: CGFloat
  var mainVertical: CGFloat
  var mainFigurePoints: CGFloat
  /// The edge of a tile is the hairline (the phone) rather than the outline.
  var tileEdgeIsHairline: Bool
  /// «Что сделать сейчас» stands with the main card (the tablet) — beside it at this width in a
  /// grid of three, under it otherwise — or in the stack of the page — `nil`.
  var doNowBesideMain: CGFloat?
  /// «3 дела · Все» in the accent's words (the phone) rather than the secondary ink.
  var countIsAccent: Bool
  /// The margins at the sides of a tablet's grid narrower than three tiles.
  var narrowSide: CGFloat? = nil

  static let mac = OverviewPageMetrics(
    side: StyleMetrics.pageSide, top: StyleMetrics.pageTop, bottom: StyleMetrics.pageBottom,
    stackGap: StyleMetrics.stackGap, groupGap: StyleMetrics.stackGap, nameTop: 0,
    nameGap: StyleMetrics.stackGap, columnGap: StyleMetrics.columnGap,
    rowGap: StyleMetrics.stackGap, titlePoints: 22, titleBottom: 0,
    mainHorizontal: StyleMetrics.mainCardHorizontal, mainVertical: StyleMetrics.mainCardVertical,
    mainFigurePoints: 24, tileEdgeIsHairline: false, doNowBesideMain: nil, countIsAccent: false)

  /// 5:8097: the content 20 from the sides (the design drew 16; the display's corners ask for more), every part 10 apart, a group's name 6 lower; the
  /// title 34 bold 12 under the status bar with 19 to the main card; the main card 14 × 16 with
  /// a figure of 20.
  static let phone = OverviewPageMetrics(
    side: PhoneMetrics.screenMargin, top: 12, bottom: 16, stackGap: 10, groupGap: 10, nameTop: 6, nameGap: 10,
    columnGap: StyleMetrics.columnGap, rowGap: 10, titlePoints: 34, titleBottom: 9,
    mainHorizontal: 14, mainVertical: 16, mainFigurePoints: 20, tileEdgeIsHairline: true,
    doNowBesideMain: nil, countIsAccent: true)

  /// 5:76205: the Mac's margins (28 at the sides, 24 below; the title right under the
  /// navigation bar), every part 12 apart, tiles 14 apart, the title 22 bold; the main card
  /// 20 × 16 and «Что сделать сейчас» 440 wide beside it.
  static let pad = OverviewPageMetrics(
    side: StyleMetrics.pageSide, top: 0, bottom: StyleMetrics.pageBottom, stackGap: 12,
    groupGap: 12, nameTop: 0, nameGap: 12, columnGap: StyleMetrics.columnGap, rowGap: 12,
    titlePoints: 22, titleBottom: 0, mainHorizontal: StyleMetrics.mainCardHorizontal,
    mainVertical: 16, mainFigurePoints: 24, tileEdgeIsHairline: false, doNowBesideMain: 440,
    countIsAccent: false, narrowSide: 24)

  static func of(_ idiom: LayoutIdiom) -> OverviewPageMetrics {
    switch idiom {
    case .mac: .mac
    case .phone: .phone
    case .pad: .pad
    }
  }

  /// The numbers for a grid of `columns` (the host's; `nil` when the page counts them itself):
  /// a tablet narrower than three tiles keeps 24 at the sides.
  static func of(_ idiom: LayoutIdiom, columns: Int?) -> OverviewPageMetrics {
    var metrics = of(idiom)
    if let narrow = metrics.narrowSide, let columns, columns < 3 { metrics.side = narrow }
    return metrics
  }

  /// The narrower Mac frame keeps 22 at the sides and 12 between columns. A missing window
  /// width uses the master frame's metrics, as standalone previews did before.
  static func of(
    _ idiom: LayoutIdiom, columns: Int?, windowWidth: CGFloat
  ) -> OverviewPageMetrics {
    var metrics = of(idiom, columns: columns)
    if idiom == .mac, windowWidth > 0, windowWidth <= 1_024 {
      metrics.side = 22
      metrics.columnGap = 12
    }
    return metrics
  }

  /// «Что сделать сейчас» stands with the main card rather than in the stack or among the tiles.
  var doNowWithMain: Bool { doNowBesideMain != nil }

  /// The tablet's frame keeps «Что сделать сейчас» beside the main card while its grid is three
  /// tiles wide; in a narrower one it stands under the main card, across the page.
  func doNowStandsBesideMain(columns: Int) -> Bool {
    doNowWithMain && columns >= 3
  }

  /// The name of the screen in the title row: 34 bold on a phone, 22 bold on a tablet.
  var titleFont: AppFont { .system(size: titlePoints, weight: .bold) }
  /// The figure of the main card.
  var mainFigureFont: AppFont { .system(size: mainFigurePoints, weight: .bold).monospacedDigit() }
}

/// «Изменить» of the phone's title row (5:8097): 15 medium in the primary ink.
enum OverviewTitleType {
  static let phoneAction = AppFont.system(size: 15, weight: .medium)
  static let phoneDone = AppFont.system(size: 15, weight: .semibold)
}

extension EnvironmentValues {
  /// One set of page metrics for the margins and every grid inside them.
  @Entry var overviewPageMetrics: OverviewPageMetrics? = nil
}
