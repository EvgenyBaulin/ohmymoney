import AppCore
import SwiftUI

extension EnvironmentValues {
  /// «Изменить» and «Готово» stand in the navigation bar of the host (the phone), not in the
  /// bar above the tiles.
  @Entry var overviewEditsInChrome = false
  /// The title of the screen and its buttons, drawn as the first row of the page and scrolling
  /// with it (the phone and the tablet, whose navigation bar is hidden); `nil` where the window
  /// has a title bar of its own.
  @Entry var overviewTitleRow: OverviewTitleRow?
  /// Tiles in a row fixed by the host (an iPad, whose window width and sidebar decide it, not
  /// the width of the page); `nil` lets the page count by its own width.
  @Entry var overviewColumnsOverride: Int?
  /// The width the window gives the screen (the detail column between the sidebar and the entry
  /// form), set by the host; `nil` lets the page measure itself. A page that counts its columns
  /// from the width it measured of its own content can keep itself too wide: columns that ask
  /// for more than the room keep the page wide, and the wide page keeps its columns.
  @Entry var overviewRoom: CGFloat?
}

/// The type of a phone's or a tablet's Overview in the Mac's points (`appFontDesignPoints`),
/// with the body of every text that names no font — a message of a tile, a button — at the
/// Mac's 13 rather than the 17 of iOS. The Mac's own page is left as it is.
private struct OverviewDesignType: ViewModifier {
  let on: Bool

  func body(content: Content) -> some View {
    if on {
      content
        .appFont(.body)
        .environment(\.appFontDesignPoints, true)
    } else {
      content
    }
  }
}

/// The large title of Overview with what stands at its right edge.
struct OverviewTitleRow {
  let title: String
  let trailing: AnyView
}

/// The month so far, as tiles. The cards come from the calculation pipeline (`ComputeStore`):
/// nothing here reads the database, and nothing here counts — every figure is the core's, only
/// put into words. The operations are «Операции» of the sidebar (`OperationsScreen`); ↓ in the
/// entry line goes there. The sheets the cards open live in `actions`, which the window presents
/// from its root.
struct OverviewView: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.store) private var store
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies
  @Environment(\.themeSurfaces) private var surfaces
  @Environment(\.layoutIdiom) private var idiom
  @Environment(\.overviewColumnsOverride) private var columnsOverride
  let actions: OperationActions
  /// Editing or not, and the tile whose «Почему так» is open.
  @State private var screen: OverviewScreen

  /// The numbers of the page on this platform's own design (`OverviewPageMetrics`): the Mac's,
  /// or the phone's where a phone and a tablet share code that is not told the idiom.
  static var platformMetrics: OverviewPageMetrics {
    #if os(iOS)
      .phone
    #else
      .mac
    #endif
  }

  /// The margin of the page: 16 on a phone, 28 on the Mac and a tablet.
  static var sideMargin: CGFloat { platformMetrics.side }
  /// The margins above and below the page.
  static var topMargin: CGFloat { platformMetrics.top }
  static var bottomMargin: CGFloat { platformMetrics.bottom }
  /// The gap between the parts of the page stacked one under another.
  static var stackGap: CGFloat { platformMetrics.stackGap }

  /// `screen` is handed in by a test that drives the editing and the sheet; the window makes its
  /// own.
  init(actions: OperationActions, screen: OverviewScreen = OverviewScreen()) {
    self.actions = actions
    _screen = State(initialValue: screen)
  }

  var body: some View {
    let metrics = OverviewPageMetrics.of(LayoutIdiom.resolved(idiom), columns: columnsOverride)
    ScrollView {
      OverviewHeader(actions: actions, screen: screen)
        .padding(.horizontal, metrics.side)
        .padding(.top, metrics.top)
        .padding(.bottom, metrics.bottom)
        // A phone's and a tablet's frames write the type of the tiles in the Mac's points,
        // the words without a font of their own too.
        .modifier(OverviewDesignType(on: metrics != .mac))
    }
    .background(surfaces.background)
    .onAppear(perform: followData)
    // The limit of a small purchase and the copies of the database, read again with every change
    // of the data: the tiles of 2.0 follow them.
    .task(id: compute.generation) {
      OverviewFirstRun.seed(environment)
      await OverviewFiguresStore.shared.refresh(environment: environment)
    }
    // Every change of the data: the dictionaries of the menus the cards open follow it.
    .onChange(of: compute.generation) { _, _ in followData() }
    // A sheet is a host of its own: the dependencies are handed to it.
    .sheet(item: Binding(get: { screen.why }, set: { screen.why = $0 })) { tile in
      TileWhySheet(tile: tile, actions: actions)
        .handingOver(dependencies)
    }
  }

  /// The line of «Траты» when no day is listed, as a key and its table: an empty book asks for
  /// the first operation in the floating entry line at the bottom of the window; a book whose
  /// operations are all older than two months points to where they are. Nothing until the
  /// first data arrives — the list shows the state of the data step then.
  static func emptyLine(for snapshot: DataSnapshot?) -> (key: String, table: String)? {
    guard let snapshot else { return nil }
    return snapshot.dataset.entries.isEmpty
      ? ("transactions.empty", "Transactions") : ("overview.noRecent", "Overview")
  }

  private func followData() {
    guard let snapshot = compute.snapshot else { return }
    actions.reloadDictionaries(from: snapshot.dataset)
  }
}

