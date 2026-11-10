import SwiftUI

/// The numbers of the entry line as the design draws it on each device: a capsule with the
/// sparkles at its start, the words, and the send arrow at its end. The Mac's is 50 pt tall,
/// 16 × 12 inside, 12 between its parts; the phone's 48, the tablet's 54.
struct EntryLineMetrics: Equatable, Sendable {
  /// The room inside the capsule before its first part and after its last.
  let leading: CGFloat
  let trailing: CGFloat
  /// The room above and below its parts.
  let vertical: CGFloat
  /// The room between two parts.
  let gap: CGFloat
  /// The sparkles at the start and the quiet symbols beside the send arrow.
  let icon: CGFloat
  /// The send arrow at the end.
  let send: CGFloat
  /// The height of the whole capsule, its edge included.
  let height: CGFloat
  /// The type of the words, in points at «Обычный».
  let text: CGFloat
  /// The room the capsule keeps from each side of the column on a phone; the tablet's capsule
  /// is as wide as `width`, the Mac's follows the window (`EntryBarMetrics.columnWidth`).
  let side: CGFloat
  /// The width of the tablet's capsule; the phone's is the column less `side` on each side.
  let width: CGFloat?

  static func of(_ idiom: LayoutIdiom) -> EntryLineMetrics {
    switch idiom {
    case .mac:
      EntryLineMetrics(
        leading: 16, trailing: 16, vertical: 12, gap: 12, icon: 18, send: 24, height: 50,
        text: 13, side: EntryBarMetrics.sideMargin, width: nil)
    case .phone:
      EntryLineMetrics(
        leading: 16, trailing: 8, vertical: 7, gap: 10, icon: 15, send: 34, height: 48,
        text: 15, side: 16, width: nil)
    case .pad:
      EntryLineMetrics(
        leading: 14, trailing: 14, vertical: 11, gap: 10, icon: 18, send: 32, height: 54,
        text: 16, side: 16, width: 600)
    }
  }
}

/// The ↓ panel over the line: 20 inside, 12 between its rows, rounded 22; the kinds in a
/// rounded track (`EntryKindTabs`).
enum EntryPanelMetrics {
  static let padding: CGFloat = 20
  static let gap: CGFloat = 12
  static let radius: CGFloat = 22
}

/// The form of a new operation at the right of the window, as the design draws it (360 pt):
/// 16 inside and 10 between its rows, the title 17 bold, the kinds in a track of equal segments,
/// the amount 28 bold with its words 14 beside it, the fields two to a row 8 apart with their
/// labels 4 above them, and «Записать» across the column, rounded 8.
enum EntryFormMetrics {
  static let inset: CGFloat = 16
  static let gap: CGFloat = 10
  /// The room between two fields of a row.
  static let fieldGap: CGFloat = 8
  /// The room between a label and its field.
  static let labelGap: CGFloat = 4
  /// «Записать»: 16 × 8 inside, rounded 8, as wide as the column.
  static let saveHorizontal: CGFloat = 16
  static let saveVertical: CGFloat = 8
  static let saveRadius: CGFloat = 8
  /// The figure of the amount and the words beside it.
  static let amountGap: CGFloat = 10
}

/// The type of the entry, in points at «Обычный»; each grows with the size chosen in Settings.
enum EntryType {
  /// «Новая запись»: 17 bold.
  static let formTitle = AppFont.system(size: 17, weight: .bold)
  /// The amount of the panel and of the form: 28 bold, its figures of one width.
  static let amount = AppFont.system(size: 28, weight: .bold).monospacedDigit()
  /// The label over a field: 11 on the Mac, the system's subheadline there; the system's
  /// caption on a phone and a tablet.
  static var label: AppFont {
    #if os(iOS)
      .caption
    #else
      .subheadline
    #endif
  }
  /// «Записать» of the form: 11.
  static let save = AppFont.system(size: 11)
}

/// The kinds of an operation in one rounded track: the chosen one a card-coloured chip with an
/// edge, the others quiet. The ↓ panel's are 13 pt, each as wide as its name, the track 3 inside;
/// the form's are 11 pt, all of one width, the track 2 inside.
struct EntryKindTrackMetrics: Equatable, Sendable {
  let inset: CGFloat
  let trackRadius: CGFloat
  let chipRadius: CGFloat
  let horizontal: CGFloat
  let vertical: CGFloat
  let text: CGFloat
  /// The segments share the track equally (the form) or take their names' widths (the panel).
  let equalWidths: Bool

  static let panel = EntryKindTrackMetrics(
    inset: 3, trackRadius: 10, chipRadius: 8, horizontal: 10, vertical: 6, text: 13,
    equalWidths: false)
  static let form = EntryKindTrackMetrics(
    inset: 2, trackRadius: 10, chipRadius: 8, horizontal: 4, vertical: 6, text: 11,
    equalWidths: true)
}

/// The sheets of quick entry («Операции из банка», «Черновики»), as the design draws them: 520
/// wide, rounded 16 by the system; a head of the title 17 bold, and under it a line 12, 16 × 20
/// inside; a rule; a body 20 inside with 14 between its parts — the rows in a card rounded 10,
/// 12 at its sides, each row 10 above and below, 10 between its parts —; a rule; the buttons at
/// the right, 14 × 20 inside, 10 apart.
enum QuickSheetMetrics {
  static let width: CGFloat = 520
  static let headHorizontal: CGFloat = 20
  static let headVertical: CGFloat = 16
  static let headLineGap: CGFloat = 3
  static let body: CGFloat = 20
  static let bodyGap: CGFloat = 14
  static let listRadius: CGFloat = 10
  static let listSide: CGFloat = 12
  static let rowVertical: CGFloat = 10
  static let rowGap: CGFloat = 10
  static let footHorizontal: CGFloat = 20
  static let footVertical: CGFloat = 14
  static let footGap: CGFloat = 10
  /// The tick of a row of the bank's list.
  static let tick: CGFloat = 18
}

/// The type of the sheets of quick entry.
enum QuickSheetType {
  /// The title: 17 bold.
  static let title = AppFont.system(size: 17, weight: .bold)
  /// The line under the title and the hints of the body: 12.
  static let line = AppFont.system(size: 12)
  /// A row: 13, its sum 13 semibold.
  static let row = AppFont.system(size: 13)
  static let rowFigure = AppFont.system(size: 13, weight: .semibold).monospacedDigit()
  /// The line under a row: 11.
  static let rowDetail = AppFont.system(size: 11)
}
