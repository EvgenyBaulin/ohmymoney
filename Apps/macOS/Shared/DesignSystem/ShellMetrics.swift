import AppCore
import SwiftUI

/// The numbers of the sidebar of the main window, as the design draws it (232 pt wide): the
/// rows of the sections, the name of a block of accounts, «Настройки» at the foot. The list
/// itself, its column and its scrolling are the system's.
enum SidebarMetrics {
  /// The width the column opens at.
  static let width: CGFloat = 232
  /// The room between the edge of the column and a row's plate.
  static let sideInset: CGFloat = 12
  /// The room the system's sidebar list keeps between the column's edges and a row, whatever
  /// the row asks; the plate reaches beyond the row by the difference.
  static let listRowInset: CGFloat = 16
  static let listOutset: CGFloat = listRowInset - sideInset
  /// A row of a section: 10 × 7 inside its plate, the icon 17 pt and 9 from the name, the
  /// plate rounded 8, and 3 between two rows.
  static let rowHorizontal: CGFloat = 10
  static let rowVertical: CGFloat = 7
  static let icon: CGFloat = 17
  static let iconGap: CGFloat = 9
  static let plateRadius: CGFloat = 8
  static let rowGap: CGFloat = 3
  /// The name of a block of accounts («СЧЕТА», «БЕЗ ГРУППЫ»): 10 from the plate's edge, 16
  /// above and 4 below.
  static let headerTop: CGFloat = 16
  static let headerBottom: CGFloat = 4
}

/// The type of the sidebar at «Обычный»; it grows with the size chosen in Settings.
enum SidebarType {
  /// A section: 14 medium; the chosen one 14 semibold.
  static let row = AppFont.system(size: 14, weight: .medium)
  static let chosenRow = AppFont.system(size: 14, weight: .semibold)
  /// The name of a block of accounts: 11 semibold.
  static let header = AppFont.system(size: 11, weight: .semibold)
}

/// Where the form of a new operation stands (Settings → «Ввод» → the form at the right): a
/// column of its own at the right of the window while the window holds the content beside it,
/// and a round «+» in the corner of a window narrower than that, which opens the form over the
/// content. The line at the bottom has neither.
enum EntryFormDock {
  /// The width of the form.
  static let width: CGFloat = 360
  /// The narrowest the content beside the form may be: two of the narrowest tiles of Overview,
  /// the gap between them and the margins of the page.
  static let contentMinimum: CGFloat =
    2 * StyleMetrics.tileMinWidth + StyleMetrics.columnGap + 2 * StyleMetrics.pageSide

  enum Placement: Equatable, Sendable {
    /// The line at the bottom: no form at all.
    case line
    /// The form in a column of its own, always there.
    case docked
    /// The form folded into the round «+».
    case collapsed
  }

  /// `contentWidth`: the width of the window less what a sidebar standing beside the content
  /// takes. A width not known yet (0) docks, as the window opens wide by default.
  static func placement(style: EntryStyle, contentWidth: CGFloat) -> Placement {
    guard style == .form else { return .line }
    if contentWidth <= 0 { return .docked }
    return contentWidth >= contentMinimum + width ? .docked : .collapsed
  }

  /// The Mac: the window less the sidebar at its own width.
  static func placement(style: EntryStyle, windowWidth: CGFloat) -> Placement {
    placement(
      style: style, contentWidth: windowWidth > 0 ? windowWidth - SidebarMetrics.width : 0)
  }

  /// What the round «+» of a tablet opens: the line at the bottom, or the folded form; a docked
  /// form is on screen already and leaves no «+».
  enum PlusTarget: Equatable, Sendable { case line, form }

  static func plusOpens(_ placement: Placement) -> PlusTarget? {
    switch placement {
    case .line: .line
    case .collapsed: .form
    case .docked: nil
    }
  }
}

/// Whether the folded form is open over the content. It opens by the «+» or a new entry asked
/// for (⌘N, the palette) and folds again after a save, Esc or a tap outside it; a window wide
/// enough to dock the form, or the line chosen, leaves nothing folded to open.
struct EntryFormPresence: Equatable, Sendable {
  enum Event: Equatable, Sendable {
    case plusTapped
    case newEntryRequested
    case saved
    case escaped
    case tappedOutside
    case placementChanged(EntryFormDock.Placement)
  }

  private(set) var placement: EntryFormDock.Placement
  private(set) var isOpen = false

  init(placement: EntryFormDock.Placement = .line) { self.placement = placement }

  /// The round «+» is in the corner: the form is folded and not open.
  var showsPlus: Bool { placement == .collapsed && !isOpen }
  /// The form is on screen, in its column or over the content.
  var showsForm: Bool { placement == .docked || (placement == .collapsed && isOpen) }
  /// The form is over the content rather than beside it.
  var floats: Bool { placement == .collapsed && isOpen }

  mutating func apply(_ event: Event) {
    switch event {
    case .plusTapped, .newEntryRequested:
      if placement == .collapsed { isOpen = true }
    case .saved, .escaped, .tappedOutside:
      isOpen = false
    case .placementChanged(let next):
      placement = next
      if next != .collapsed { isOpen = false }
    }
  }
}

/// The numbers of the round «+» of the folded form and of the tablet's entry: an accent circle
/// with the plus in the colour on the accent, a soft shadow below it, in the bottom right corner.
enum EntryPlusMetrics {
  /// The Mac: 44 pt, 20 from the right and the bottom edges.
  static let macDiameter: CGFloat = 44
  static let macMargin: CGFloat = 20
  /// The iPad: 56 pt, 24 from the edges.
  static let padDiameter: CGFloat = 56
  static let padMargin: CGFloat = 24
  /// The plus is drawn in a 26 pt square on both.
  static let glyph: CGFloat = 26
  /// The shadow: 4 down, blurred 8, black at 16 %.
  static let shadowY: CGFloat = 4
  static let shadowRadius: CGFloat = 8
  static let shadowOpacity: Double = 0.16
  /// The form open over the content: its shadow falls to the left, blurred 12, black at 18 %.
  static let formShadowX: CGFloat = -4
  static let formShadowRadius: CGFloat = 12
  static let formShadowOpacity: Double = 0.18
  /// The tablet dims the content under the open form: black at 20 %; a tap there folds it.
  static let padDim: Double = 0.2
}

/// The round «+» in the corner of a window whose form is folded.
struct EntryPlusButton: View {
  @Environment(\.appTheme) private var theme
  let diameter: CGFloat
  let label: String
  var help: String? = nil
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: "plus")
        .font(.system(size: 20, weight: .medium))  // font-fixed: the glyph of a fixed circle
        .frame(width: EntryPlusMetrics.glyph, height: EntryPlusMetrics.glyph)
        .foregroundStyle(theme.contentOnAccent)
        .frame(width: diameter, height: diameter)
        .background(theme.accentDefault, in: .circle)
        .shadow(
          color: .black.opacity(EntryPlusMetrics.shadowOpacity),
          radius: EntryPlusMetrics.shadowRadius / 2, y: EntryPlusMetrics.shadowY
        )
        .contentShape(.circle)
    }
    .buttonStyle(.plain)
    .help(help ?? label)
    .accessibilityLabel(Text(verbatim: label))
    .accessibilityIdentifier("entry.form.plus")
  }
}