/// The tiles in their groups and the status of the recalculation right under them — the bottom of
/// the window belongs to the entry bar.
///
/// The way back to the setup of the accounts stands above the groups, the full width of them,
/// and only while the setup is put off: it is no cell of a grid, so once the setup is done no
/// empty row is left behind.
///
/// Above everything, «Последняя запись» and «Изменить»: when the owner last wrote something down
/// says whether the figures under it are up to date, so it comes before them — the bottom of the
/// grid is often out of view.
private struct OverviewHeader: View {
  @Dependency(\.environment) private var environment
  @Environment(\.overviewTitleRow) private var titleRow
  @Environment(\.overviewColumnsOverride) private var columnsOverride
  @Environment(\.overviewRoom) private var room
  @Environment(\.appFontSize) private var fontSize
  @Environment(\.layoutIdiom) private var idiom
  @Dependency(\.compute) private var compute
  let actions: OperationActions
  let screen: OverviewScreen
  @State private var measured: CGFloat = 0

  private var metrics: OverviewPageMetrics {
    .of(LayoutIdiom.resolved(idiom), columns: columnsOverride)
  }

  /// The room the page has: the host's, less the margins, else the measured width.
  private var width: CGFloat {
    room.map { max($0 - 2 * metrics.side, 0) } ?? measured
  }

  var body: some View {
    let columns = columnsOverride ?? OverviewCard.columns(forWidth: width, fontSize: fontSize)
    // A tablet lays «Что сделать сейчас» with the main card: beside it, or under it.
    let doNowWithMain =
      metrics.doNowWithMain
      && OverviewGroupedGrid.extras(compute.snapshot, environment).contains(.doNow)
    VStack(alignment: .leading, spacing: metrics.stackGap) {
      if let titleRow {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
          Text(verbatim: titleRow.title)
            .appFont(metrics.titleFont)
            .accessibilityAddTraits(.isHeader)
          Spacer(minLength: 8)
          titleRow.trailing
        }
        .padding(.bottom, metrics.titleBottom)
      }
      OverviewEditBar(screen: screen)
      SummaryAnnouncementCard()
      FirstMonthCard()
      if OverviewHero.shows(forWidth: width) {
        if doNowWithMain, let side = metrics.doNowBesideMain {
          if metrics.doNowStandsBesideMain(columns: columns) {
            // The tablet's first row: the main card, and «Что сделать сейчас» at its right.
            HStack(alignment: .top, spacing: metrics.columnGap) {
              OverviewHero()
              OverviewDoNowCard(screen: screen).frame(width: side)
            }
          } else {
            VStack(alignment: .leading, spacing: metrics.columnGap) {
              OverviewHero()
              OverviewDoNowCard(screen: screen)
            }
          }
        } else {
          OverviewHero()
        }
      }
      if OverviewAccountsStrip.shows { OverviewAccountsStrip() }
      OverviewDiscrepancies()
      if AccountsSetupCard.shows(setup: environment.accountSetup) {
        AccountsSetupCard()
      }
      OverviewGroupedGrid(
        columns: columns,
        // Only the host's room fixes the widths of the places: a width the page measured of
        // itself would hold the page at it when the window narrows.
        width: room == nil ? 0 : width,
        actions: actions,
        screen: screen,
        doNowBesideMain: doNowWithMain)
      RecomputeStatusLine()
    }
    // A container of its own, so the cards inside keep their own identifiers.
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("overview.grid")
    .frame(maxWidth: .infinity, alignment: .leading)
    .onGeometryChange(for: CGFloat.self) {
      $0.size.width
    } action: {
      measured = $0
    }
    .listRowSeparator(.hidden)
    .selectionDisabled()
  }
}
