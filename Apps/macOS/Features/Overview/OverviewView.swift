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
  let actions: OperationActions
  /// Editing or not, and the tile whose «Почему так» is open.
  @State private var screen: OverviewScreen

  /// `screen` is handed in by a test that drives the editing and the sheet; the window makes its
  /// own.
  init(actions: OperationActions, screen: OverviewScreen = OverviewScreen()) {
    self.actions = actions
    _screen = State(initialValue: screen)
  }

  var body: some View {
    ScrollView {
      OverviewHeader(actions: actions, screen: screen)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
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
  let actions: OperationActions
  let screen: OverviewScreen
  @State private var width: CGFloat = 0

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      if let titleRow {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
          Text(verbatim: titleRow.title)
            .appFont(.largeTitle.bold())
            .accessibilityAddTraits(.isHeader)
          Spacer(minLength: 8)
          titleRow.trailing
        }
      }
      OverviewEditBar(screen: screen)
      if OverviewHero.shows(forWidth: width) { OverviewHero() }
      if AccountsSetupCard.shows(setup: environment.accountSetup) {
        AccountsSetupCard()
      }
      OverviewGroupedGrid(
        columns: OverviewCard.columns(forWidth: width), actions: actions, screen: screen)
      RecomputeStatusLine()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .onGeometryChange(for: CGFloat.self) {
      $0.size.width
    } action: {
      width = $0
    }
    .padding(.vertical, 8)
    .listRowSeparator(.hidden)
    .selectionDisabled()
  }
}
